// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ExtensionFixture} from "../utils/ExtensionFixture.sol";
import {NFTClaim} from "../../src/NFTClaim.sol";
import {AdamTreasuryV2} from "../../src/AdamTreasuryV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract ReenteringStakeMock {
    NFTClaim public claimContract;
    bytes public failure;

    function configure(NFTClaim c) external {
        claimContract = c;
    }

    function isExcluded(address) external pure returns (bool) {
        return true;
    }

    function stakeFor(address, uint256 amount) external {
        uint256[] memory list = new uint256[](1);
        list[0] = 0;
        (bool ok, bytes memory result) = address(claimContract).call(abi.encodeCall(NFTClaim.claim, (uint8(0), list)));
        require(!ok, "reentry succeeded");
        failure = result;
        IERC20(address(claimContract.adam())).transferFrom(msg.sender, address(this), amount);
    }
}

/// @custom:x https://x.com/IaMaDamIMD
contract ReenteringKeeper {
    AdamTreasuryV2 public treasury;
    bytes public failure;

    function process(AdamTreasuryV2 t) external {
        treasury = t;
        t.process();
    }

    receive() external payable {
        (bool ok, bytes memory result) = address(treasury).call(abi.encodeWithSignature("process()"));
        require(!ok, "reentry succeeded");
        failure = result;
    }
}

/// @custom:x https://x.com/IaMaDamIMD
contract ExtensionAdversarialTest is ExtensionFixture {
    function testNFTStakeCallbackCannotReenterAndAllowanceIsCleared() public {
        ReenteringStakeMock target = new ReenteringStakeMock();
        NFTClaim c = new NFTClaim(address(adam), address(target), address(nft), address(pepe), 4, 2, block.timestamp);
        target.configure(c);
        adam.transfer(address(c), 110_000_000e18);
        vm.prank(alice);
        c.claimAndStake(0, ids(0));
        assertEq(bytes4(target.failure()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(c.claimed(0, 0), 2_500_000e18);
        assertEq(adam.balanceOf(address(target)), 2_500_000e18);
        assertEq(adam.allowance(address(c), address(target)), 0);
    }

    function testBountyCallbackCannotReenterOrDoubleAllocate() public {
        ReenteringKeeper keeper = new ReenteringKeeper();
        fundTreasury(1 ether);
        keeper.process(t2);
        assertEq(bytes4(keeper.failure()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(address(keeper).balance, 0.005 ether);
        assertEq(t2.teamOwed(), 0.0995 ether);
        assertEq(t2.unsplitEth(), 0);
    }

    function testDirectTokenLockCannotPreventPrincipalOrOtherRewards() public {
        stakeAlice(100_000_000e18);
        imdstr.setDistributor(address(d2), true);
        d2.enableDirectDistribution();
        fundTreasury(1 ether);
        t2.process();
        imdstr.setDistributor(address(d2), false);
        vm.prank(alice);
        vm.expectRevert();
        d2.claim();
        vm.prank(alice);
        d2.claimReward(address(imd));
        vm.prank(alice);
        d2.claimReward(address(pnkstr));
        vm.prank(alice);
        d2.unstake(100_000_000e18);
        assertEq(d2.stakedBalance(alice), 0);
        assertGt(imd.balanceOf(alice), 0);
        assertGt(d2.earned(alice, address(imdstr)), 0);
        imdstr.setDistributor(address(d2), true);
        vm.prank(alice);
        d2.claimReward(address(imdstr));
        assertGt(imdstr.balanceOf(alice), 0);
    }

    function testFuzzTwoStakersNeverClaimMoreETHThanFunded(uint96 a, uint96 b, uint64 funding) public {
        uint256 aStake = bound(a, 1e18, 100_000_000e18);
        uint256 bStake = bound(b, 1e18, 100_000_000e18);
        uint256 value = bound(funding, 1 gwei, 1 ether);
        stakeAlice(aStake);
        vm.prank(bob);
        d2.stake(bStake);
        d2.notifyIMDSTR{value: value}(0);
        uint256 aDue = d2.earned(alice, address(0));
        uint256 bDue = d2.earned(bob, address(0));
        assertLe(aDue + bDue, value);
        assertApproxEqAbs(aDue, value * aStake / (aStake + bStake), 1);
        vm.prank(alice);
        d2.unstake(aStake);
        vm.prank(bob);
        d2.unstake(bStake);
        if (aDue > 0) {
            vm.prank(alice);
            d2.claimIMDSTR(aDue, 1, block.timestamp);
        }
        if (bDue > 0) {
            vm.prank(bob);
            d2.claimIMDSTR(bDue, 1, block.timestamp);
        }
        assertEq(address(d2).balance, value - aDue - bDue);
        assertEq(d2.totalClaimed(address(0)), aDue + bDue);
    }
}
