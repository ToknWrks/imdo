// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RegenDrop} from "../../src/RegenDrop.sol";
import {MockAxlRegen} from "../unit/RegenDrop.t.sol";

/// @dev Random funding, posting, replacing, cancelling, time and claims against a growing two-account tree.
contract DropHandler is Test {
    RegenDrop public drop;
    MockAxlRegen public regen;
    address public safe;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    uint256 public funded;
    uint256 public totalA;
    uint256 public totalB;
    uint256 public t;
    // the proofs for the latest posted tree
    bytes32[] internal proofA;
    bytes32[] internal proofB;

    constructor(RegenDrop d, MockAxlRegen r, address s) {
        drop = d;
        regen = r;
        safe = s;
        t = 1_000_000;
        vm.warp(t);
    }

    function _leaf(address a, uint256 c) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, c))));
    }

    function fund(uint96 amount) external {
        regen.mint(address(drop), amount);
        funded += amount;
    }

    function postGrowth(uint96 addA, uint96 addB) external {
        uint256 nA = totalA + addA;
        uint256 nB = totalB + addB;
        if (nA + nB > funded) return; // the contract would refuse; that path is covered by unit tests
        bytes32 la = _leaf(alice, nA);
        bytes32 lb = _leaf(bob, nB);
        bytes32 r = la < lb ? keccak256(abi.encodePacked(la, lb)) : keccak256(abi.encodePacked(lb, la));
        vm.prank(safe);
        drop.postRoot(r, nA + nB);
        totalA = nA;
        totalB = nB;
        delete proofA;
        delete proofB;
        proofA.push(lb);
        proofB.push(la);
    }

    function cancel() external {
        vm.prank(safe);
        try drop.cancelPending() {} catch {}
    }

    function wait(uint32 secs) external {
        t += secs % 3 days;
        vm.warp(t);
    }

    function claimAlice() external {
        if (proofA.length == 0) return;
        try drop.claim(alice, totalA, proofA) {} catch {}
    }

    function claimBob() external {
        if (proofB.length == 0) return;
        try drop.claim(bob, totalB, proofB) {} catch {}
    }
}

contract RegenDropInvariant is Test {
    RegenDrop internal drop;
    MockAxlRegen internal regen;
    DropHandler internal h;

    function setUp() public {
        regen = new MockAxlRegen();
        address safe = makeAddr("safe");
        drop = new RegenDrop(address(regen), safe);
        h = new DropHandler(drop, regen, safe);
        targetContract(address(h));
    }

    /// @dev Tokens are conserved: what the contract holds plus what it paid out is everything ever funded.
    function invariant_tokensAreConserved() public view {
        assertEq(regen.balanceOf(address(drop)) + drop.totalClaimed(), h.funded());
    }

    /// @dev The two accounts together can never have taken more than the live root commits to.
    function invariant_claimsStayWithinTheLiveCommitment() public view {
        assertLe(drop.claimed(h.alice()) + drop.claimed(h.bob()), drop.committed());
        assertEq(drop.claimed(h.alice()) + drop.claimed(h.bob()), drop.totalClaimed());
    }

    /// @dev The commitment never exceeds what was funded.
    function invariant_commitmentIsFunded() public view {
        assertLe(drop.committed(), h.funded());
    }
}
