// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClaimHarness, ClaimTree, ModelSeats} from "../utils/ClaimHarness.sol";
import {IMDOToken} from "src/IMDOToken.sol";
import {ImdoStaking} from "src/ImdoStaking.sol";
import {ImdoClaim} from "src/ImdoClaim.sol";

/// @dev Independent entitlement model. Failed calls must revert with the expected error;
/// unexpected failures are never swallowed by the handler.
contract ClaimHandler is Test {
    IMDOToken public token;
    ImdoClaim public claim;
    ImdoStaking public staking;
    ModelSeats public seats;
    uint256 public clock;
    uint256 public launch;
    uint256 public burned;
    uint256 public paid;
    uint256[8] public seatPaid;
    uint256[8] public ownerIndex;
    address[8] public lastClaimant;
    uint256[4] public holderPaid;
    uint256[4] public liquid;
    uint256[4] public staked;
    uint256[4] public unlock;

    constructor(IMDOToken t, ImdoClaim c, ImdoStaking s, ModelSeats n) {
        token = t;
        claim = c;
        staking = s;
        seats = n;
        launch = c.launch();
        clock = vm.getBlockTimestamp();
        for (uint256 i; i < 8; ++i) {
            ownerIndex[i] = i % 4;
        }
        for (uint256 i; i < 4; ++i) {
            vm.prank(ClaimTree.actor(i));
            t.approve(address(s), type(uint256).max);
        }
    }

    function vested(uint256 total) public view returns (uint256) {
        if (clock < launch || clock >= launch + 39 days) return 0;
        uint256 day = (clock - launch) / 1 days;
        return day >= 9 ? total : total * (day + 1) / 10;
    }

    function transferSeat(uint256 id, uint256 to) external {
        id %= 8;
        to %= 4;
        address from = ClaimTree.actor(ownerIndex[id]);
        vm.prank(from);
        seats.transferFrom(from, ClaimTree.actor(to), id);
        ownerIndex[id] = to;
    }

    function claimSeat(uint256 id, uint256 who, bool stake, bool duplicate) external {
        id %= 8;
        who %= 4;
        address caller = ClaimTree.actor(who);
        uint256[] memory list = new uint256[](duplicate ? 2 : 1);
        list[0] = id;
        if (duplicate) list[1] = id;
        uint256 due = vested(50_000e18);
        if (clock >= launch + 39 days) {
            vm.expectRevert(ImdoClaim.ClaimClosed.selector);
        } else if (clock < launch) {
            vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        } else if (who != ownerIndex[id]) {
            vm.expectRevert(ImdoClaim.NotOwner.selector);
        } else if (due == seatPaid[id] && lastClaimant[id] == caller) {
            vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        } else {
            uint256 amount = due - seatPaid[id];
            seatPaid[id] = due;
            lastClaimant[id] = caller;
            _credit(who, amount, stake);
        }
        vm.prank(caller);
        claim.claimSeat(list, stake);
    }

    function claimHolder(uint256 who, bool stake, bool corruptProof) external {
        who %= 4;
        bytes32[] memory proof = ClaimTree.proof(who);
        if (corruptProof) proof[0] = bytes32(uint256(proof[0]) ^ 1);
        uint256 vestedAmount = vested(ClaimTree.allocation(who));
        if (clock >= launch + 39 days) {
            vm.expectRevert(ImdoClaim.ClaimClosed.selector);
        } else if (corruptProof) {
            vm.expectRevert(ImdoClaim.InvalidProof.selector);
        } else if (vestedAmount <= holderPaid[who]) {
            vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        } else {
            uint256 amount = vestedAmount - holderPaid[who];
            holderPaid[who] = vestedAmount;
            _credit(who, amount, stake);
        }
        vm.prank(ClaimTree.actor(who));
        claim.claimHolder(ClaimTree.allocation(who), proof, stake);
    }

    function _credit(uint256 who, uint256 amount, bool stake) private {
        paid += amount;
        if (stake && amount != 0) {
            staked[who] += amount;
            unlock[who] = clock + 1 days;
        } else {
            liquid[who] += amount;
        }
    }

    function stakeAgain(uint256 who, uint256 amount) external {
        who %= 4;
        if (liquid[who] == 0) return;
        amount = bound(amount, 1, liquid[who]);
        liquid[who] -= amount;
        staked[who] += amount;
        unlock[who] = clock + 1 days;
        vm.prank(ClaimTree.actor(who));
        staking.stake(amount);
    }

    function exit(uint256 who) external {
        who %= 4;
        if (staked[who] != 0 && clock < unlock[who]) {
            vm.expectRevert(abi.encodeWithSelector(ImdoStaking.StakeLocked.selector, unlock[who]));
        } else {
            liquid[who] += staked[who];
            staked[who] = 0;
        }
        vm.prank(ClaimTree.actor(who));
        staking.exit();
    }

    function advance(uint32 elapsed) external {
        clock += bound(elapsed, 1, 3 days);
        vm.warp(clock);
    }

    function burn() external {
        if (clock < launch + 39 days) vm.expectRevert(ImdoClaim.TooEarly.selector);
        else burned = 110_000_000e18 - paid;
        claim.burnUnclaimed();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ClaimInvariantTest is ClaimHarness {
    ClaimHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ClaimHandler(token, claim, staking, seats);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transferSeat.selector;
        selectors[1] = handler.claimSeat.selector;
        selectors[2] = handler.claimHolder.selector;
        selectors[3] = handler.stakeAgain.selector;
        selectors[4] = handler.exit.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.burn.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_entitlementsAndCustodyMatchIndependentModel() public view {
        uint256 claimed;
        uint256 holderTotal;
        uint256 principal;
        uint256 wallets;
        for (uint256 i; i < 8; ++i) {
            assertEq(claim.seatClaimed(i), handler.seatPaid(i));
            assertLe(claim.seatClaimed(i), 50_000e18);
            assertEq(seats.ownerOf(i), ClaimTree.actor(handler.ownerIndex(i)));
            assertEq(claim.seatClaimedBy(i), handler.lastClaimant(i));
            claimed += handler.seatPaid(i);
        }
        for (uint256 i; i < 4; ++i) {
            address actor = ClaimTree.actor(i);
            assertEq(claim.holderClaimed(actor), handler.holderPaid(i));
            assertLe(claim.holderClaimed(actor), ClaimTree.allocation(i));
            assertEq(token.balanceOf(actor), handler.liquid(i));
            assertEq(staking.stakedBalance(actor), handler.staked(i));
            assertEq(staking.unlockTime(actor), handler.unlock(i));
            holderTotal += handler.holderPaid(i);
            principal += handler.staked(i);
            wallets += handler.liquid(i);
        }
        assertEq(claim.totalHolderClaimed(), holderTotal);
        assertLe(holderTotal, 10_000_000e18);
        assertEq(claimed + holderTotal, handler.paid());
        assertEq(wallets + principal, handler.paid());
        assertEq(staking.totalStaked(), principal);
        assertEq(token.balanceOf(address(staking)), principal);
        assertEq(token.allowance(address(claim), address(staking)), 0);
        assertEq(token.balanceOf(claim.DEAD()), handler.burned());
        assertEq(token.balanceOf(address(claim)) + handler.burned() + handler.paid(), 110_000_000e18);
        assertEq(token.balanceOf(address(this)), 890_000_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    /// @dev Every generated history must still allow all remaining funded rights to settle.
    function afterInvariant() public {
        if (vm.getBlockTimestamp() < launch + 39 days) {
            if (vm.getBlockTimestamp() < launch + 9 days) handler.advance(3 days);
            while (vm.getBlockTimestamp() < launch + 9 days) handler.advance(3 days);
            for (uint256 i; i < 8; ++i) {
                handler.claimSeat(i, handler.ownerIndex(i), false, false);
            }
            for (uint256 i; i < 4; ++i) {
                handler.claimHolder(i, false, false);
            }
        }
        while (vm.getBlockTimestamp() < launch + 39 days) handler.advance(3 days);
        handler.burn();
        for (uint256 i; i < 4; ++i) {
            handler.exit(i);
        }
        invariant_entitlementsAndCustodyMatchIndependentModel();
        assertEq(token.balanceOf(address(claim)), 0);
        assertEq(staking.totalStaked(), 0);
    }
}
