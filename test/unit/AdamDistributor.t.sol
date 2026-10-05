// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LaunchToken} from "../../src/LaunchToken.sol";
import {AdamDistributor} from "../../src/AdamDistributor.sol";

/// @dev Reward token that calls back into the distributor on every transfer out of it.
/// @custom:x https://x.com/IaMaDamIMD
contract ReenteringToken is ERC20 {
    AdamDistributor public target;
    bool public armed;

    constructor() ERC20("Evil", "EVIL") {
        _mint(msg.sender, 1e30);
    }

    function arm(AdamDistributor t) external {
        target = t;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(target)) {
            armed = false;
            target.claim();
        }
    }
}

/// @custom:x https://x.com/IaMaDamIMD
contract AdamDistributorTest is Test {
    LaunchToken internal adam;
    MockERC20 internal imd;
    MockERC20 internal pnkstr;
    AdamDistributor internal dist;

    address internal poolManager = makeAddr("poolManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        adam = new LaunchToken();
        imd = new MockERC20("IMD", "IMD", 18);
        pnkstr = new MockERC20("PNKSTR", "PNKSTR", 18);
        dist = new AdamDistributor(address(adam), address(imd), address(pnkstr), poolManager, address(0));

        imd.mint(address(this), 1e36);
        pnkstr.mint(address(this), 1e36);
        imd.approve(address(dist), type(uint256).max);
        pnkstr.approve(address(dist), type(uint256).max);

        _give(alice, 1_000e18);
        _give(bob, 1_000e18);
        _give(carol, 1_000e18);
    }

    function _give(address who, uint256 amount) internal {
        adam.transfer(who, amount);
        vm.prank(who);
        adam.approve(address(dist), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        dist.stake(amount);
    }

    // ------------------------------------------------------------------ construction

    function test_constructorState() public view {
        assertEq(address(dist.adam()), address(adam));
        address[] memory tokens = dist.rewardTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(imd));
        assertEq(tokens[1], address(pnkstr));
        assertTrue(dist.isRewardToken(address(imd)));
        assertTrue(dist.isRewardToken(address(pnkstr)));
        assertFalse(dist.isRewardToken(address(adam)));
        assertTrue(dist.isExcluded(address(0)));
        assertTrue(dist.isExcluded(0x000000000000000000000000000000000000dEaD));
        assertTrue(dist.isExcluded(address(dist)));
        assertTrue(dist.isExcluded(address(adam)));
        assertTrue(dist.isExcluded(poolManager));
        assertFalse(dist.isExcluded(alice));
    }

    function test_constructorValidation() public {
        vm.expectRevert(AdamDistributor.ZeroAddress.selector);
        new AdamDistributor(address(0), address(imd), address(pnkstr), poolManager, address(0));
        vm.expectRevert(AdamDistributor.ZeroAddress.selector);
        new AdamDistributor(address(adam), address(imd), address(pnkstr), address(0), address(0));
        vm.expectRevert(AdamDistributor.DuplicateRewardToken.selector);
        new AdamDistributor(address(adam), address(imd), address(imd), poolManager, address(0));
    }

    function test_extraExclusionIsApplied() public {
        AdamDistributor d = new AdamDistributor(address(adam), address(imd), address(pnkstr), poolManager, carol);
        assertTrue(d.isExcluded(carol));
    }

    // ------------------------------------------------------------------ staking

    function test_stakeAndUnstake() public {
        _stake(alice, 400e18);
        assertEq(dist.stakedBalance(alice), 400e18);
        assertEq(dist.totalStaked(), 400e18);
        assertEq(adam.balanceOf(address(dist)), 400e18);

        vm.prank(alice);
        dist.unstake(150e18);
        assertEq(dist.stakedBalance(alice), 250e18);
        assertEq(dist.totalStaked(), 250e18);
        assertEq(adam.balanceOf(alice), 750e18);
    }

    function test_stakeRejectsZeroAndExcluded() public {
        vm.prank(alice);
        vm.expectRevert(AdamDistributor.ZeroAmount.selector);
        dist.stake(0);

        adam.transfer(poolManager, 10e18);
        vm.startPrank(poolManager);
        adam.approve(address(dist), 10e18);
        vm.expectRevert(abi.encodeWithSelector(AdamDistributor.Excluded.selector, poolManager));
        dist.stake(10e18);
        vm.stopPrank();

        address dead = 0x000000000000000000000000000000000000dEaD;
        vm.prank(dead);
        vm.expectRevert(abi.encodeWithSelector(AdamDistributor.Excluded.selector, dead));
        dist.stake(1);
    }

    function test_unstakeMoreThanStakedReverts() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(AdamDistributor.InsufficientStake.selector);
        dist.unstake(100e18 + 1);
        vm.prank(alice);
        vm.expectRevert(AdamDistributor.ZeroAmount.selector);
        dist.unstake(0);
    }

    // ------------------------------------------------------------------ rewards

    function test_rewardsProRataAcrossTwoTokens() public {
        _stake(alice, 300e18);
        _stake(bob, 100e18);
        dist.notifyReward(address(imd), 1_000e18);
        dist.notifyReward(address(pnkstr), 40_000e18);

        assertEq(dist.earned(alice, address(imd)), 750e18);
        assertEq(dist.earned(bob, address(imd)), 250e18);
        assertEq(dist.earned(alice, address(pnkstr)), 30_000e18);
        assertEq(dist.earned(bob, address(pnkstr)), 10_000e18);
        assertEq(dist.totalDistributed(address(imd)), 1_000e18);

        vm.prank(alice);
        dist.claim();
        assertEq(imd.balanceOf(alice), 750e18);
        assertEq(pnkstr.balanceOf(alice), 30_000e18);
        assertEq(dist.earned(alice, address(imd)), 0);
        assertEq(dist.totalClaimed(address(imd)), 750e18);

        // Bob's share is untouched and claimable later.
        vm.prank(bob);
        dist.claim();
        assertEq(imd.balanceOf(bob), 250e18);
        assertEq(pnkstr.balanceOf(bob), 10_000e18);
        assertEq(imd.balanceOf(address(dist)), 0);
        assertEq(pnkstr.balanceOf(address(dist)), 0);
    }

    function test_rewardsOnlyAccrueWhileStaked() public {
        _stake(alice, 100e18);
        dist.notifyReward(address(imd), 100e18); // alice alone
        _stake(bob, 100e18);
        dist.notifyReward(address(imd), 100e18); // split 50/50
        vm.prank(alice);
        dist.unstake(100e18);
        dist.notifyReward(address(imd), 100e18); // bob alone

        assertEq(dist.earned(alice, address(imd)), 150e18);
        assertEq(dist.earned(bob, address(imd)), 150e18);
    }

    function test_rewardsBeforeAnyStakeWaitForMeaningfulStake() public {
        dist.notifyReward(address(imd), 500e18);
        assertEq(dist.unallocated(address(imd)), 500e18);
        assertEq(dist.totalDistributed(address(imd)), 0);

        _stake(alice, 100e18);
        assertEq(dist.earned(alice, address(imd)), 0, "not credited until the next notify");
        dist.notifyReward(address(imd), 100e18);
        assertEq(dist.unallocated(address(imd)), 500e18);
        assertEq(dist.earned(alice, address(imd)), 100e18);
    }

    function test_notifyRejectsUnknownTokenAndZero() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        other.mint(address(this), 1e18);
        other.approve(address(dist), 1e18);
        vm.expectRevert(abi.encodeWithSelector(AdamDistributor.NotRewardToken.selector, address(other)));
        dist.notifyReward(address(other), 1e18);
        vm.expectRevert(AdamDistributor.ZeroAmount.selector);
        dist.notifyReward(address(imd), 0);
    }

    function test_notifyRequiresAllowance() public {
        vm.prank(alice);
        vm.expectRevert();
        dist.notifyReward(address(imd), 1e18);
    }

    function test_claimWithNothingIsANoop() public {
        vm.prank(alice);
        dist.claim();
        assertEq(imd.balanceOf(alice), 0);
    }

    function test_exitWithdrawsAndClaims() public {
        _stake(alice, 100e18);
        dist.notifyReward(address(imd), 10e18);
        vm.prank(alice);
        dist.exit();
        assertEq(adam.balanceOf(alice), 1_000e18);
        assertApproxEqAbs(imd.balanceOf(alice), 10e18, 1, "floor division leaves at most 1 wei");
        assertEq(dist.stakedBalance(alice), 0);
        assertEq(dist.totalStaked(), 0);
    }

    function test_unstakeKeepsAccruedRewardsClaimable() public {
        _stake(alice, 100e18);
        dist.notifyReward(address(pnkstr), 10e18);
        vm.prank(alice);
        dist.unstake(100e18);
        assertApproxEqAbs(dist.earned(alice, address(pnkstr)), 10e18, 1);
        vm.prank(alice);
        dist.claim();
        assertApproxEqAbs(pnkstr.balanceOf(alice), 10e18, 1);
        assertEq(pnkstr.balanceOf(alice), dist.totalClaimed(address(pnkstr)));
    }

    function test_tokensSentDirectlyAreNotStakedButRewardsFromBalanceDiff() public {
        // A direct transfer is not a reward; only `notifyReward` credits.
        imd.transfer(address(dist), 5e18);
        _stake(alice, 1e18);
        assertEq(dist.earned(alice, address(imd)), 0);
    }

    function test_noOwnerOrAdminEntryPoints() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("setExcluded(address,bool)")),
            bytes4(keccak256("addRewardToken(address)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("recoverERC20(address,uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(dist).call(abi.encodeWithSelector(selectors[i], address(this), true));
            assertFalse(ok);
        }
    }

    // ------------------------------------------------------------------ reentrancy

    function test_claimIsReentrancySafe() public {
        ReenteringToken evil = new ReenteringToken();
        AdamDistributor d = new AdamDistributor(address(adam), address(evil), address(pnkstr), poolManager, address(0));
        evil.approve(address(d), type(uint256).max);
        vm.prank(alice);
        adam.approve(address(d), type(uint256).max);
        vm.prank(alice);
        d.stake(100e18);
        d.notifyReward(address(evil), 10e18);

        evil.arm(d);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        d.claim();
        assertApproxEqAbs(d.earned(alice, address(evil)), 10e18, 1, "state unchanged after the failed re-entry");
        assertEq(evil.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------ conservation

    function testFuzz_claimsNeverExceedDistributed(uint256 a, uint256 b, uint256 c, uint256 r1, uint256 r2) public {
        a = bound(a, 1, 1_000e18);
        b = bound(b, 1, 1_000e18);
        c = bound(c, 1, 1_000e18);
        r1 = bound(r1, 1, 1e30);
        r2 = bound(r2, 1, 1e30);

        _stake(alice, a);
        dist.notifyReward(address(imd), r1);
        _stake(bob, b);
        dist.notifyReward(address(imd), r2);
        _stake(carol, c);
        dist.notifyReward(address(pnkstr), r1);

        vm.prank(alice);
        dist.exit();
        vm.prank(bob);
        dist.exit();
        vm.prank(carol);
        dist.exit();

        uint256 paidImd = imd.balanceOf(alice) + imd.balanceOf(bob) + imd.balanceOf(carol);
        uint256 paidPnk = pnkstr.balanceOf(alice) + pnkstr.balanceOf(bob) + pnkstr.balanceOf(carol);
        assertLe(paidImd, r1 + r2, "never pays more than received");
        assertLe(paidPnk, r1);
        // Rounding dust is at most one wei per staker per distribution.
        assertGe(paidImd + 6, r1 + r2);
        assertGe(paidPnk + 3, r1);
        assertEq(dist.totalStaked(), 0);
        assertEq(adam.balanceOf(address(dist)), 0, "all ADAM returned");
        assertEq(imd.balanceOf(address(dist)), r1 + r2 - paidImd);
    }

    function testFuzz_stakeUnstakeRoundTrip(uint256 amount, uint256 part) public {
        amount = bound(amount, 1, 1_000e18);
        part = bound(part, 1, amount);
        _stake(alice, amount);
        vm.prank(alice);
        dist.unstake(part);
        assertEq(dist.stakedBalance(alice), amount - part);
        assertEq(adam.balanceOf(alice) + dist.stakedBalance(alice), 1_000e18);
    }

    function test_exitAfterUnstakeStillClaims() public {
        _stake(alice, 100e18);
        dist.notifyReward(address(imd), 10e18);
        vm.startPrank(alice);
        dist.unstake(100e18);
        dist.exit();
        dist.exit(); // repeated settlement is a no-op
        vm.stopPrank();
        assertApproxEqAbs(imd.balanceOf(alice), 10e18, 1);
        assertEq(dist.earned(alice, address(imd)), 0);
    }

    function test_dustCannotCaptureBacklogEvenAfterWaiting() public {
        dist.notifyReward(address(imd), 1_000e18);
        dist.notifyReward(address(pnkstr), 100_000e18);
        _stake(alice, 1);
        dist.notifyReward(address(imd), 1);
        dist.notifyReward(address(pnkstr), 1);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        dist.exit();
        assertEq(imd.balanceOf(alice), 1);
        assertEq(pnkstr.balanceOf(alice), 1);
        assertEq(dist.unallocated(address(imd)), 1_000e18);
        assertEq(dist.unallocated(address(pnkstr)), 100_000e18);
    }

    function test_backlogStreamsAndNewcomerCannotClaimPastTime() public {
        uint256 floor = dist.MIN_BACKLOG_STAKE();
        _give(alice, floor);
        _give(bob, floor);
        dist.notifyReward(address(imd), 700e18);
        dist.notifyReward(address(pnkstr), 7_000e18);
        _stake(alice, floor);
        uint256 start = block.timestamp;
        assertEq(dist.earned(alice, address(imd)), 0, "no instant jackpot at threshold");
        vm.warp(start + 1 days);
        assertApproxEqAbs(dist.earned(alice, address(imd)), 100e18, 1);
        _stake(bob, floor);
        assertEq(dist.earned(bob, address(imd)), 0, "no retroactive accrual");
        vm.warp(start + 7 days);
        assertApproxEqAbs(dist.earned(alice, address(imd)), 400e18, 2);
        assertApproxEqAbs(dist.earned(bob, address(imd)), 300e18, 1);
        vm.prank(alice);
        dist.exit();
        vm.prank(bob);
        dist.exit();
        assertEq(dist.unallocated(address(imd)), 0);
        assertEq(dist.unallocated(address(pnkstr)), 0);
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), 700e18);
        assertApproxEqAbs(pnkstr.balanceOf(alice) + pnkstr.balanceOf(bob), 7_000e18, 3);
    }

    function test_backlogPausesBelowThresholdWithoutRetroactiveVesting() public {
        uint256 floor = dist.MIN_BACKLOG_STAKE();
        _give(alice, floor);
        dist.notifyReward(address(imd), 700e18);
        _stake(alice, floor);
        uint256 start = block.timestamp;
        vm.warp(start + 1 days);
        vm.prank(alice);
        dist.unstake(floor - 1);
        assertEq(dist.unallocated(address(imd)), 600e18);
        vm.warp(start + 365 days);
        assertApproxEqAbs(dist.earned(alice, address(imd)), 100e18, 1);
        _stake(alice, floor - 1);
        assertApproxEqAbs(dist.earned(alice, address(imd)), 100e18, 1);
        vm.warp(start + 372 days);
        vm.prank(alice);
        dist.exit();
        assertEq(dist.unallocated(address(imd)), 0);
        assertApproxEqAbs(imd.balanceOf(alice), 700e18, 2);
    }

    function testFuzz_backlogConservation(uint128 reward, uint32 elapsed) public {
        reward = uint128(bound(reward, 1, 1e30));
        elapsed = uint32(bound(elapsed, 0, 14 days));
        uint256 floor = dist.MIN_BACKLOG_STAKE();
        _give(alice, floor);
        dist.notifyReward(address(imd), reward);
        _stake(alice, floor);
        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        dist.exit();
        assertEq(dist.unallocated(address(imd)) + dist.totalDistributed(address(imd)), reward);
        assertLe(dist.totalClaimed(address(imd)), dist.totalDistributed(address(imd)));
        assertEq(imd.balanceOf(address(dist)) + imd.balanceOf(alice), reward);
    }
}
