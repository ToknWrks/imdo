// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "../utils/LocalV4.sol";
import {FaultyStaking, RejectingKeeper} from "./ImdoTreasury.t.sol";
import {ImdoTreasury} from "src/ImdoTreasury.sol";

contract TreasuryBoundariesTest is LocalV4 {
    function fund(ImdoTreasury t, uint256 amount) internal {
        (bool ok,) = address(t).call{value: amount}("");
        assertTrue(ok);
    }

    function test_oldPendingRegenSurvivesEpochRollAndDoesNotConsumeNewCap() public {
        FaultyStaking sink = new FaultyStaking();
        sink.configure(true, true);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        uint256 oldEpoch = vm.getBlockTimestamp() / 7 days;
        fund(t, 2 ether);
        t.process();
        assertEq(t.pendingRegen(), 0.4975 ether);
        vm.prank(regenSafe);
        t.setRegenCap(0.05 ether);
        vm.warp((oldEpoch + 1) * 7 days);
        fund(t, 1 ether);
        t.process();
        assertEq(t.regenAccrued(oldEpoch), 0.4975 ether);
        assertEq(t.regenAccrued(oldEpoch + 1), 0.05 ether);
        assertEq(t.pendingRegen(), 0.5475 ether);
        assertEq(t.leg(0).pending, 1.39275 ether);
        sink.configure(false, true);
        vm.warp(vm.getBlockTimestamp() + 600);
        uint256 keeperBalance = address(this).balance;
        t.process();
        assertEq(sink.notified(), 0.5475 ether);
        assertEq(t.pendingRegen(), 0);
        assertEq(address(this).balance, keeperBalance, "retry must not earn another bounty");
        assertEq(t.regenAccrued(oldEpoch + 1), 0.05 ether);
        assertEq(t.opsOwed(), 0.2985 ether);
        assertEq(t.offsetsOwed(), 0.74625 ether);
        assertEq(address(t).balance, t.opsOwed() + t.offsetsOwed() + t.leg(0).pending);
    }

    function test_loweringCapBelowUsedCapacityCannotResplitPendingFunds() public {
        FaultyStaking sink = new FaultyStaking();
        sink.configure(true, true);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        fund(t, 1 ether);
        t.process();
        vm.prank(regenSafe);
        t.setRegenCap(0.05 ether);
        vm.warp(vm.getBlockTimestamp() + 600);
        fund(t, 1 ether);
        t.process();
        assertEq(t.pendingRegen(), 0.24875 ether);
        assertEq(t.regenAccrued(vm.getBlockTimestamp() / 7 days), 0.24875 ether);
        assertEq(t.leg(0).pending, 1.04475 ether);
        vm.prank(regenSafe);
        t.setRegenCap(0.3 ether);
        vm.warp(vm.getBlockTimestamp() + 600);
        fund(t, 1 ether);
        t.process();
        assertEq(t.pendingRegen(), 0.3 ether);
        assertEq(t.leg(0).pending, 1.64025 ether);
        assertEq(address(t).balance, t.opsOwed() + t.offsetsOwed() + t.pendingRegen() + t.leg(0).pending);
    }

    function test_keeperDebtsAreIsolatedAndFailedPullPreservesBoth() public {
        RejectingKeeper first = new RejectingKeeper();
        RejectingKeeper second = new RejectingKeeper();
        fund(treasury, 1 ether);
        first.process(treasury);
        vm.warp(vm.getBlockTimestamp() + 600);
        fund(treasury, 0.5 ether);
        second.process(treasury);
        assertEq(treasury.keeperOwed(address(first)), 0.005 ether);
        assertEq(treasury.keeperOwed(address(second)), 0.0025 ether);
        vm.prank(alice);
        vm.expectRevert(ImdoTreasury.NothingOwed.selector);
        treasury.claimKeeper(payable(alice));
        vm.expectRevert(ImdoTreasury.ZeroAddress.selector);
        first.claim(treasury, payable(address(0)));
        vm.expectRevert(ImdoTreasury.TeamTransferFailed.selector);
        first.claim(treasury, payable(address(second)));
        assertEq(treasury.totalKeeperOwed(), 0.0075 ether);
        assertEq(treasury.keeperOwed(address(first)), 0.005 ether);
        assertEq(treasury.keeperOwed(address(second)), 0.0025 ether);
        first.claim(treasury, payable(alice));
        second.claim(treasury, payable(bob));
        assertEq(alice.balance, 0.005 ether);
        assertEq(bob.balance, 0.0025 ether);
        assertEq(treasury.totalKeeperOwed(), 0);
        assertEq(address(treasury).balance, treasury.opsOwed() + treasury.offsetsOwed());
    }

    function test_failedFlushRetainsTokensAndClearsApprovalOnSuccessfulRetry() public {
        FaultyStaking sink = new FaultyStaking();
        sink.configure(false, true);
        ImdoTreasury t = _newTreasury(address(sink), address(poolManager));
        imd.transfer(address(t), 123e18);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "imd"));
        t.flushRewards();
        assertEq(imd.balanceOf(address(t)), 123e18);
        assertEq(imd.balanceOf(address(sink)), 0);
        assertEq(imd.allowance(address(t), address(sink)), 0);
        sink.configure(false, false);
        vm.prank(alice);
        t.flushRewards();
        assertEq(imd.balanceOf(address(t)), 0);
        assertEq(imd.balanceOf(address(sink)), 123e18);
        assertEq(imd.allowance(address(t), address(sink)), 0);
        t.flushRewards();
        assertEq(imd.balanceOf(address(sink)), 123e18, "empty flush cannot pay twice");
    }
}
