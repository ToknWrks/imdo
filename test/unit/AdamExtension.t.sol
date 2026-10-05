// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ExtensionFixture, LockedStrategyMock} from "../utils/ExtensionFixture.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";
import {AdamTreasuryV2} from "../../src/AdamTreasuryV2.sol";
import {AdamDistributorV2} from "../../src/AdamDistributorV2.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract RejectingKeeper {
    function process(AdamTreasuryV2 t) external {
        t.process();
    }

    function claim(AdamTreasuryV2 t, address payable recipient) external {
        t.claimKeeper(recipient);
    }
}

/// @custom:x https://x.com/IaMaDamIMD
contract AdamExtensionTest is ExtensionFixture {
    function testThreeLegPullRewardsAndKeeper() public {
        stakeAlice(100_000_000e18);
        fundTreasury(1 ether);
        uint256 before = bob.balance;
        vm.prank(bob);
        t2.process();
        assertEq(bob.balance - before, 0.005 ether);
        assertEq(teamWallet.balance, 0);
        assertEq(t2.teamOwed(), 0.0995 ether);
        uint256 holders = 0.8955 ether;
        uint256 first = holders * 3333 / 10000;
        uint256 third = holders - 2 * first;
        assertApproxEqAbs(d2.earned(alice, address(0)), third, 1);
        assertEq(address(d2).balance, third);
        assertGt(d2.earned(alice, address(imd)), 0);
        assertGt(d2.earned(alice, address(pnkstr)), 0);
        vm.prank(alice);
        d2.claim();
        assertGt(imd.balanceOf(alice), 0);
        assertGt(pnkstr.balanceOf(alice), 0);
        assertEq(imdstr.balanceOf(alice), 0);
        uint256 due = d2.earned(alice, address(0));
        vm.prank(alice);
        uint256 got = d2.claimIMDSTR(due, 1, block.timestamp);
        assertEq(imdstr.balanceOf(alice), got);
        assertGt(got, 0);
        assertEq(d2.earned(alice, address(0)), 0);
        vm.prank(alice);
        vm.expectRevert(LockedStrategyMock.InvalidTransfer.selector);
        imdstr.transfer(bob, 1);
        vm.prank(bob);
        vm.expectRevert(AdamTreasury.InvalidParameter.selector);
        t2.payTeam();
        vm.prank(teamWallet);
        t2.payTeam();
        assertEq(teamWallet.balance, 0.0995 ether);
        assertEq(t2.unsplitEth(), 0);
    }

    function testReportWeightsAndStaleFallback() public {
        stakeAlice(100_000_000e18);
        submit(6500, 2000, 1500);
        fundTreasury(1 ether);
        t2.process();
        assertApproxEqAbs(d2.earned(alice, address(0)), 0.8955 ether * 1500 / 10000, 1);
        vm.warp(vm.getBlockTimestamp() + 26 hours + 1);
        fundTreasury(1 ether);
        t2.process();
        assertApproxEqAbs(
            d2.earned(alice, address(0)),
            0.8955 ether * 1500 / 10000 + 0.8955 ether - (0.8955 ether * 3333 / 10000) * 2,
            1
        );
    }

    function testSlippageDeadlineAndFailurePreserveClaim() public {
        stakeAlice(100_000_000e18);
        d2.notifyIMDSTR{value: 0.1 ether}(0);
        uint256 due = d2.earned(alice, address(0));
        vm.prank(alice);
        vm.expectRevert(AdamDistributorV2.Slippage.selector);
        d2.claimIMDSTR(due, type(uint128).max, block.timestamp);
        assertEq(d2.earned(alice, address(0)), due);
        assertEq(address(d2).balance, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert(AdamDistributorV2.InvalidSwap.selector);
        d2.claimIMDSTR(due, 1, block.timestamp - 1);
        vm.prank(bob);
        vm.expectRevert(AdamDistributorV2.InvalidSwap.selector);
        d2.claimIMDSTR(1, 1, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(AdamDistributorV2.InvalidSwap.selector);
        d2.claimIMDSTR(1, 0, block.timestamp);
        vm.prank(alice);
        d2.unstake(100_000_000e18);
        vm.prank(alice);
        d2.claimIMDSTR(due, 1, block.timestamp);
        assertGt(imdstr.balanceOf(alice), 0);
    }

    function testOneTimeDirectSwitchPreservesOldETHCredits() public {
        stakeAlice(100_000_000e18);
        d2.notifyIMDSTR{value: 0.1 ether}(0);
        uint256 oldDue = d2.earned(alice, address(0));
        vm.expectRevert(AdamDistributorV2.NotWhitelisted.selector);
        d2.enableDirectDistribution();
        imdstr.setDistributor(address(d2), true);
        vm.prank(bob);
        d2.enableDirectDistribution();
        vm.expectRevert(AdamDistributorV2.NotWhitelisted.selector);
        d2.enableDirectDistribution();
        fundTreasury(1 ether);
        t2.process();
        assertEq(d2.earned(alice, address(0)), oldDue);
        assertGt(d2.earned(alice, address(imdstr)), 0);
        vm.prank(alice);
        d2.claim();
        uint256 direct = imdstr.balanceOf(alice);
        assertGt(direct, 0);
        vm.prank(alice);
        d2.claimIMDSTR(oldDue, 1, block.timestamp);
        assertGt(imdstr.balanceOf(alice), direct);
    }

    function testLegFailureIsolationRetriesRerouteAndNoSecondBounty() public {
        stakeAlice(100_000_000e18);
        // Excess tax fails PNKSTR's floor. IMDSTR accrues ETH without buying yet.
        pnkstrHook.setTaxBps(2000);
        fundTreasury(1 ether);
        uint256 before = bob.balance;
        vm.prank(bob);
        t2.process();
        assertEq(bob.balance - before, 0.005 ether);
        assertEq(t2.leg(1).pending, 0.8955 ether * 3333 / 10000);
        assertGt(d2.earned(alice, address(imd)), 0);
        assertGt(d2.earned(alice, address(0)), 0);
        uint64 since = t2.leg(1).failingSince;
        for (uint256 h = 1; h <= 72; ++h) {
            vm.warp(uint256(since) + h * 1 hours);
            vm.prank(bob);
            t2.process();
        }
        assertEq(t2.leg(1).pending, 0);
        assertEq(t2.leg(2).pending, 0);
        assertEq(bob.balance - before, 0.005 ether);
        assertGt(d2.earned(alice, address(0)), 0.5 ether);
    }

    function testThirdLegFailureAfterWhitelistRevokedReroutes() public {
        stakeAlice(100_000_000e18);
        imdstr.setDistributor(address(d2), true);
        d2.enableDirectDistribution();
        imdstr.setDistributor(address(d2), false);
        fundTreasury(1 ether);
        t2.process();
        uint256 pending = t2.leg(2).pending;
        assertGt(pending, 0);
        assertGt(d2.earned(alice, address(imd)), 0);
        assertGt(d2.earned(alice, address(pnkstr)), 0);
        uint64 since = t2.leg(2).failingSince;
        for (uint256 h = 1; h <= 72; ++h) {
            vm.warp(uint256(since) + h * 1 hours);
            t2.process();
        }
        assertEq(t2.leg(2).pending, 0);
        assertEq(t2.leg(0).pending, pending);
        vm.warp(vm.getBlockTimestamp() + 600);
        t2.process();
        assertEq(t2.leg(0).pending, 0);
    }

    function testRejectingKeeperCreditsAreReservedAndPullable() public {
        RejectingKeeper keeper = new RejectingKeeper();
        fundTreasury(1 ether);
        keeper.process(t2);
        assertEq(t2.keeperOwed(address(keeper)), 0.005 ether);
        assertEq(t2.totalKeeperOwed(), 0.005 ether);
        assertEq(t2.unsplitEth(), 0);
        uint256 before = bob.balance;
        keeper.claim(t2, payable(bob));
        assertEq(bob.balance - before, 0.005 ether);
        assertEq(t2.totalKeeperOwed(), 0);
    }

    function testETHBacklogThresholdAndNewStakeNoPastRewards() public {
        d2.notifyIMDSTR{value: 0.1 ether}(0);
        stakeAlice(1e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(d2.earned(alice, address(0)), 0);
        stakeAlice(10_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 before = d2.earned(alice, address(0));
        assertGt(before, 0);
        vm.prank(bob);
        d2.stake(10_000_000e18);
        assertEq(d2.earned(bob, address(0)), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(d2.earned(alice, address(0)) + d2.earned(bob, address(0)), 0.1 ether, 2);
    }

    function testCallbackAndAtomicSelfCallGuards() public {
        vm.expectRevert(AdamDistributorV2.InvalidSwap.selector);
        d2.unlockCallback("");
        vm.prank(address(poolManager));
        vm.expectRevert(AdamDistributorV2.InvalidSwap.selector);
        d2.unlockCallback("");
        vm.expectRevert(AdamTreasury.NotProcessing.selector);
        t2.executeV2(0, 1 ether);
        assertGt(bytes(d2.contractURI()).length, 0);
        assertGt(bytes(t2.contractURI()).length, 0);
    }

    function testFuzzETHConservation(uint96 funding) public {
        uint256 amount = bound(funding, 1 gwei, 20 ether);
        stakeAlice(100_000_000e18);
        fundTreasury(amount);
        uint256 keeperBefore = bob.balance;
        uint256 pmBefore = address(poolManager).balance;
        vm.prank(bob);
        t2.process();
        uint256 bounty = bob.balance - keeperBefore;
        assertLe(bounty, amount * 50 / 10000);
        assertEq(address(t2).balance + address(d2).balance + (address(poolManager).balance - pmBefore) + bounty, amount);
        assertEq(
            t2.unsplitEth() + t2.teamOwed() + t2.totalKeeperOwed() + t2.leg(0).pending + t2.leg(1).pending
                + t2.leg(2).pending,
            address(t2).balance
        );
    }
}
