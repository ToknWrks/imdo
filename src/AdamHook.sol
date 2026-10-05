// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title AdamHook
/// @notice Uniswap v4 hook for the single ETH/ADAM pool. Charges a fee in ETH on every buy and sell and
/// forwards it to the Treasury inside the swap, with no other logic on the swap path.
///
/// Fee schedule (basis points of the ETH leg of the swap):
///   - anti-snipe: 20.00% at the first filled swap, decaying linearly to `feeBps` over 30 minutes;
///   - steady state: `feeBps`, 1.50% at deployment. The owner can only lower it, never raise it.
///
/// How the ETH is taken, by swap type (ETH is always currency0 of the pool):
///   - buy, exact input  (ETH specified):  beforeSwap takes fee% of the ETH in; the pool swaps the rest.
///   - buy, exact output (ADAM specified): afterSwap grosses up the pool's ETH charge by fee/(1-fee).
///   - sell, exact input (ADAM specified): afterSwap takes fee% of the ETH the pool pays out.
///   - sell, exact output (ETH specified): beforeSwap grosses up the requested ETH by fee/(1-fee).
/// ETH-specified swaps must fill completely or revert, including all fee transfers.
///
/// Trust model: the owner (Ownable2Step) can lower the fee and is the only account that may initialize the
/// pool. Nothing else is privileged; the hook never holds funds (every fee is taken straight to Treasury).
contract AdamHook is IHooks, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    /// @notice Fee at the first filled swap.
    uint16 public constant LAUNCH_FEE_BPS = 2000;
    /// @notice Length of the linear anti-snipe decay.
    uint32 public constant DECAY_DURATION = 30 minutes;
    /// @notice Steady-state fee at deployment (owner may only lower it).
    uint16 public constant INITIAL_FEE_BPS = 150;

    IPoolManager public immutable poolManager;
    address public immutable adam;
    address public immutable treasury;

    /// @notice Current steady-state fee in basis points.
    uint16 public feeBps = INITIAL_FEE_BPS;
    /// @notice Timestamp of the first filled swap; 0 until trading starts.
    uint64 public launchTimestamp;
    bool public initialized;
    /// @notice Id of the one pool this hook serves.
    PoolId public poolId;

    event FeeLowered(uint16 oldFeeBps, uint16 newFeeBps);
    event PoolInitialized(PoolId indexed poolId);
    event PoolLaunched(PoolId indexed poolId, uint64 launchTimestamp);
    event FeeTaken(bool indexed isBuy, uint256 ethAmount, uint256 fee, uint256 feeBps);

    error NotPoolManager();
    error HookNotImplemented();
    error AlreadyInitialized();
    error InvalidPool();
    error OnlyOwnerCanInitialize();
    error FeeNotLower(uint16 current, uint16 requested);
    error ZeroAddress();
    error PartialFillNotSupported();
    error EmptySwap();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address adam_, address treasury_, address owner_) Ownable(owner_) {
        if (address(poolManager_) == address(0) || adam_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        adam = adam_;
        treasury = treasury_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    /// @notice Lower the steady-state fee. Raising is impossible by construction.
    function lowerFee(uint16 newFeeBps) external onlyOwner {
        uint16 current = feeBps;
        if (newFeeBps >= current) revert FeeNotLower(current, newFeeBps);
        feeBps = newFeeBps;
        emit FeeLowered(current, newFeeBps);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Fee that applies to a swap in the current block, in basis points of the ETH leg.
    function currentFeeBps() public view returns (uint256) {
        uint256 base = feeBps;
        uint256 launch = launchTimestamp;
        if (launch == 0) return LAUNCH_FEE_BPS;
        uint256 elapsed = block.timestamp - launch;
        if (elapsed >= DECAY_DURATION) return base;
        if (base >= LAUNCH_FEE_BPS) return base;
        return base + ((LAUNCH_FEE_BPS - base) * (DECAY_DURATION - elapsed)) / DECAY_DURATION;
    }

    /// @notice Permissions encoded in this hook's address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The address flags a deployment of this hook must carry (for salt mining).
    function requiredFlags() external pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @dev Only the owner may create the pool, exactly once, and it must be native ETH / ADAM.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        if (sender != owner()) revert OnlyOwnerCanInitialize();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != adam) revert InvalidPool();
        initialized = true;
        poolId = key.toId();
        emit PoolInitialized(poolId);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (launchTimestamp == 0) {
            launchTimestamp = uint64(block.timestamp);
            emit PoolLaunched(poolId, launchTimestamp);
        }
        // ETH (currency0) is the specified currency for exact-input buys and exact-output sells.
        if (!_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 ethAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _takeFee(params, ethAmount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (delta == BalanceDelta.wrap(0)) revert EmptySwap();
        // afterSwap may only adjust the unspecified currency. Refuse partial fills when an ETH fee
        // was prepaid, so a price limit or exhausted liquidity can never tax an unfilled request.
        if (_ethIsSpecified(params)) {
            uint256 requested =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 prepaidFee = _fee(requested, params.amountSpecified > 0);
            int256 expected =
                params.amountSpecified < 0 ? -int256(requested - prepaidFee) : int256(requested + prepaidFee);
            if (int256(delta.amount0()) != expected) revert PartialFillNotSupported();
            return (IHooks.afterSwap.selector, 0);
        }
        int128 ethDelta = delta.amount0();
        uint256 ethAmount = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        uint256 fee = _takeFee(params, ethAmount);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev zeroForOne == exactInput  <=>  ETH is the specified currency.
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    /// @dev Compute the fee on `ethAmount`, and move it from the PoolManager straight to the Treasury.
    function _fee(uint256 ethAmount, bool exactOutput) private view returns (uint256) {
        uint256 bps = currentFeeBps();
        return (ethAmount * bps) / (exactOutput ? BPS - bps : BPS);
    }

    function _takeFee(SwapParams calldata params, uint256 ethAmount) private returns (uint256 fee) {
        uint256 bps = currentFeeBps();
        fee = _fee(ethAmount, params.amountSpecified > 0);
        if (fee != 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, treasury, fee);
        emit FeeTaken(params.zeroForOne, ethAmount, fee, bps);
    }
}
