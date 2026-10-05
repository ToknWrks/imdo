// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "../utils/LocalV4.sol";
import {AdamHook} from "../../src/AdamHook.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";
import {AdamDistributor} from "../../src/AdamDistributor.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract RevisionTest is LocalV4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _fund(uint256 amount) private {
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok);
    }

    function test_sandwichCannotLowerCheckpointFloor() public {
        _fund(1 ether);
        treasury.process();
        uint256 checkpoint = treasury.leg(0).checkpointSqrtPriceX96;
        vm.warp(block.timestamp + COOLDOWN);
        _fund(2.3 ether);
        uint256 fairFloor = treasury.quoteMinOut(0, 1 ether);
        uint256 before = imd.balanceOf(address(distributor));
        BalanceDelta pump = _swap(imdKey, true, -100 ether, 100 ether);
        assertEq(treasury.quoteMinOut(0, 1 ether), fairFloor, "pump cannot lower minOut");
        treasury.process();
        imd.approve(address(swapRouter), type(uint256).max);
        _swap(imdKey, false, -int256(pump.amount1()), 0);
        assertEq(treasury.leg(0).pending, 1 ether);
        assertEq(treasury.leg(0).checkpointSqrtPriceX96, checkpoint, "failure cannot reset reference");
        assertEq(imd.balanceOf(address(distributor)), before);
        // Recovery retries less ETH, then drains the rest without rerouting.
        vm.warp(block.timestamp + COOLDOWN);
        treasury.process();
        assertGt(imd.balanceOf(address(distributor)), before);
        assertEq(treasury.leg(0).retryCap, 0);
    }

    function test_constructorCheckpointAlsoProtectsFirstProcess() public {
        uint256 fairFloor = treasury.quoteMinOut(0, 1 ether);
        _swap(imdKey, true, -100 ether, 100 ether);
        _fund(2.3 ether);
        treasury.process();
        assertEq(treasury.quoteMinOut(0, 1 ether), fairFloor);
        assertEq(treasury.leg(0).pending, 1 ether);
        assertEq(imd.balanceOf(address(distributor)), 0);
    }

    function test_partialInputBuyRevertsAndReturnsEntireFee() public {
        warpPastDecay();
        uint256 snap = vm.snapshotState();
        buyExactIn(1 ether);
        (uint160 limit,,,) = IPoolManager(address(poolManager)).getSlot0(adamKey.toId());
        vm.revertToState(snap);
        uint256 before = address(treasury).balance;
        uint256 traderBefore = address(this).balance;
        vm.expectRevert(); // v4 wraps PartialFillNotSupported in HookCallFailed
        swapRouter.swap{value: 10 ether}(
            adamKey, SwapParams(true, -10 ether, limit), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(address(treasury).balance, before);
        assertEq(address(this).balance, traderBefore);
    }

    function test_emptySellCannotChargeFeeOrStartClock() public {
        uint256 before = address(treasury).balance;
        vm.expectRevert(); // no ETH liquidity yet; original code charged 0.2 ETH for this empty fill
        sellExactOut(1 ether);
        assertEq(address(treasury).balance, before);
        assertEq(hook.launchTimestamp(), 0);
    }

    function test_exactOutputAndInputBuySameGrossFeeAtLaunch() public {
        uint256 snap = vm.snapshotState();
        uint256 want = uint256(uint128(buyExactIn(1 ether).amount1()));
        vm.revertToState(snap);
        BalanceDelta d = buyExactOut(want, 2 ether);
        assertEq(address(treasury).balance, 0.2 ether);
        assertEq(d.amount0(), -1 ether);
    }

    function testFuzz_exactOutputFeesAreGrossRate(uint32 elapsed, uint128 requested) public {
        buyExactIn(1);
        elapsed = uint32(bound(elapsed, 0, 1 hours));
        requested = uint128(bound(requested, 1e18, 1_000_000e18));
        vm.warp(uint256(hook.launchTimestamp()) + elapsed);
        uint256 bps = hook.currentFeeBps();
        uint256 before = address(treasury).balance;
        BalanceDelta d = buyExactOut(requested, 2 ether);
        uint256 gross = uint256(uint128(-d.amount0()));
        assertApproxEqAbs(address(treasury).balance - before, gross * bps / 10_000, 1);
    }

    function test_firstFilledSwapStartsFullDecayAfterDeploymentDelay() public {
        vm.warp(block.timestamp + 7 days);
        assertEq(hook.launchTimestamp(), 0);
        assertEq(hook.currentFeeBps(), 2000);
        buyExactIn(1 ether);
        assertEq(address(treasury).balance, 0.2 ether);
        assertEq(hook.launchTimestamp(), block.timestamp);
        vm.warp(uint256(hook.launchTimestamp()) + 15 minutes);
        assertEq(hook.currentFeeBps(), 1075);
    }

    function test_dustWaitsWithoutStartingFailureStreak() public {
        _fund(10);
        treasury.process();
        assertEq(treasury.leg(0).pending, 4);
        assertEq(treasury.leg(1).pending, 5);
        assertEq(treasury.leg(0).failingSince, 0);
        assertEq(treasury.leg(1).failingSince, 0);
        vm.warp(block.timestamp + COOLDOWN);
        _fund(1 ether);
        treasury.process();
        assertEq(treasury.leg(0).pending, 0);
        assertEq(treasury.leg(1).pending, 0);
    }

    function test_twoIsolatedFailuresDoNotReroute() public {
        pnkstrHook.setTaxBps(1500);
        _fund(1 ether);
        treasury.process();
        uint256 since = treasury.leg(1).failingSince;
        pnkstrHook.setTaxBps(1000);
        vm.warp(since + 3 days);
        pnkstrHook.setTaxBps(1500);
        _fund(1 ether);
        treasury.process();
        assertEq(treasury.leg(1).pending, 0.9 ether);
        assertEq(treasury.leg(1).failures, 1);
        assertEq(treasury.leg(1).failingSince, since + 3 days);
        assertEq(treasury.leg(0).pending, 0);
    }

    function test_thinPoolRecoversAtSmallerSize() public {
        MockERC20 thin = new MockERC20("THIN", "T", 18);
        thin.mint(address(this), 1e36);
        thin.approve(address(lpRouter), type(uint256).max);
        PoolKey memory key = imdKey;
        key.currency1 = Currency.wrap(address(thin));
        _initAndSeed(key, 54_000, -887_200, 887_200, 20 ether);
        AdamDistributor d =
            new AdamDistributor(address(adam), address(thin), address(pnkstr), address(poolManager), address(0));
        AdamTreasury t = new AdamTreasury(
            address(d),
            teamWallet,
            address(poolManager),
            address(thin),
            10_000,
            200,
            address(0),
            0,
            address(pnkstr),
            0,
            60,
            address(pnkstrHook),
            1000,
            1 ether,
            300,
            COOLDOWN
        );
        (bool ok,) = address(t).call{value: 2.3 ether}("");
        require(ok);
        t.process();
        assertEq(thin.balanceOf(address(d)), 0);
        assertEq(t.leg(0).pending, 1 ether);
        assertEq(t.leg(0).retryCap, 0.5 ether);
        vm.warp(block.timestamp + COOLDOWN);
        t.process();
        assertGt(thin.balanceOf(address(d)), 0);
        assertLt(t.leg(0).pending, 1 ether);
        assertEq(t.leg(0).failingSince, 0);
        assertEq(t.leg(0).retryCap, 0);
    }

    /// @dev Documented exclusion deviation: neither contract has any entry point that can stake.
    function test_hookAndTreasuryHaveNoStakingEntryPoint() public {
        assertFalse(distributor.isExcluded(address(hook)));
        assertFalse(distributor.isExcluded(address(treasury)));
        (bool hookCanStake,) = address(hook).call(abi.encodeCall(AdamDistributor.stake, (1)));
        (bool treasuryCanStake,) = address(treasury).call(abi.encodeCall(AdamDistributor.stake, (1)));
        assertFalse(hookCanStake);
        assertFalse(treasuryCanStake);
    }
}
