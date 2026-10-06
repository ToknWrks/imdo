// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IMDOToken} from "../../src/IMDOToken.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";
import {ImdoClaim} from "../../src/ImdoClaim.sol";

contract ClaimNFTMock is ERC721 {
    constructor() ERC721("Seats", "SEAT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract ImdoClaimTest is Test {
    IMDOToken token;
    ImdoStaking staking;
    ImdoClaim claim;
    ClaimNFTMock nft;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    bytes32 aliceLeaf;
    bytes32 bobLeaf;
    uint256 launch;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new IMDOToken();
        nft = new ClaimNFTMock();
        nft.mint(alice, 0);
        nft.mint(alice, 1);
        nft.mint(bob, 1999);
        nft.mint(bob, 2000);
        aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(6_000_000e18)))));
        bobLeaf = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(4_000_000e18)))));
        bytes32 root = aliceLeaf < bobLeaf
            ? keccak256(abi.encodePacked(aliceLeaf, bobLeaf))
            : keccak256(abi.encodePacked(bobLeaf, aliceLeaf));
        launch = vm.getBlockTimestamp() + 1 days;
        _deploy(root);
    }

    function _deploy(bytes32 root) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        staking = new ImdoStaking(address(token), address(0x1234), address(0x9000), predicted, address(0x5afe));
        claim = new ImdoClaim(address(token), address(staking), address(nft), 2000, root, launch);
        assertEq(address(claim), predicted);
        token.transfer(address(claim), 110_000_000e18);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function test_seatTransferMovesOnlyRemainingEntitlement() public {
        vm.warp(launch);
        vm.prank(alice);
        claim.claimSeat(_ids(0), false);
        assertEq(token.balanceOf(alice), 5_000e18);
        assertEq(claim.seatClaimedBy(0), alice);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 0);
        vm.expectEmit(true, true, false, true, address(claim));
        emit ImdoClaim.SeatClaimed(0, bob);
        vm.prank(bob);
        claim.claimSeat(_ids(0), false);
        assertEq(claim.seatClaimedBy(0), bob);
        assertEq(token.balanceOf(bob), 0);
        vm.warp(launch + 9 days);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.NotOwner.selector);
        claim.claimSeat(_ids(0), false);
        vm.prank(bob);
        claim.claimSeat(_ids(0), true);
        assertEq(staking.stakedBalance(bob), 45_000e18);
        assertEq(staking.unlockTime(bob), launch + 10 days);
        assertEq(claim.seatClaimed(0), 50_000e18);
        assertEq(token.allowance(address(claim), address(staking)), 0);
    }

    function test_duplicateIdsAndOwnerChecks() public {
        vm.warp(launch);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 0;
        vm.prank(alice);
        claim.claimSeat(ids, false);
        assertEq(token.balanceOf(alice), 5_000e18);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        claim.claimSeat(ids, false);
        vm.prank(bob);
        vm.expectRevert(ImdoClaim.InvalidToken.selector);
        claim.claimSeat(_ids(2000), false);
        vm.prank(bob);
        vm.expectRevert(ImdoClaim.NotOwner.selector);
        claim.claimSeat(_ids(1), false);
    }

    function test_holderProofPartialDoubleClaimAndStake() public {
        vm.warp(launch);
        vm.prank(alice);
        claim.claimHolder(6_000_000e18, _proof(bobLeaf), false);
        assertEq(token.balanceOf(alice), 600_000e18);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        claim.claimHolder(6_000_000e18, _proof(bobLeaf), false);
        vm.prank(bob);
        vm.expectRevert(ImdoClaim.InvalidProof.selector);
        claim.claimHolder(6_000_000e18, _proof(bobLeaf), false);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.InvalidProof.selector);
        claim.claimHolder(6_000_000e18 + 1, _proof(bobLeaf), false);
        vm.warp(launch + 9 days);
        vm.prank(alice);
        claim.claimHolder(6_000_000e18, _proof(bobLeaf), true);
        vm.prank(bob);
        claim.claimHolder(4_000_000e18, _proof(aliceLeaf), false);
        assertEq(staking.stakedBalance(alice), 5_400_000e18);
        assertEq(claim.totalHolderClaimed(), 10_000_000e18);
    }

    function test_zeroRootDisablesHolderClaims() public {
        _deploy(bytes32(0));
        vm.warp(launch);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.InvalidProof.selector);
        claim.claimHolder(1, new bytes32[](0), false);
        vm.prank(alice);
        claim.claimSeat(_ids(0), false);
    }

    function test_launchDeadlineAndBurnBoundaries() public {
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.NothingUnlocked.selector);
        claim.claimSeat(_ids(0), false);
        vm.warp(launch + 39 days - 1);
        vm.prank(alice);
        claim.claimSeat(_ids(0), false);
        vm.expectRevert(ImdoClaim.TooEarly.selector);
        claim.burnUnclaimed();
        uint256 amount = token.balanceOf(address(claim));
        vm.warp(launch + 39 days);
        vm.prank(alice);
        vm.expectRevert(ImdoClaim.ClaimClosed.selector);
        claim.claimSeat(_ids(1), false);
        vm.prank(bob);
        vm.expectRevert(ImdoClaim.ClaimClosed.selector);
        claim.claimHolder(4_000_000e18, _proof(aliceLeaf), false);
        claim.burnUnclaimed();
        assertEq(token.balanceOf(claim.DEAD()), amount);
        assertEq(token.balanceOf(address(claim)), 0);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
