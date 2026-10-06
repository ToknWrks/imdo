// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LocalV4} from "../utils/LocalV4.sol";

contract IntegrationTest is LocalV4 {
    function test_buyStakeProcessClaimAndWithdraw() public {
        uint256 firstBuy = uint256(uint128(buyExactIn(1 ether).amount1()));
        imdo.transfer(alice, firstBuy);
        vm.startPrank(alice);
        imdo.approve(address(distributor), firstBuy);
        distributor.stake(firstBuy);
        vm.stopPrank();
        buyExactIn(1 ether);
        uint256 fees = address(treasury).balance;
        uint256 bounty = fees * 50 / 10000;
        treasury.process();
        assertEq(treasury.opsOwed(), (fees - bounty) / 10);
        assertEq(treasury.offsetsOwed(), (fees - bounty) / 4);
        assertEq(distributor.totalRegenNotified(), (fees - bounty) / 4);
        uint256 credit = distributor.regenCreditOf(alice);
        assertApproxEqAbs(credit, (fees - bounty) / 4, 1);
        uint256 bought = imd.balanceOf(address(distributor));
        assertGt(bought, 0);
        vm.prank(alice);
        distributor.claim();
        assertApproxEqAbs(imd.balanceOf(alice), bought, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        distributor.exit();
        assertEq(imdo.balanceOf(alice), firstBuy);
        assertEq(distributor.regenCreditOf(alice), credit);
        uint256 regenAmount = distributor.totalRegenNotified();
        vm.prank(regenSafe);
        distributor.withdrawRegen(regenAmount);
        assertEq(distributor.regenCreditOf(alice), credit);
        assertEq(address(distributor).balance, 0);
        vm.prank(opsWallet);
        treasury.payOps();
        vm.prank(offsetsSafe);
        treasury.payOffsets();
        assertEq(address(treasury).balance, 0);
    }
}
