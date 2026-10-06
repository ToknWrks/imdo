// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ClaimHarness, ClaimTree} from "../utils/ClaimHarness.sol";
import {ImdoClaim} from "src/ImdoClaim.sol";
import {ImdoStaking} from "src/ImdoStaking.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ClaimAdversarialTest is ClaimHarness {
    function test_batchWithUnauthorizedLastSeatRollsBackEarlierEntitlement() public {
        vm.warp(launch);
        vm.prank(ClaimTree.actor(0));
        vm.expectRevert(ImdoClaim.NotOwner.selector);
        claim.claimSeat(ids(0, 1), true);
        assertEq(claim.seatClaimed(0), 0);
        assertEq(claim.seatClaimedBy(0), address(0));
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(address(claim)), 110_000_000e18);
        assertEq(token.allowance(address(claim), address(staking)), 0);

        vm.prank(ClaimTree.actor(0));
        vm.expectRevert(ImdoClaim.InvalidToken.selector);
        claim.claimSeat(ids(0, 2000), false);
        assertEq(claim.seatClaimed(0), 0);
        assertEq(claim.seatClaimedBy(0), address(0));
    }

    function test_emptyBatchNeverChangesBalancesOrLocks() public {
        vm.warp(launch);
        vm.prank(ClaimTree.actor(0));
        vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        claim.claimSeat(new uint256[](0), true);
        assertEq(staking.unlockTime(ClaimTree.actor(0)), 0);
        assertEq(token.balanceOf(address(claim)), 110_000_000e18);
    }

    function test_recordingNewOwnerWithoutNewTrancheDoesNotResetExistingStakeLock() public {
        vm.warp(launch);
        address alice = ClaimTree.actor(0);
        address bob = ClaimTree.actor(1);
        vm.prank(alice);
        claim.claimSeat(ids(0, 0), false);
        vm.prank(bob);
        claim.claimSeat(ids(1, 1), true);
        uint256 unlock = staking.unlockTime(bob);
        vm.prank(alice);
        seats.transferFrom(alice, bob, 0);
        vm.warp(launch + 12 hours);
        vm.expectEmit(true, true, false, true, address(claim));
        emit ImdoClaim.SeatClaimed(0, bob);
        vm.prank(bob);
        claim.claimSeat(ids(0, 0), true);
        assertEq(claim.seatClaimedBy(0), bob);
        assertEq(claim.seatClaimed(0), 5_000e18);
        assertEq(staking.stakedBalance(bob), 5_000e18);
        assertEq(staking.unlockTime(bob), unlock);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_excludedNftOwnerCanTakeWalletClaimAfterFailedStake() public {
        address safe = staking.regenSafe();
        vm.prank(ClaimTree.actor(0));
        seats.transferFrom(ClaimTree.actor(0), safe, 0);
        vm.warp(launch);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdoStaking.Excluded.selector, safe));
        claim.claimSeat(ids(0, 0), true);
        assertEq(claim.seatClaimed(0), 0);
        assertEq(claim.seatClaimedBy(0), address(0));
        assertEq(token.allowance(address(claim), address(staking)), 0);
        vm.prank(safe);
        claim.claimSeat(ids(0, 0), false);
        assertEq(token.balanceOf(safe), 5_000e18);
    }

    function test_operatorApprovalDoesNotGiveClaimRights() public {
        vm.prank(ClaimTree.actor(0));
        seats.setApprovalForAll(ClaimTree.actor(1), true);
        vm.warp(launch);
        vm.prank(ClaimTree.actor(1));
        vm.expectRevert(ImdoClaim.NotOwner.selector);
        claim.claimSeat(ids(0, 0), false);
        assertEq(claim.seatClaimed(0), 0);
    }

    function test_holderRejectsSingleHashLeafAndReorderedProof() public {
        vm.warp(launch);
        address alice = ClaimTree.actor(0);
        bytes32[] memory proof = ClaimTree.proof(0);
        (proof[0], proof[1]) = (proof[1], proof[0]);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.InvalidProof.selector);
        claim.claimHolder(1_000_000e18, proof, false);
        ImdoClaim wrongTree = _newClaim(keccak256(abi.encode(alice, uint256(1_000_000e18))), 0);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.InvalidProof.selector);
        wrongTree.claimHolder(1_000_000e18, new bytes32[](0), false);
        assertEq(wrongTree.totalHolderClaimed(), 0);
    }

    function test_underfundedHolderPaymentRollsBackAndCanRetryAfterFunding() public {
        ImdoClaim empty = _newClaim(ClaimTree.root(), 0);
        vm.warp(launch);
        address alice = ClaimTree.actor(0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(empty), 0, 100_000e18)
        );
        empty.claimHolder(1_000_000e18, ClaimTree.proof(0), false);
        assertEq(empty.holderClaimed(alice), 0);
        assertEq(empty.totalHolderClaimed(), 0);
        token.transfer(address(empty), 100_000e18);
        vm.prank(alice);
        empty.claimHolder(1_000_000e18, ClaimTree.proof(0), false);
        assertEq(token.balanceOf(alice), 100_000e18);
    }

    function test_overcommittedHolderTreeCannotSpendSeatReserve() public {
        address alice = ClaimTree.actor(0);
        address bob = ClaimTree.actor(1);
        bytes32 a = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(6_000_000e18)))));
        bytes32 b = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(6_000_000e18)))));
        ImdoClaim overcommitted = _newClaim(ClaimTree.pair(a, b), 110_000_000e18);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        vm.warp(launch + 9 days);
        vm.prank(alice);
        overcommitted.claimHolder(6_000_000e18, proof, false);
        proof[0] = a;
        vm.prank(bob);
        vm.expectRevert(ImdoClaim.InvalidConfiguration.selector);
        overcommitted.claimHolder(6_000_000e18, proof, false);
        assertEq(overcommitted.totalHolderClaimed(), 6_000_000e18);
        assertEq(overcommitted.holderClaimed(bob), 0);
        assertEq(token.balanceOf(address(overcommitted)), 104_000_000e18);
        vm.prank(bob);
        overcommitted.claimSeat(ids(1, 1), false);
        assertEq(token.balanceOf(bob), 50_000e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_eachDailyTrancheIsPaidOnlyOnceAcrossWalletAndStake(uint16 stakeMask) public {
        address alice = ClaimTree.actor(0);
        for (uint256 day; day < 10; ++day) {
            vm.warp(launch + day * 1 days);
            bool stake = (uint256(stakeMask) & (1 << day)) != 0;
            vm.prank(alice);
            claim.claimSeat(ids(0, 4), stake);
            vm.prank(alice);
            claim.claimHolder(1_000_000e18, ClaimTree.proof(0), stake);
            assertEq(token.balanceOf(alice) + staking.stakedBalance(alice), (day + 1) * 110_000e18);
            assertEq(token.allowance(address(claim), address(staking)), 0);
            vm.warp(launch + (day + 1) * 1 days - 1);
            vm.prank(alice);
            vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
            claim.claimSeat(ids(0, 4), !stake);
            vm.prank(alice);
            vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
            claim.claimHolder(1_000_000e18, ClaimTree.proof(0), !stake);
        }
        assertEq(claim.seatClaimed(0) + claim.seatClaimed(4), 100_000e18);
        assertEq(claim.holderClaimed(alice), 1_000_000e18);
        vm.warp(launch + 10 days);
        vm.prank(alice);
        staking.exit();
        assertEq(token.balanceOf(alice), 1_100_000e18);
    }

    function _newClaim(bytes32 root, uint256 funding) private returns (ImdoClaim c) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ImdoStaking s = new ImdoStaking(address(token), address(imd), address(0x9000), predicted, address(0x5afe));
        c = new ImdoClaim(address(token), address(s), address(seats), 2000, root, launch);
        if (funding != 0) token.transfer(address(c), funding);
    }
}
