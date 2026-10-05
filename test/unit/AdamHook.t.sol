// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LocalV4} from "../utils/LocalV4.sol";
import {AdamHook} from "../../src/AdamHook.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";

contract AdamHookTest is LocalV4 {
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ deployment & permissions

    function test_addressCarriesExactlyTheRequiredFlags() public view {
        uint160 flags = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(flags, hook.requiredFlags());
        assertEq(flags, deployScript.hookFlags());
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_INITIALIZE_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
    }

    function test_constructorRejectsUnflaggedAddress() public {
        vm.expectRevert();
        new AdamHook(poolManager, address(adam), address(treasury), hookOwner);
    }

    function test_initialState() public view {
        assertEq(hook.feeBps(), 150);
        assertEq(hook.owner(), hookOwner);
        assertEq(hook.treasury(), address(treasury));
        assertEq(hook.adam(), address(adam));
        assertEq(hook.launchTimestamp(), 0);
        assertTrue(hook.initialized());
        assertEq(hook.currentFeeBps(), 2000, "20% at launch");
    }

    // ------------------------------------------------------------------ pool initialization rules

    function _freshHook(address owner_) internal returns (AdamHook fresh) {
        bytes memory args = abi.encode(address(poolManager), address(adam), address(treasury), owner_);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), deployScript.hookFlags(), type(AdamHook).creationCode, args);
        fresh = new AdamHook{salt: salt}(poolManager, address(adam), address(treasury), owner_);
        assertEq(address(fresh), expected);
    }

    function _keyFor(AdamHook h, address currency1, uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(h))
        });
    }

    function test_initializeRequiresOwner() public {
        AdamHook fresh = _freshHook(hookOwner);
        PoolKey memory key = _keyFor(fresh, address(adam), 3000);
        vm.prank(alice);
        vm.expectRevert();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        assertEq(fresh.launchTimestamp(), 0);

        vm.prank(hookOwner);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        assertEq(fresh.launchTimestamp(), 0);
        assertTrue(fresh.initialized());
    }

    function test_initializeOnlyOnce() public {
        PoolKey memory second = _keyFor(hook, address(adam), 3000);
        vm.prank(hookOwner);
        vm.expectRevert();
        poolManager.initialize(second, TickMath.getSqrtPriceAtTick(0));
    }

    function test_initializeRejectsWrongPair() public {
        AdamHook fresh = _freshHook(hookOwner);
        PoolKey memory wrong = _keyFor(fresh, address(imd), 0);
        vm.prank(hookOwner);
        vm.expectRevert();
        poolManager.initialize(wrong, TickMath.getSqrtPriceAtTick(0));
    }

    function test_callbacksRejectNonPoolManager() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(AdamHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), adamKey, p, "");
        vm.expectRevert(AdamHook.NotPoolManager.selector);
        hook.afterSwap(address(this), adamKey, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(AdamHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), adamKey, 0);
    }

    // ------------------------------------------------------------------ fee schedule

    function test_decaySchedule() public {
        buyExactIn(1);
        uint256 launch = hook.launchTimestamp();
        assertEq(hook.currentFeeBps(), 2000);
        vm.warp(launch + 15 minutes);
        assertEq(hook.currentFeeBps(), 150 + (1850 * 15 minutes) / (30 minutes)); // 1075
        vm.warp(launch + 30 minutes - 1);
        assertEq(hook.currentFeeBps(), 151);
        vm.warp(launch + 30 minutes);
        assertEq(hook.currentFeeBps(), 150);
        vm.warp(launch + 365 days);
        assertEq(hook.currentFeeBps(), 150);
    }

    function testFuzz_decayIsMonotoneAndBounded(uint32 a, uint32 b) public {
        a = uint32(bound(a, 0, 2 hours));
        b = uint32(bound(b, 0, 2 hours));
        if (a > b) (a, b) = (b, a);
        buyExactIn(1);
        uint256 launch = hook.launchTimestamp();
        vm.warp(launch + a);
        uint256 feeA = hook.currentFeeBps();
        vm.warp(launch + b);
        uint256 feeB = hook.currentFeeBps();
        assertGe(feeA, feeB);
        assertLe(feeA, 2000);
        assertGe(feeB, 150);
    }

    function test_lowerFee() public {
        vm.prank(hookOwner);
        hook.lowerFee(100);
        assertEq(hook.feeBps(), 100);
        warpPastDecay();
        assertEq(hook.currentFeeBps(), 100);
    }

    function test_lowerFeeToZeroDisablesFee() public {
        vm.prank(hookOwner);
        hook.lowerFee(0);
        warpPastDecay();
        uint256 before = address(treasury).balance;
        buyExactIn(1 ether);
        assertEq(address(treasury).balance, before);
    }

    function test_lowerFeeDuringDecayKeepsDecaying() public {
        buyExactIn(1);
        vm.prank(hookOwner);
        hook.lowerFee(100);
        vm.warp(hook.launchTimestamp() + 15 minutes);
        assertEq(hook.currentFeeBps(), 100 + 1900 / 2);
    }

    function test_feeCannotBeRaisedOrKept() public {
        vm.startPrank(hookOwner);
        vm.expectRevert(abi.encodeWithSelector(AdamHook.FeeNotLower.selector, 150, 151));
        hook.lowerFee(151);
        vm.expectRevert(abi.encodeWithSelector(AdamHook.FeeNotLower.selector, 150, 150));
        hook.lowerFee(150);
        hook.lowerFee(50);
        vm.expectRevert(abi.encodeWithSelector(AdamHook.FeeNotLower.selector, 50, 100));
        hook.lowerFee(100);
        vm.stopPrank();
    }

    function test_onlyOwnerLowersFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.lowerFee(100);
    }

    function test_twoStepOwnershipTransfer() public {
        vm.prank(hookOwner);
        hook.transferOwnership(alice);
        assertEq(hook.owner(), hookOwner);
        assertEq(hook.pendingOwner(), alice);
        vm.prank(alice);
        hook.acceptOwnership();
        assertEq(hook.owner(), alice);
        vm.prank(alice);
        hook.lowerFee(10);
        assertEq(hook.feeBps(), 10);
    }

    // ------------------------------------------------------------------ fee collection on every swap type

    function test_antiSnipeFeeAtLaunchIs20Percent() public {
        uint256 before = address(treasury).balance;
        BalanceDelta d = buyExactIn(1 ether);
        assertEq(address(treasury).balance - before, 0.2 ether);
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
    }

    function test_buyExactInput_takes1_5PercentOfEthIn() public {
        warpPastDecay();
        uint256 tBefore = address(treasury).balance;
        uint256 pmBefore = address(poolManager).balance;
        BalanceDelta d = buyExactIn(1 ether);
        assertEq(address(treasury).balance - tBefore, 0.015 ether, "fee to treasury");
        assertEq(address(poolManager).balance - pmBefore, 0.985 ether, "pool keeps the rest");
        assertEq(d.amount0(), -1 ether, "buyer pays exactly the input");
        assertGt(d.amount1(), 0);
        assertEq(address(hook).balance, 0, "hook never holds ETH");
    }

    function test_buyExactOutput_feeIsAddedOnTopOfEthIn() public {
        warpPastDecay();
        uint256 tBefore = address(treasury).balance;
        uint256 pmBefore = address(poolManager).balance;
        uint256 want = 1_000_000e18;
        BalanceDelta d = buyExactOut(want, 5 ether);
        uint256 poolIn = address(poolManager).balance - pmBefore;
        uint256 fee = address(treasury).balance - tBefore;
        assertEq(d.amount1(), int256(want), "exact ADAM out");
        assertEq(fee, (poolIn * 150) / (BPS - 150), "fee is 1.5% of gross buyer spend, rounded down");
        assertEq(uint256(uint128(-d.amount0())), poolIn + fee, "buyer pays pool amount plus fee");
    }

    function test_sellExactInput_takes1_5PercentOfEthOut() public {
        warpPastDecay();
        buyExactIn(2 ether);
        uint256 adamBal = adam.balanceOf(address(this));
        uint256 sellAmount = adamBal / 2;

        uint256 tBefore = address(treasury).balance;
        uint256 pmBefore = address(poolManager).balance;
        BalanceDelta d = sellExactIn(sellAmount);
        uint256 poolOut = pmBefore - address(poolManager).balance;
        uint256 fee = address(treasury).balance - tBefore;
        assertEq(d.amount1(), -int256(sellAmount));
        assertEq(fee, (poolOut * 150) / BPS, "fee is 1.5% of the ETH the pool paid");
        assertEq(uint256(uint128(d.amount0())), poolOut - fee, "seller receives the rest");
    }

    function test_sellExactOutput_feeIsAddedOnTopOfEthOut() public {
        warpPastDecay();
        buyExactIn(2 ether);
        uint256 tBefore = address(treasury).balance;
        uint256 pmBefore = address(poolManager).balance;
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = sellExactOut(0.5 ether);
        assertEq(d.amount0(), 0.5 ether, "seller receives exactly the requested ETH");
        assertEq(address(this).balance - ethBefore, 0.5 ether);
        uint256 fee = (0.5 ether * 150) / (BPS - 150);
        assertEq(address(treasury).balance - tBefore, fee, "1.5% of gross pool output, rounded down");
        assertEq(pmBefore - address(poolManager).balance, 0.5 ether + fee);
    }

    function testFuzz_buyFeeMatchesSchedule(uint256 ethIn, uint32 elapsed) public {
        ethIn = bound(ethIn, 1e12, 5 ether);
        elapsed = uint32(bound(elapsed, 0, 1 hours));
        buyExactIn(1);
        vm.warp(hook.launchTimestamp() + elapsed);
        uint256 expectedBps = hook.currentFeeBps();
        uint256 before = address(treasury).balance;
        buyExactIn(ethIn);
        assertEq(address(treasury).balance - before, (ethIn * expectedBps) / BPS);
    }

    function test_feeEventsAreEmitted() public {
        warpPastDecay();
        vm.expectEmit(true, false, false, true, address(hook));
        emit AdamHook.FeeTaken(true, 1 ether, 0.015 ether, 150);
        buyExactIn(1 ether);
    }
}
