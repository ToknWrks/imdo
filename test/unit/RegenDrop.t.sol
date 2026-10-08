// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RegenDrop} from "../../src/RegenDrop.sol";

contract MockAxlRegen is ERC20 {
    constructor() ERC20("Axelar REGEN", "axlREGEN") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Builds the same tree shape the off-chain script will: double-hashed `(address,uint256)` leaves, sorted pairs.
abstract contract DropBase is Test {
    RegenDrop internal drop;
    MockAxlRegen internal regen;
    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        regen = new MockAxlRegen();
        drop = new RegenDrop(address(regen), safe);
    }

    function leaf(address a, uint256 c) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, c))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @return rootHash of a two-leaf tree, and each leaf's one-element proof
    function tree2(address a, uint256 ca, address b, uint256 cb)
        internal
        pure
        returns (bytes32 rootHash, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32 la = leaf(a, ca);
        bytes32 lb = leaf(b, cb);
        rootHash = pair(la, lb);
        proofA = new bytes32[](1);
        proofA[0] = lb;
        proofB = new bytes32[](1);
        proofB[0] = la;
    }

    function fund(uint256 amount) internal {
        regen.mint(address(drop), amount);
    }

    function post(bytes32 rootHash, uint256 committed) internal {
        vm.prank(safe);
        drop.postRoot(rootHash, committed);
    }

    function live(bytes32 rootHash, uint256 committed) internal {
        post(rootHash, committed);
        vm.warp(block.timestamp + drop.ACTIVATION_DELAY());
        drop.activate();
    }
}

