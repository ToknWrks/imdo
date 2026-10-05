// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Local stand-in for the (unverified) PNKSTR hook: afterSwap + afterSwapReturnDelta, taking
/// `taxBps` of the unspecified currency on exact-input buys (the output token), kept by the hook.
/// `setTaxBps` lets tests simulate the hook raising its tax, and `setRevertSwaps` a dead pool.
contract MockTaxHook is IHooks {
    IPoolManager public immutable poolManager;
    uint256 public taxBps;
    bool public revertSwaps;

    constructor(IPoolManager poolManager_, uint256 taxBps_) {
        poolManager = poolManager_;
        taxBps = taxBps_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function setTaxBps(uint256 newTaxBps) external {
        taxBps = newTaxBps;
    }

    function setRevertSwaps(bool value) external {
        revertSwaps = value;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(poolManager), "not pm");
        require(!revertSwaps, "MockTaxHook: swaps disabled");
        // Only tax exact-input buys (ETH in, token out), like the PNKSTR hook on the path we use.
        if (!(params.zeroForOne && params.amountSpecified < 0)) return (IHooks.afterSwap.selector, 0);
        int128 out = delta.amount1();
        if (out <= 0) return (IHooks.afterSwap.selector, 0);
        uint256 tax = (uint256(uint128(out)) * taxBps) / 10_000;
        if (tax != 0) poolManager.take(key.currency1, address(this), tax);
        return (IHooks.afterSwap.selector, int128(uint128(tax)));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert("n/a");
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert("n/a");
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("n/a");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert("n/a");
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("n/a");
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert("n/a");
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert("n/a");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("n/a");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("n/a");
    }
}
