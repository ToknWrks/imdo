// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ExtensionFixture} from "../utils/ExtensionFixture.sol";
import {NFTClaim} from "../../src/NFTClaim.sol";
import {AdamDistributor} from "../../src/AdamDistributor.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract NFTClaimTest is ExtensionFixture {
    function testDailyUnlockAndTransferredOwnership() public {
        vm.prank(alice);
        vm.expectRevert(NFTClaim.NothingUnlocked.selector);
        nftClaim.claim(0, ids(0));
        vm.warp(nftClaim.launch());
        uint256 before = adam.balanceOf(alice);
        vm.prank(alice);
        nftClaim.claim(0, ids(0));
        assertEq(adam.balanceOf(alice) - before, 2_500_000e18);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 0);
        vm.warp(nftClaim.launch() + 1 days - 1);
        assertEq(nftClaim.claimable(0, 0), 0);
        vm.warp(nftClaim.launch() + 1 days);
        vm.prank(alice);
        vm.expectRevert(NFTClaim.NotOwner.selector);
        nftClaim.claim(0, ids(0));
        vm.prank(bob);
        nftClaim.claim(0, ids(0));
        assertEq(nftClaim.claimed(0, 0), 5_000_000e18);
        vm.warp(nftClaim.launch() + 9 days);
        vm.prank(bob);
        nftClaim.claim(0, ids(0));
        assertEq(nftClaim.claimed(0, 0), 25_000_000e18);
    }

    function testBatchDuplicateStakeAndNoRewardsForClaimContract() public {
        vm.warp(nftClaim.launch());
        uint256[] memory list = new uint256[](3);
        list[0] = 0;
        list[1] = 1;
        list[2] = 0;
        vm.prank(alice);
        nftClaim.claimAndStake(0, list);
        assertEq(d2.stakedBalance(alice), 5_000_000e18);
        assertEq(d2.stakedBalance(address(nftClaim)), 0);
        assertTrue(d2.isExcluded(address(nftClaim)));
        assertEq(adam.allowance(address(nftClaim), address(d2)), 0);
        vm.expectRevert(abi.encodeWithSelector(AdamDistributor.Excluded.selector, address(nftClaim)));
        d2.stakeFor(address(nftClaim), 1);
        vm.prank(alice);
        vm.expectRevert(NFTClaim.NothingUnlocked.selector);
        nftClaim.claim(0, list);
        vm.prank(alice);
        nftClaim.claim(1, ids(1));
        assertEq(nftClaim.claimed(1, 1), 500_000e18);
    }

    function testInvalidIdsUnauthorizedAndBatchAtomicity() public {
        vm.warp(nftClaim.launch());
        vm.expectRevert(NFTClaim.InvalidToken.selector);
        nftClaim.share(2, 0);
        vm.expectRevert(NFTClaim.InvalidToken.selector);
        nftClaim.share(0, 4);
        vm.expectRevert(NFTClaim.InvalidToken.selector);
        nftClaim.share(1, 0);
        pepe.mint(alice, 3);
        vm.prank(alice);
        vm.expectRevert(NFTClaim.InvalidToken.selector);
        nftClaim.claim(1, ids(3));
        uint256[] memory list = new uint256[](2);
        list[0] = 0;
        list[1] = 2;
        vm.prank(alice);
        vm.expectRevert(NFTClaim.NotOwner.selector);
        nftClaim.claim(0, list);
        assertEq(nftClaim.claimed(0, 0), 0);
    }

    function testBurnDeadlineAndBurnedNFT() public {
        nft.burn(0);
        vm.warp(nftClaim.deadline() - 1);
        vm.expectRevert(NFTClaim.TooEarly.selector);
        nftClaim.burnUnclaimed();
        vm.prank(alice);
        nftClaim.claim(0, ids(1));
        vm.warp(nftClaim.deadline());
        vm.prank(alice);
        vm.expectRevert(NFTClaim.ClaimClosed.selector);
        nftClaim.claim(1, ids(1));
        uint256 remaining = adam.balanceOf(address(nftClaim));
        vm.prank(bob);
        nftClaim.burnUnclaimed();
        assertEq(adam.balanceOf(nftClaim.DEAD()), remaining);
        assertEq(adam.balanceOf(address(nftClaim)), 0);
        assertEq(adam.totalSupply(), 1_000_000_000e18);
    }

    function testFuzzUnlockConservation(uint8 day, uint8 timeOfDay) public {
        uint256 elapsed = bound(day, 0, 38) * 1 days + uint256(timeOfDay) * 100;
        vm.warp(nftClaim.launch() + elapsed);
        uint256 tranches = elapsed / 1 days + 1;
        if (tranches > 10) tranches = 10;
        assertEq(nftClaim.claimable(0, 0), 25_000_000e18 * tranches / 10);
        uint256 initial = adam.balanceOf(address(nftClaim));
        vm.prank(alice);
        nftClaim.claim(0, ids(0));
        assertEq(nftClaim.claimed(0, 0) + adam.balanceOf(address(nftClaim)), initial);
        assertEq(nftClaim.claimable(0, 0), 0);
    }
}