contract RegenDropTest is DropBase {
    function test_constructorRejectsZero() public {
        vm.expectRevert(RegenDrop.ZeroAddress.selector);
        new RegenDrop(address(0), safe);
        vm.expectRevert(RegenDrop.ZeroAddress.selector);
        new RegenDrop(address(regen), address(0));
    }

    function test_onlySafePostsAndCancels() public {
        vm.expectRevert(RegenDrop.OnlySafe.selector);
        drop.postRoot(bytes32(uint256(1)), 0);
        vm.expectRevert(RegenDrop.OnlySafe.selector);
        drop.cancelPending();
        vm.prank(alice);
        vm.expectRevert(RegenDrop.OnlySafe.selector);
        drop.postRoot(bytes32(uint256(1)), 0);
    }

    function test_rootIsNotClaimableUntilTheDelayPasses() public {
        fund(300e6);
        (bytes32 r, bytes32[] memory pa,) = tree2(alice, 100e6, bob, 200e6);
        post(r, 300e6);
        // before the delay the live root is still empty: any proof fails
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(alice, 100e6, pa);
        vm.warp(block.timestamp + drop.ACTIVATION_DELAY() - 1);
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(alice, 100e6, pa);
        vm.warp(block.timestamp + 1);
        drop.claim(alice, 100e6, pa); // claim activates the due root itself
        assertEq(regen.balanceOf(alice), 100e6);
        assertEq(drop.root(), r);
        assertEq(drop.pendingActiveAt(), 0);
    }

    function test_claimPaysTheAccountEvenWhenAnotherCalls() public {
        fund(300e6);
        (bytes32 r, bytes32[] memory pa,) = tree2(alice, 100e6, bob, 200e6);
        live(r, 300e6);
        vm.prank(carol);
        drop.claim(alice, 100e6, pa);
        assertEq(regen.balanceOf(alice), 100e6);
        assertEq(regen.balanceOf(carol), 0);
        assertEq(drop.claimed(alice), 100e6);
        assertEq(drop.totalClaimed(), 100e6);
    }

    function test_cannotClaimTwiceOrWithABadProof() public {
        fund(300e6);
        (bytes32 r, bytes32[] memory pa, bytes32[] memory pb) = tree2(alice, 100e6, bob, 200e6);
        live(r, 300e6);
        drop.claim(alice, 100e6, pa);
        vm.expectRevert(RegenDrop.NothingToClaim.selector);
        drop.claim(alice, 100e6, pa);
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(alice, 100e6, pb); // bob's proof
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(alice, 150e6, pa); // a bigger total than the leaf holds
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(carol, 100e6, pa); // someone not in the tree
    }

    function test_runningTotalsPayOnlyTheDifference() public {
        fund(300e6);
        (bytes32 r1, bytes32[] memory pa1,) = tree2(alice, 100e6, bob, 200e6);
        live(r1, 300e6);
        drop.claim(alice, 100e6, pa1);
        // next epoch: alice's total grows to 130, bob's to 260; 90 more REGEN is funded
        fund(90e6);
        (bytes32 r2, bytes32[] memory pa2, bytes32[] memory pb2) = tree2(alice, 130e6, bob, 260e6);
        live(r2, 390e6);
        drop.claim(alice, 130e6, pa2);
        assertEq(regen.balanceOf(alice), 130e6);
        // bob missed epoch one entirely and still gets everything in one claim
        drop.claim(bob, 260e6, pb2);
        assertEq(regen.balanceOf(bob), 260e6);
        assertEq(drop.totalClaimed(), 390e6);
        assertEq(regen.balanceOf(address(drop)), 0);
    }

    function test_oldProofStopsWorkingOnceANewRootIsLive() public {
        fund(300e6);
        (bytes32 r1,, bytes32[] memory pb1) = tree2(alice, 100e6, bob, 200e6);
        live(r1, 300e6);
        fund(10e6);
        (bytes32 r2,,) = tree2(alice, 110e6, bob, 200e6);
        live(r2, 310e6);
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(bob, 200e6, pb1);
    }

    function test_aWrongRootCanBeReplacedOrCancelledInsideTheWindow() public {
        // absolute times: repeated `block.timestamp + x` warps are cached by the via_ir optimizer
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        fund(300e6);
        (bytes32 bad,,) = tree2(alice, 300e6, bob, 0);
        post(bad, 300e6);
        (bytes32 good, bytes32[] memory pa,) = tree2(alice, 100e6, bob, 200e6);
        vm.warp(t0 + 12 hours);
        post(good, 300e6); // replaces it and restarts the full delay
        vm.warp(t0 + 24 hours);
        drop.activate();
        assertEq(drop.root(), bytes32(0)); // not yet: the replacement restarted the clock
        vm.warp(t0 + 36 hours);
        drop.activate();
        assertEq(drop.root(), good);
        drop.claim(alice, 100e6, pa);

        vm.prank(safe);
        vm.expectRevert(RegenDrop.NoPendingRoot.selector);
        drop.cancelPending();
        post(bad, 300e6);
        vm.prank(safe);
        drop.cancelPending();
        assertEq(drop.pendingActiveAt(), 0);
        assertEq(drop.root(), good); // the live root keeps working
    }

    function test_aRootCannotPromiseMoreThanTheContractHasHeld() public {
        fund(100e6);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RegenDrop.Underfunded.selector, 101e6, 100e6));
        drop.postRoot(bytes32(uint256(1)), 101e6);
        // claimed tokens still count as funded: balance + totalClaimed
        (bytes32 r, bytes32[] memory pa,) = tree2(alice, 60e6, bob, 40e6);
        live(r, 100e6);
        drop.claim(alice, 60e6, pa);
        fund(10e6);
        post(bytes32(uint256(2)), 110e6);
    }

    function test_theCommittedTotalNeverShrinks() public {
        fund(300e6);
        (bytes32 r,,) = tree2(alice, 100e6, bob, 200e6);
        live(r, 300e6);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RegenDrop.CommittedBelowLive.selector, 299e6, 300e6));
        drop.postRoot(bytes32(uint256(9)), 299e6);
        post(bytes32(uint256(9)), 300e6); // equal is fine
    }

    function test_aDueRootIsLiveBeforeTheNextPostIsChecked() public {
        fund(500e6);
        (bytes32 r1,,) = tree2(alice, 100e6, bob, 200e6);
        post(r1, 300e6);
        vm.warp(block.timestamp + drop.ACTIVATION_DELAY());
        // nobody called activate: the next post must still compare with 300, not with the stale 0
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RegenDrop.CommittedBelowLive.selector, 250e6, 300e6));
        drop.postRoot(bytes32(uint256(3)), 250e6);
        drop.activate();
        assertEq(drop.root(), r1);
        assertEq(drop.committed(), 300e6);
    }

    /// @dev Known limit, documented: a corrected root that LOWERS someone who already claimed cannot recover the
    ///      overpayment, and raising others to keep `committed` level leaves the contract short by that amount. The
    ///      guard checks totals, not each account's floor. The epoch script must treat `claimed` as every total's floor.
    function test_aLoweredTotalPaysNothingMoreAndLeavesTheContractShort() public {
        fund(300e6);
        (bytes32 r1, bytes32[] memory pa1,) = tree2(alice, 100e6, bob, 200e6);
        live(r1, 300e6);
        drop.claim(alice, 100e6, pa1);
        (bytes32 r2, bytes32[] memory pa2, bytes32[] memory pb2) = tree2(alice, 80e6, bob, 220e6);
        live(r2, 300e6);
        vm.expectRevert(RegenDrop.NothingToClaim.selector);
        drop.claim(alice, 80e6, pa2); // nothing more, and nothing clawed back
        assertEq(regen.balanceOf(alice), 100e6);
        vm.expectRevert(); // bob's 220 exceeds the 200 left; the transfer fails, nothing is paid from elsewhere
        drop.claim(bob, 220e6, pb2);
        fund(20e6); // topping up the shortfall makes it whole
        drop.claim(bob, 220e6, pb2);
        assertEq(regen.balanceOf(bob), 220e6);
    }

    function test_theSafeHasNoWayToTakeTheTokens() public {
        fund(100e6);
        // the only setter-shaped functions are post/cancel; neither moves tokens
        (bytes32 r,,) = tree2(alice, 100e6, bob, 0);
        live(r, 100e6);
        vm.startPrank(safe);
        vm.expectRevert(RegenDrop.InvalidProof.selector);
        drop.claim(safe, 100e6, new bytes32[](0));
        vm.stopPrank();
        assertEq(regen.balanceOf(address(drop)), 100e6);
        assertEq(regen.balanceOf(safe), 0);
    }

    function test_claimableView() public {
        assertEq(drop.claimable(alice, 5), 5);
        fund(10e6);
        (bytes32 r, bytes32[] memory pa,) = tree2(alice, 4e6, bob, 6e6);
        live(r, 10e6);
        drop.claim(alice, 4e6, pa);
        assertEq(drop.claimable(alice, 4e6), 0);
        assertEq(drop.claimable(alice, 9e6), 5e6);
    }

    function test_eventsAreEmitted() public {
        fund(300e6);
        (bytes32 r, bytes32[] memory pa,) = tree2(alice, 100e6, bob, 200e6);
        vm.expectEmit(false, false, false, true);
        emit RegenDrop.RootPosted(r, 300e6, uint64(block.timestamp) + 24 hours);
        post(r, 300e6);
        vm.warp(block.timestamp + 24 hours);
        vm.expectEmit(false, false, false, true);
        emit RegenDrop.RootActivated(r, 300e6);
        vm.expectEmit(true, false, false, true);
        emit RegenDrop.Claimed(alice, 100e6, 100e6);
        drop.claim(alice, 100e6, pa);
    }
}

