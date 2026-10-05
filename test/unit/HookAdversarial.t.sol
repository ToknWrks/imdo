// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "../utils/LocalV4.sol";
import {AdamHook} from "src/AdamHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract HookAdversarialTest is LocalV4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactInputSellChargesGrossEthAtAnyDecayTime(uint256 fraction, uint32 elapsed, uint16 base)
        public
    {
        uint256 bought = uint256(uint128(buyExactIn(2 ether).amount1()));
        elapsed = uint32(bound(elapsed, 0, 3600));
        base = uint16(bound(base, 0, 149));
        vm.prank(hookOwner);
        hook.lowerFee(base);
        vm.warp(uint256(hook.launchTimestamp()) + elapsed);
        uint256 amount = bound(fraction, bought / 1000, bought);
        uint256 beforeTreasury = address(treasury).balance;
        uint256 beforeTrader = address(this).balance;
        uint256 beforeManager = address(poolManager).balance;
        BalanceDelta d = sellExactIn(amount);
        uint256 gross = beforeManager - address(poolManager).balance;
        uint256 net = address(this).balance - beforeTrader;
        uint256 tax = address(treasury).balance - beforeTreasury;
        assertGt(gross, 0);
        assertEq(net + tax, gross, "all ETH leaving manager accounted for");
        assertEq(tax, gross * hook.currentFeeBps() / 10_000);
        assertEq(int256(d.amount1()), -int256(amount));
        assertEq(uint256(uint128(d.amount0())), net);
        assertEq(address(hook).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactOutputSellDeliversRequestedNetAndGrossFee(uint256 requested, uint32 elapsed) public {
        buyExactIn(2 ether);
        vm.warp(uint256(hook.launchTimestamp()) + bound(elapsed, 0, 3600));
        requested = bound(requested, 1 gwei, 0.5 ether);
        uint256 traderBefore = address(this).balance;
        uint256 managerBefore = address(poolManager).balance;
        uint256 feesBefore = address(treasury).balance;
        BalanceDelta d = sellExactOut(requested);
        uint256 tax = address(treasury).balance - feesBefore;
        uint256 gross = managerBefore - address(poolManager).balance;
        assertEq(address(this).balance - traderBefore, requested);
        assertEq(uint256(uint128(d.amount0())), requested);
        assertEq(requested + tax, gross);
        assertApproxEqAbs(tax, gross * hook.currentFeeBps() / 10_000, 1);
        assertLt(d.amount1(), 0);
    }

    function test_partialExactOutputSellRevertsFeeAndPoolMovement() public {
        buyExactIn(2 ether);
        uint256 snapshot = vm.snapshotState();
        sellExactOut(0.01 ether);
        (uint160 limit,,,) = IPoolManager(address(poolManager)).getSlot0(adamKey.toId());
        assertTrue(vm.revertToState(snapshot));
        uint256 traderBefore = address(this).balance;
        uint256 managerBefore = address(poolManager).balance;
        uint256 treasuryBefore = address(treasury).balance;
        uint256 adamBefore = adam.balanceOf(address(this));
        (uint160 priceBefore,,,) = IPoolManager(address(poolManager)).getSlot0(adamKey.toId());
        vm.expectRevert(); // PoolManager wraps the hook's PartialFillNotSupported error.
        swapRouter.swap(adamKey, SwapParams(false, 0.1 ether, limit), PoolSwapTest.TestSettings(false, false), "");
        assertEq(address(this).balance, traderBefore);
        assertEq(address(poolManager).balance, managerBefore);
        assertEq(address(treasury).balance, treasuryBefore);
        assertEq(adam.balanceOf(address(this)), adamBefore);
        (uint160 priceAfter,,,) = IPoolManager(address(poolManager)).getSlot0(adamKey.toId());
        assertEq(priceAfter, priceBefore);
    }

    function test_decayBoundariesAndNoFeeResurrection() public {
        buyExactIn(1 ether);
        uint256 launch = hook.launchTimestamp();
        vm.warp(launch + 1799);
        assertEq(hook.currentFeeBps(), 151);
        vm.warp(launch + 1800);
        assertEq(hook.currentFeeBps(), 150);
        vm.prank(hookOwner);
        hook.lowerFee(0);
        vm.warp(launch + 1801);
        uint256 before = address(treasury).balance;
        buyExactIn(0.1 ether);
        sellExactOut(0.01 ether);
        assertEq(address(treasury).balance, before);
        vm.prank(hookOwner);
        vm.expectRevert(abi.encodeWithSelector(AdamHook.FeeNotLower.selector, uint16(0), uint16(1)));
        hook.lowerFee(1);
    }
}
