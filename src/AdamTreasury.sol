// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IAdamDistributor} from "./interfaces/IAdamDistributor.sol";

/// @title AdamTreasury
/// @notice Receives the ETH fees taken by AdamHook and, on anyone's call to `process()`, splits them:
///   - 10% to the team wallet (pushed; if the push fails it is held and can be forwarded later);
///   - 90% to holders, as 45% ETH -> IMD and 45% ETH -> PNKSTR bought on their Uniswap v4 pools and
///     pushed to the AdamDistributor.
///
/// MEV limits on the buys: each buy leg is capped at `maxEthPerBuy` per call, `process()` is rate limited by
/// `cooldown`, and every swap requires at least the spot-price output after pool fees and the configured hook
/// buy tax, minus `slippageBps`. Keepers should still submit `process()` through a private relay.
///
/// Fault tolerance: each leg is attempted independently. A failing leg keeps its ETH earmarked and is retried
/// on the next call; if a leg has failed continuously for `LEG_FALLBACK_DELAY` its earmarked ETH is rerouted
/// to the other leg so holder funds never strand behind a dead pool.
///
/// Trust model: no owner, no upgrade, no withdrawal path for anyone. Every parameter is immutable.
contract AdamTreasury is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    uint256 public constant BPS = 10_000;
    uint256 public constant TEAM_BPS = 1000;
    uint256 public constant LEG_FALLBACK_DELAY = 3 days;
    uint256 public constant MAX_SLIPPAGE_BPS = 2000;
    uint256 public constant MAX_COOLDOWN = 1 days;
    uint256 private constant TEAM_PUSH_GAS = 100_000;
    uint8 public constant LEG_IMD = 0;
    uint8 public constant LEG_PNKSTR = 1;

    struct Leg {
        PoolKey key;
        /// @dev Buy tax charged by the pool's hook, in bps of the output (measured on a mainnet fork).
        uint16 hookTaxBps;
        /// @dev ETH already split for this leg and not yet swapped.
        uint256 pending;
        /// @dev Timestamp of the first failure of the current failure streak; 0 when healthy.
        uint64 failingSince;
    }

    IPoolManager public immutable poolManager;
    IAdamDistributor public immutable distributor;
    address public immutable teamWallet;
    uint256 public immutable maxEthPerBuy;
    uint16 public immutable slippageBps;
    uint32 public immutable cooldown;

    Leg[2] private _legs;
    /// @notice ETH owed to the team because a push failed; anyone can forward it with `payTeam()`.
    uint256 public teamOwed;
    uint64 public lastProcessed;

    bool private _inProcess;

    event Split(uint256 ethProcessed, uint256 teamShare, uint256 holdersShare);
    event TeamPaid(uint256 amount);
    event TeamPaymentDeferred(uint256 amount);
    event LegBought(uint8 indexed leg, address indexed token, uint256 ethIn, uint256 amountOut);
    event LegFailed(uint8 indexed leg, uint256 ethAttempted, bytes reason);
    event LegRerouted(uint8 indexed fromLeg, uint8 indexed toLeg, uint256 amount);
    event RewardsFlushed(address indexed token, uint256 amount);

    error ZeroAddress();
    error InvalidParameter();
    error NotPoolManager();
    error NotProcessing();
    error CooldownActive(uint64 availableAt);
    error NothingToProcess();
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error PartialFill();
    error TeamTransferFailed();
    error NothingOwed();

    /// @dev Parameters are flat so the contract can be constructed by a factory with primitive arguments.
    /// @param distributor_ AdamDistributor receiving IMD and PNKSTR.
    /// @param teamWallet_ Receives 10% of every processed ETH amount.
    /// @param poolManager_ Uniswap v4 PoolManager.
    /// @param imd IMD token (currency1 of the ETH/IMD pool).
    /// @param imdFee ETH/IMD pool LP fee.
    /// @param imdTickSpacing ETH/IMD pool tick spacing (unsigned; cast to int24).
    /// @param imdHooks ETH/IMD pool hook address (address(0) on mainnet).
    /// @param imdTaxBps Buy tax of the IMD pool hook in bps of output (0 on mainnet).
    /// @param pnkstr PNKSTR token (currency1 of the ETH/PNKSTR pool).
    /// @param pnkstrFee ETH/PNKSTR pool LP fee.
    /// @param pnkstrTickSpacing ETH/PNKSTR pool tick spacing (unsigned; cast to int24).
    /// @param pnkstrHooks ETH/PNKSTR pool hook address.
    /// @param pnkstrTaxBps Buy tax of the PNKSTR pool hook in bps of output (measured: 1000).
    /// @param maxEthPerBuy_ Max ETH swapped per leg per `process()` call.
    /// @param slippageBps_ Tolerance below the spot-price-after-fees output.
    /// @param cooldown_ Minimum seconds between two `process()` calls.
    constructor(
        address distributor_,
        address teamWallet_,
        address poolManager_,
        address imd,
        uint24 imdFee,
        uint24 imdTickSpacing,
        address imdHooks,
        uint16 imdTaxBps,
        address pnkstr,
        uint24 pnkstrFee,
        uint24 pnkstrTickSpacing,
        address pnkstrHooks,
        uint16 pnkstrTaxBps,
        uint256 maxEthPerBuy_,
        uint16 slippageBps_,
        uint32 cooldown_
    ) {
        if (
            distributor_ == address(0) || teamWallet_ == address(0) || poolManager_ == address(0) || imd == address(0)
                || pnkstr == address(0)
        ) revert ZeroAddress();
        if (
            maxEthPerBuy_ == 0 || slippageBps_ > MAX_SLIPPAGE_BPS || cooldown_ > MAX_COOLDOWN || imdTaxBps >= BPS
                || pnkstrTaxBps >= BPS || imd == pnkstr || imdTickSpacing > uint24(type(int24).max)
                || pnkstrTickSpacing > uint24(type(int24).max)
        ) revert InvalidParameter();

        poolManager = IPoolManager(poolManager_);
        distributor = IAdamDistributor(distributor_);
        teamWallet = teamWallet_;
        maxEthPerBuy = maxEthPerBuy_;
        slippageBps = slippageBps_;
        cooldown = cooldown_;

        _legs[LEG_IMD].key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(imd),
            fee: imdFee,
            tickSpacing: int24(imdTickSpacing),
            hooks: IHooks(imdHooks)
        });
        _legs[LEG_IMD].hookTaxBps = imdTaxBps;
        _legs[LEG_PNKSTR].key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(pnkstr),
            fee: pnkstrFee,
            tickSpacing: int24(pnkstrTickSpacing),
            hooks: IHooks(pnkstrHooks)
        });
        _legs[LEG_PNKSTR].hookTaxBps = pnkstrTaxBps;
    }

    /// @dev Fee ETH arrives here from the PoolManager (`take`) during swaps; keep it to a bare receive.
    receive() external payable {}

    // ---------------------------------------------------------------------------------------------
    // Public maintenance
    // ---------------------------------------------------------------------------------------------

    /// @notice Split newly received ETH 10/90, buy IMD and PNKSTR with the holders' share and push them to
    /// the distributor. Anyone may call; rate limited by `cooldown`.
    function process() external nonReentrant {
        uint64 availableAt = lastProcessed + cooldown;
        if (block.timestamp < availableAt) revert CooldownActive(availableAt);

        uint256 unsplit = unsplitEth();
        uint256 cap = (2 * maxEthPerBuy * BPS) / (BPS - TEAM_BPS);
        uint256 amount = unsplit > cap ? cap : unsplit;
        if (amount == 0 && _legs[LEG_IMD].pending == 0 && _legs[LEG_PNKSTR].pending == 0) revert NothingToProcess();
        lastProcessed = uint64(block.timestamp);

        if (amount != 0) {
            uint256 teamShare = (amount * TEAM_BPS) / BPS;
            uint256 holdersShare = amount - teamShare;
            uint256 half = holdersShare / 2;
            _legs[LEG_IMD].pending += half;
            _legs[LEG_PNKSTR].pending += holdersShare - half;
            emit Split(amount, teamShare, holdersShare);
            _pushTeam(teamShare);
        }

        _inProcess = true;
        _executeLeg(LEG_IMD);
        _executeLeg(LEG_PNKSTR);
        _inProcess = false;
    }

    /// @notice Forward ETH held for the team after a failed push.
    function payTeam() external nonReentrant {
        uint256 amount = teamOwed;
        if (amount == 0) revert NothingOwed();
        teamOwed = 0;
        (bool ok,) = teamWallet.call{value: amount}("");
        if (!ok) revert TeamTransferFailed();
        emit TeamPaid(amount);
    }

    /// @notice Push any reward-token balance sitting here (e.g. tokens sent by mistake) to the distributor.
    function flushRewards() external nonReentrant {
        for (uint8 i; i < 2; ++i) {
            address token = Currency.unwrap(_legs[i].key.currency1);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;
            IERC20(token).forceApprove(address(distributor), balance);
            distributor.notifyReward(token, balance);
            emit RewardsFlushed(token, balance);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // PoolManager callback
    // ---------------------------------------------------------------------------------------------

    /// @dev Entered only through `poolManager.unlock` issued by `_executeLeg`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_inProcess) revert NotProcessing();
        (uint8 legId, uint256 ethIn) = abi.decode(data, (uint8, uint256));
        PoolKey memory key = _legs[legId].key;

        uint256 minOut = quoteMinOut(legId, ethIn);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        int128 ethDelta = delta.amount0();
        int128 outDelta = delta.amount1();
        if (ethDelta >= 0 || uint256(uint128(-ethDelta)) != ethIn) revert PartialFill();
        if (outDelta <= 0) revert InsufficientOutput(0, minOut);
        uint256 amountOut = uint256(uint128(outDelta));
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        poolManager.settle{value: ethIn}();
        poolManager.take(key.currency1, address(this), amountOut);
        return abi.encode(amountOut);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice ETH received and not yet split.
    function unsplitEth() public view returns (uint256) {
        return address(this).balance - teamOwed - _legs[LEG_IMD].pending - _legs[LEG_PNKSTR].pending;
    }

    function leg(uint8 legId) external view returns (Leg memory) {
        return _legs[legId];
    }

    /// @notice Minimum acceptable output for buying with `ethIn` on `legId`: spot price after the pool's
    /// protocol + LP fee and the hook's buy tax, minus `slippageBps`.
    function quoteMinOut(uint8 legId, uint256 ethIn) public view returns (uint256) {
        Leg storage l = _legs[legId];
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(l.key.toId());
        if (sqrtPriceX96 == 0) revert InvalidParameter();
        uint24 swapFee = protocolFee.getZeroForOneFee().calculateSwapFee(lpFee);
        uint256 amountAfterFee = ethIn - FullMath.mulDiv(ethIn, swapFee, LPFeeLibrary.MAX_LP_FEE);
        // token1 per token0 = sqrtPrice^2 / 2^192
        uint256 spotOut = FullMath.mulDiv(amountAfterFee, sqrtPriceX96, FixedPoint96.Q96);
        spotOut = FullMath.mulDiv(spotOut, sqrtPriceX96, FixedPoint96.Q96);
        uint256 afterTax = (spotOut * (BPS - l.hookTaxBps)) / BPS;
        return (afterTax * (BPS - slippageBps)) / BPS;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _pushTeam(uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = teamWallet.call{value: amount, gas: TEAM_PUSH_GAS}("");
        if (ok) {
            emit TeamPaid(amount);
        } else {
            teamOwed += amount;
            emit TeamPaymentDeferred(amount);
        }
    }

    function _executeLeg(uint8 legId) private {
        Leg storage l = _legs[legId];
        uint256 ethIn = l.pending < maxEthPerBuy ? l.pending : maxEthPerBuy;
        if (ethIn == 0) return;
        address token = Currency.unwrap(l.key.currency1);

        try poolManager.unlock(abi.encode(legId, ethIn)) returns (bytes memory result) {
            uint256 amountOut = abi.decode(result, (uint256));
            l.pending -= ethIn;
            l.failingSince = 0;
            emit LegBought(legId, token, ethIn, amountOut);
            IERC20(token).forceApprove(address(distributor), amountOut);
            distributor.notifyReward(token, amountOut);
        } catch (bytes memory reason) {
            emit LegFailed(legId, ethIn, reason);
            if (l.failingSince == 0) {
                l.failingSince = uint64(block.timestamp);
            } else if (block.timestamp >= uint256(l.failingSince) + LEG_FALLBACK_DELAY) {
                uint8 other = legId == LEG_IMD ? LEG_PNKSTR : LEG_IMD;
                uint256 moved = l.pending;
                l.pending = 0;
                l.failingSince = 0;
                _legs[other].pending += moved;
                emit LegRerouted(legId, other, moved);
            }
        }
    }
}
