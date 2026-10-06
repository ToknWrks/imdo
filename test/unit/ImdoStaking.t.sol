// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDOToken} from "../../src/IMDOToken.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";

contract RegenReceiver {
    bool public reject = true;
    bool public reenter;
    ImdoStaking public target;

    function configure(ImdoStaking s, bool reject_, bool reenter_) external {
        target = s;
        reject = reject_;
        reenter = reenter_;
    }

    function withdraw(uint256 amount) external {
        target.withdrawRegen(amount);
    }

    receive() external payable {
        require(!reject, "reject");
        if (reenter) target.withdrawRegen(1);
    }
}

contract ImdoStakingTest is Test {
    IMDOToken internal token;
    MockERC20 internal imd;
    ImdoStaking internal staking;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal claimContract = address(0xc1a1);
    address internal regenSafe = address(0x5afe);
    uint256 internal constant FLOOR = 10_000_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1000 ether);
        token = new IMDOToken();
        imd = new MockERC20("IMD", "IMD", 18);
        staking = new ImdoStaking(address(token), address(imd), address(0x9000), claimContract, regenSafe);
        token.transfer(alice, 100_000_000e18);
        token.transfer(bob, 100_000_000e18);
        token.transfer(claimContract, 100_000_000e18);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
        vm.prank(claimContract);
        token.approve(address(staking), type(uint256).max);
        imd.mint(address(this), 1e36);
        imd.approve(address(staking), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    function test_rewardsProRataAndEthIsNeverClaimed() public {
        _stake(alice, 3e18);
        _stake(bob, 1e18);
        staking.notifyReward(address(imd), 400e18);
        staking.notifyRegen{value: 4 ether}();
        uint256 credit = staking.regenCreditOf(alice);
        uint256 ethBefore = alice.balance;
        assertEq(credit, 3 ether);
        vm.prank(alice);
        staking.claim();
        assertEq(imd.balanceOf(alice), 300e18);
        assertEq(alice.balance, ethBefore);
        assertEq(staking.regenCreditOf(alice), credit);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.regenCreditOf(alice), credit);
        assertEq(address(staking).balance, 4 ether);
        vm.expectRevert(abi.encodeWithSelector(ImdoStaking.NotRewardToken.selector, address(0)));
        staking.claimReward(address(0));
    }

    function test_stakeForRestrictedAndEveryStakeResetsLock() public {
        _stake(alice, 1e18);
        uint256 start = vm.getBlockTimestamp();
        vm.prank(bob);
        vm.expectRevert(ImdoStaking.OnlyClaim.selector);
        staking.stakeFor(alice, 1);
        vm.warp(start + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdoStaking.StakeLocked.selector, start + 1 days));
        staking.unstake(1);
        vm.prank(claimContract);
        staking.stakeFor(alice, 1);
        uint256 newUnlock = start + 2 days - 1;
        assertEq(staking.unlockTime(alice), newUnlock);
        vm.warp(newUnlock - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdoStaking.StakeLocked.selector, newUnlock));
        staking.exit();
        vm.warp(newUnlock);
        vm.prank(alice);
        staking.unstake(1);
        _stake(alice, 1);
        assertEq(staking.unlockTime(alice), newUnlock + 1 days);
    }

    function test_backlogThresholdStreamPauseAndNoPastCredit() public {
        staking.notifyRegen{value: 7 ether}();
        staking.notifyReward(address(imd), 700e18);
        _stake(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        assertEq(staking.regenCreditOf(alice), 0);
        _stake(alice, FLOOR - 1);
        uint256 start = vm.getBlockTimestamp();
        assertEq(staking.regenCreditOf(alice), 0);
        vm.warp(start + 1 days);
        assertApproxEqAbs(staking.regenCreditOf(alice), 1 ether, 1);
        _stake(bob, FLOOR);
        assertEq(staking.regenCreditOf(bob), 0);
        vm.warp(start + 2 days);
        vm.prank(bob);
        staking.unstake(FLOOR);
        vm.prank(alice);
        staking.unstake(FLOOR - 1);
        uint256 credit = staking.regenCreditOf(alice);
        assertApproxEqAbs(credit, 1.5 ether, 2);
        vm.warp(start + 90 days);
        assertEq(staking.regenCreditOf(alice), credit);
        _stake(alice, FLOOR - 1);
        vm.warp(start + 97 days);
        vm.prank(alice);
        staking.exit();
        assertApproxEqAbs(staking.regenCreditOf(alice), 6.5 ether, 3);
        assertApproxEqAbs(staking.regenCreditOf(bob), 0.5 ether, 1);
        assertEq(staking.unallocated(address(0)), 0);
        assertEq(staking.unallocated(address(imd)), 0);
    }

    function test_withdrawOnlySafeBoundedEvenWithForcedEthAndNoStake() public {
        staking.notifyRegen{value: 1 ether}();
        vm.deal(address(staking), 3 ether);
        vm.expectRevert(ImdoStaking.OnlyRegenSafe.selector);
        staking.withdrawRegen(1);
        vm.prank(regenSafe);
        vm.expectRevert(ImdoStaking.InsufficientRegen.selector);
        staking.withdrawRegen(1 ether + 1);
        vm.prank(regenSafe);
        staking.withdrawRegen(0.4 ether);
        vm.prank(regenSafe);
        staking.withdrawRegen(0.6 ether);
        assertEq(regenSafe.balance, 1 ether);
        vm.prank(regenSafe);
        vm.expectRevert(ImdoStaking.InsufficientRegen.selector);
        staking.withdrawRegen(1);
        assertEq(staking.unallocated(address(0)), 1 ether);
        assertEq(staking.totalRegenWithdrawn(), staking.totalRegenNotified());
    }

    function test_failedOrReentrantWithdrawalRollsBack() public {
        RegenReceiver receiver = new RegenReceiver();
        ImdoStaking s = new ImdoStaking(address(token), address(imd), address(0x9000), claimContract, address(receiver));
        receiver.configure(s, true, false);
        s.notifyRegen{value: 2 ether}();
        vm.expectRevert(ImdoStaking.RegenTransferFailed.selector);
        receiver.withdraw(1 ether);
        assertEq(s.totalRegenWithdrawn(), 0);
        receiver.configure(s, false, true);
        vm.expectRevert(ImdoStaking.RegenTransferFailed.selector);
        receiver.withdraw(1 ether);
        assertEq(s.totalRegenWithdrawn(), 0);
        receiver.configure(s, false, false);
        receiver.withdraw(2 ether);
        assertEq(s.totalRegenWithdrawn(), 2 ether);
    }

    function test_invalidIntakeAndClaims() public {
        vm.expectRevert(ImdoStaking.ZeroAmount.selector);
        staking.notifyRegen();
        vm.expectRevert(ImdoStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(abi.encodeWithSelector(ImdoStaking.NotRewardToken.selector, address(token)));
        staking.notifyReward(address(token), 1);
        vm.expectRevert(ImdoStaking.ZeroAmount.selector);
        staking.claimReward(address(imd));
        vm.prank(claimContract);
        vm.expectRevert(abi.encodeWithSelector(ImdoStaking.Excluded.selector, regenSafe));
        staking.stakeFor(regenSafe, 1);
    }

    function testFuzz_lifetimeCreditSurvivesClaimsAndExit(uint128 a, uint128 b, uint96 reward) public {
        uint256 amountA = bound(a, 1, 100_000_000e18);
        uint256 amountB = bound(b, 1, 100_000_000e18);
        uint256 value = bound(reward, 1, 100 ether);
        _stake(alice, amountA);
        _stake(bob, amountB);
        staking.notifyRegen{value: value}();
        uint256 credit = staking.regenCreditOf(alice);
        vm.prank(alice);
        staking.claim();
        assertEq(staking.regenCreditOf(alice), credit);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.regenCreditOf(alice), credit);
        vm.prank(regenSafe);
        staking.withdrawRegen(value);
        assertEq(staking.regenCreditOf(alice), credit);
        assertLe(credit + staking.regenCreditOf(bob), value);
        assertEq(token.balanceOf(alice), 100_000_000e18);
    }
}
