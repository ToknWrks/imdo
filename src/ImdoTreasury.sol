// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IImdoStaking} from "./interfaces/IImdoStaking.sol";

/// @notice ADAM V2 pull-payment treasury reduced to one buy and one capped ETH credit leg.
contract ImdoTreasury is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    uint256 public constant BPS = 10_000;
    uint256 public constant KEEPER_BPS = 50;
    uint256 public constant OPS_BPS = 1000;
    uint256 public constant OFFSETS_BPS = 2500;
    uint256 public constant REGEN_BPS = 2500;
    uint256 public constant IMD_BPS = 4000;
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant CHECKPOINT_DECAY = 7 days;
    uint256 public constant MAX_SLIPPAGE_BPS = 2000;
    uint256 public constant MAX_COOLDOWN = 1 days;
    uint256 public constant MIN_ETH_PER_BUY = 1 gwei;
    uint256 public constant MAX_FAILURE_GAP = 2 hours;
    uint8 public constant MIN_FAILURES = 4;
    uint8 public constant LEG_IMD = 0;

    struct Leg {
        PoolKey key;
        uint256 pending;
        uint64 failingSince;
        uint64 lastFailure;
        uint8 failures;
        uint256 retryCap;
        uint160 checkpointSqrtPriceX96;
        uint64 checkpointAt;
    }

    IPoolManager public immutable poolManager;
    IImdoStaking public immutable staking;
    address public immutable opsWallet;
    address public immutable offsetsSafe;
    address public immutable regenSafe;
    uint256 public immutable maxEthPerBuy;
    uint16 public immutable slippageBps;
    uint32 public immutable cooldown;
    uint256 public immutable regenCapMin;
    uint256 public immutable regenCapMax;
    uint256 public regenCap;
    mapping(uint256 epoch => uint256) public regenAccrued;
    uint256 public pendingRegen;
    uint256 public opsOwed;
    uint256 public offsetsOwed;
    mapping(address => uint256) public keeperOwed;
    uint256 public totalKeeperOwed;
    uint64 public lastProcessed;
    Leg private _imdLeg;
    bool private _inProcess;

    event Split(uint256 ethProcessed, uint256 bounty, uint256 ops, uint256 offsets, uint256 regen, uint256 imd);
    event OpsPaid(uint256 amount);
    event OffsetsPaid(uint256 amount);
    event KeeperPaid(address indexed keeper, uint256 amount);
    event KeeperPaymentDeferred(address indexed keeper, uint256 amount);
    event RegenCapSet(uint256 oldCap, uint256 newCap);
    event RegenAccrued(uint256 indexed epoch, uint256 amount, uint256 overflow);
    event RegenSent(uint256 amount);
    event RegenDeferred(uint256 amount, bytes reason);
    event LegBought(uint8 indexed leg, address indexed token, uint256 ethIn, uint256 amountOut);
    event LegFailed(uint8 indexed leg, uint256 ethAttempted, bytes reason);
    event RewardsFlushed(address indexed token, uint256 amount);
    event CheckpointSeeded(uint160 sqrtPriceX96);

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
    error Unauthorized();
    error PoolUnavailable();

    constructor(
        address staking_,
        address opsWallet_,
        address offsetsSafe_,
        address regenSafe_,
        address manager_,
        address imd,
        uint24 imdFee,
        uint24 imdTickSpacing,
        address imdHooks,
        uint256 maxEthPerBuy_,
        uint16 slippageBps_,
        uint32 cooldown_,
        uint256 regenCap_,
        uint256 regenCapMin_,
        uint256 regenCapMax_
    ) {
        if (
            staking_ == address(0) || opsWallet_ == address(0) || offsetsSafe_ == address(0) || regenSafe_ == address(0)
                || manager_ == address(0) || imd == address(0)
        ) revert ZeroAddress();
        if (
            maxEthPerBuy_ < MIN_ETH_PER_BUY || maxEthPerBuy_ > uint256(uint128(type(int128).max))
                || slippageBps_ > MAX_SLIPPAGE_BPS || cooldown_ > MAX_COOLDOWN || imdTickSpacing == 0
                || imdTickSpacing > uint24(TickMath.MAX_TICK_SPACING) || imdFee > LPFeeLibrary.MAX_LP_FEE
                || regenCapMin_ > regenCapMax_ || regenCap_ < regenCapMin_ || regenCap_ > regenCapMax_
        ) revert InvalidParameter();
        staking = IImdoStaking(staking_);
        opsWallet = opsWallet_;
        offsetsSafe = offsetsSafe_;
        regenSafe = regenSafe_;
        poolManager = IPoolManager(manager_);
        maxEthPerBuy = maxEthPerBuy_;
        slippageBps = slippageBps_;
        cooldown = cooldown_;
        regenCap = regenCap_;
        regenCapMin = regenCapMin_;
        regenCapMax = regenCapMax_;
        _imdLeg.key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(imd), imdFee, int24(imdTickSpacing), IHooks(imdHooks));
        // Permit constructor-only manifest inspection without chain state. Processing fails closed
        // until real dependencies and an initialized pool exist. The manual script checks them first.
        if (manager_.code.length != 0) {
            (_imdLeg.checkpointSqrtPriceX96,,,) = poolManager.getSlot0(_imdLeg.key.toId());
            if (_imdLeg.checkpointSqrtPriceX96 != 0) _imdLeg.checkpointAt = uint64(block.timestamp);
        }
    }

    receive() external payable {}

    /// @notice The only mutable configuration, controlled by the off-chain REGEN custodian.
    function setRegenCap(uint256 cap) external nonReentrant {
        if (msg.sender != regenSafe) revert Unauthorized();
        if (cap < regenCapMin || cap > regenCapMax) revert InvalidParameter();
        emit RegenCapSet(regenCap, cap);
        regenCap = cap;
    }

    function process() external nonReentrant {
        uint64 availableAt = lastProcessed + cooldown;
        if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        _ensurePool();
        uint256 amount = unsplitEth();
        uint256 cap = maxEthPerBuy * BPS * BPS / (IMD_BPS * (BPS - KEEPER_BPS));
        if (amount > cap) amount = cap;
        if (amount == 0 && _imdLeg.pending == 0 && pendingRegen == 0) revert NothingToProcess();
        lastProcessed = uint64(block.timestamp);
        uint256 bounty;
        if (amount != 0) {
            bounty = amount * KEEPER_BPS / BPS;
            uint256 net = amount - bounty;
            uint256 ops = net * OPS_BPS / BPS;
            uint256 offsets = net * OFFSETS_BPS / BPS;
            uint256 regen = net * REGEN_BPS / BPS;
            uint256 imd = net - ops - offsets - regen;
            uint256 epoch = block.timestamp / EPOCH_DURATION;
            uint256 used = regenAccrued[epoch];
            uint256 available = regenCap > used ? regenCap - used : 0;
            uint256 accepted = regen < available ? regen : available;
            uint256 overflow = regen - accepted;
            regenAccrued[epoch] = used + accepted;
            pendingRegen += accepted;
            _imdLeg.pending += imd + overflow;
            opsOwed += ops;
            offsetsOwed += offsets;
            keeperOwed[msg.sender] += bounty;
            totalKeeperOwed += bounty;
            emit Split(amount, bounty, ops, offsets, accepted, imd + overflow);
            emit RegenAccrued(epoch, accepted, overflow);
        }
        _inProcess = true;
        _executeImd();
        uint256 regenPending = pendingRegen;
        if (regenPending != 0) {
            pendingRegen = 0;
            try staking.notifyRegen{value: regenPending}() {
                emit RegenSent(regenPending);
            } catch (bytes memory reason) {
                pendingRegen = regenPending;
                emit RegenDeferred(regenPending, reason);
            }
        }
        _inProcess = false;
        if (bounty != 0) {
            keeperOwed[msg.sender] -= bounty;
            totalKeeperOwed -= bounty;
            (bool ok,) = msg.sender.call{value: bounty, gas: 100_000}("");
            if (ok) {
                emit KeeperPaid(msg.sender, bounty);
            } else {
                keeperOwed[msg.sender] += bounty;
                totalKeeperOwed += bounty;
                emit KeeperPaymentDeferred(msg.sender, bounty);
            }
        }
    }

    function payOps() external nonReentrant {
        if (msg.sender != opsWallet) revert Unauthorized();
        uint256 amount = opsOwed;
        if (amount == 0) revert NothingOwed();
        opsOwed = 0;
        _pay(opsWallet, amount);
        emit OpsPaid(amount);
    }

    function payOffsets() external nonReentrant {
        if (msg.sender != offsetsSafe) revert Unauthorized();
        uint256 amount = offsetsOwed;
        if (amount == 0) revert NothingOwed();
        offsetsOwed = 0;
        _pay(offsetsSafe, amount);
        emit OffsetsPaid(amount);
    }

    function claimKeeper(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 amount = keeperOwed[msg.sender];
        if (amount == 0) revert NothingOwed();
        keeperOwed[msg.sender] = 0;
        totalKeeperOwed -= amount;
        _pay(recipient, amount);
        emit KeeperPaid(msg.sender, amount);
    }

    function _pay(address recipient, uint256 amount) private {
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TeamTransferFailed();
    }

    function flushRewards() external nonReentrant {
        address token = Currency.unwrap(_imdLeg.key.currency1);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        IERC20(token).forceApprove(address(staking), balance);
        staking.notifyReward(token, balance);
        IERC20(token).forceApprove(address(staking), 0);
        emit RewardsFlushed(token, balance);
    }

    function unsplitEth() public view returns (uint256) {
        return address(this).balance - opsOwed - offsetsOwed - totalKeeperOwed - _imdLeg.pending - pendingRegen;
    }

    function leg(uint8 id) external view returns (Leg memory) {
        if (id != LEG_IMD) revert InvalidParameter();
        return _imdLeg;
    }

    /// @notice Checkpoint floor relaxes deterministically with age; the current spot is always a floor.
    /// @dev cp * 7 days / (7 days + age) prevents the permanent stale-checkpoint stall.
    function quoteMinOut(uint8 id, uint256 ethIn) public view returns (uint256) {
        if (id != LEG_IMD) revert InvalidParameter();
        Leg storage l = _imdLeg;
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(l.key.toId());
        if (sqrtPriceX96 == 0 || l.checkpointSqrtPriceX96 == 0) revert InvalidParameter();
        uint256 checkpointFloor = FullMath.mulDiv(
            l.checkpointSqrtPriceX96, CHECKPOINT_DECAY, CHECKPOINT_DECAY + block.timestamp - l.checkpointAt
        );
        if (sqrtPriceX96 < checkpointFloor) sqrtPriceX96 = uint160(checkpointFloor);
        uint24 swapFee = protocolFee.getZeroForOneFee().calculateSwapFee(lpFee);
        uint256 afterFee = ethIn - FullMath.mulDiv(ethIn, swapFee, LPFeeLibrary.MAX_LP_FEE);
        uint256 output = FullMath.mulDiv(afterFee, sqrtPriceX96, FixedPoint96.Q96);
        output = FullMath.mulDiv(output, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(output, BPS - slippageBps, BPS);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_inProcess) revert NotProcessing();
        uint256 ethIn = abi.decode(data, (uint256));
        uint256 minOut = quoteMinOut(LEG_IMD, ethIn);
        if (minOut == 0) revert InvalidParameter();
        BalanceDelta delta =
            poolManager.swap(_imdLeg.key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), "");
        if (delta.amount0() >= 0 || uint256(-int256(delta.amount0())) != ethIn) revert PartialFill();
        if (delta.amount1() <= 0) revert InsufficientOutput(0, minOut);
        uint256 amountOut = uint256(uint128(delta.amount1()));
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        poolManager.settle{value: ethIn}();
        poolManager.take(_imdLeg.key.currency1, address(this), amountOut);
        return abi.encode(amountOut);
    }

    /// @dev Self-call makes swap and reward notification atomic and isolates failure from other legs.
    function executeImd(uint256 ethIn) external returns (uint256 out) {
        if (msg.sender != address(this) || !_inProcess) revert NotProcessing();
        out = abi.decode(poolManager.unlock(abi.encode(ethIn)), (uint256));
        address token = Currency.unwrap(_imdLeg.key.currency1);
        IERC20(token).forceApprove(address(staking), out);
        staking.notifyReward(token, out);
        IERC20(token).forceApprove(address(staking), 0);
    }

    function _executeImd() private {
        Leg storage l = _imdLeg;
        uint256 gap = cooldown > MAX_FAILURE_GAP ? cooldown : MAX_FAILURE_GAP;
        if (l.failures != 0 && block.timestamp > uint256(l.lastFailure) + gap) _resetFailures();
        uint256 cap = l.retryCap == 0 ? maxEthPerBuy : l.retryCap;
        uint256 ethIn = l.pending < cap ? l.pending : cap;
        if (ethIn < MIN_ETH_PER_BUY) {
            _resetFailures();
            return;
        }
        try this.executeImd(ethIn) returns (uint256 out) {
            l.pending -= ethIn;
            _resetFailures();
            (l.checkpointSqrtPriceX96,,,) = poolManager.getSlot0(l.key.toId());
            l.checkpointAt = uint64(block.timestamp);
            emit LegBought(LEG_IMD, Currency.unwrap(l.key.currency1), ethIn, out);
        } catch (bytes memory reason) {
            emit LegFailed(LEG_IMD, ethIn, reason);
            if (l.failures == 0) l.failingSince = uint64(block.timestamp);
            l.lastFailure = uint64(block.timestamp);
            if (l.failures < MIN_FAILURES) ++l.failures;
            l.retryCap = ethIn / 2;
            if (l.retryCap < MIN_ETH_PER_BUY) l.retryCap = MIN_ETH_PER_BUY;
        }
    }

    function _resetFailures() private {
        _imdLeg.failingSince = 0;
        _imdLeg.lastFailure = 0;
        _imdLeg.failures = 0;
        _imdLeg.retryCap = 0;
    }

    function _ensurePool() private {
        if (
            address(poolManager).code.length == 0 || address(staking).code.length == 0
                || Currency.unwrap(_imdLeg.key.currency1).code.length == 0
        ) revert PoolUnavailable();
        (uint160 price,,,) = poolManager.getSlot0(_imdLeg.key.toId());
        if (price == 0) revert PoolUnavailable();
        if (_imdLeg.checkpointSqrtPriceX96 == 0) {
            _imdLeg.checkpointSqrtPriceX96 = price;
            _imdLeg.checkpointAt = uint64(block.timestamp);
            emit CheckpointSeeded(price);
        }
    }
}