contract RegenDropFuzz is DropBase {
    /// @dev Any two totals: payouts equal the totals, the contract never pays more than was funded, and a second claim is empty.
    function testFuzz_payoutsMatchTheTree(uint96 a, uint96 b, uint96 extra) public {
        uint256 ca = a;
        uint256 cb = b;
        fund(ca + cb + extra);
        (bytes32 r, bytes32[] memory pa, bytes32[] memory pb) = tree2(alice, ca, bob, cb);
        live(r, ca + cb);
        if (ca > 0) {
            drop.claim(alice, ca, pa);
            vm.expectRevert(RegenDrop.NothingToClaim.selector);
            drop.claim(alice, ca, pa);
        }
        if (cb > 0) drop.claim(bob, cb, pb);
        assertEq(regen.balanceOf(alice), ca);
        assertEq(regen.balanceOf(bob), cb);
        assertEq(regen.balanceOf(address(drop)), extra);
        assertEq(drop.totalClaimed(), ca + cb);
    }

    /// @dev A root that commits to more than the funded total is always refused.
    function testFuzz_underfundedRootRefused(uint96 funded, uint96 over) public {
        vm.assume(over > 0);
        fund(funded);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RegenDrop.Underfunded.selector, uint256(funded) + over, uint256(funded)));
        drop.postRoot(bytes32(uint256(1)), uint256(funded) + over);
    }

    /// @dev Across two epochs a claimant ends with exactly the latest running total, however claims are split.
    function testFuzz_twoEpochsEndAtTheLatestTotal(uint64 first, uint64 more, bool claimBetween) public {
        uint256 c1 = first;
        uint256 c2 = uint256(first) + more;
        fund(c1);
        (bytes32 r1, bytes32[] memory p1,) = tree2(alice, c1, bob, 0);
        live(r1, c1);
        if (claimBetween && c1 > 0) drop.claim(alice, c1, p1);
        fund(more);
        (bytes32 r2, bytes32[] memory p2,) = tree2(alice, c2, bob, 0);
        live(r2, c2);
        if (c2 > drop.claimed(alice)) drop.claim(alice, c2, p2);
        assertEq(regen.balanceOf(alice), c2);
    }
}
