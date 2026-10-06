// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {ImdoStaking} from "src/ImdoStaking.sol";

/// @dev An external reward token with independently selectable failure modes.
contract AdversarialReward is ERC20 {
    ImdoStaking public target;
    uint16 public intakeTax;
    bool public returnFalse;
    bool public omitReturn;
    bool public paused;
    bool public callback;
    uint256 public blockedCallbacks;
    error TokenPaused();

    constructor() ERC20("Reward stand-in", "RWD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(ImdoStaking d, uint16 tax, bool fail, bool noReturn, bool pause_, bool reenter) external {
        target = d;
        intakeTax = tax;
        returnFalse = fail;
        omitReturn = noReturn;
        paused = pause_;
        callback = reenter;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        super.transfer(to, amount);
        if (omitReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        super.transferFrom(from, to, amount);
        if (omitReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (paused) revert TokenPaused();
        uint256 tax = to == address(target) ? amount * intakeTax / 10_000 : 0;
        if (tax != 0) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
        if (callback && (from == address(target) || to == address(target))) {
            callback = false;
            bytes[5] memory attempts = [
                abi.encodeCall(ImdoStaking.stake, (1)),
                abi.encodeCall(ImdoStaking.unstake, (1)),
                abi.encodeCall(ImdoStaking.claim, ()),
                abi.encodeCall(ImdoStaking.exit, ()),
                abi.encodeCall(ImdoStaking.notifyReward, (address(this), 1))
            ];
            for (uint256 i; i < attempts.length; ++i) {
                (bool ok, bytes memory reason) = address(target).call(attempts[i]);
                require(
                    !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "unguarded callback"
                );
                ++blockedCallbacks;
            }
        }
    }
}

contract DistributorAdversarialTest is Test {
    LaunchToken internal imdo;
    AdversarialReward internal reward0;
    AdversarialReward internal reward1;
    ImdoStaking internal dist;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MANAGER = address(0x9000);
    address internal constant EXTRA = address(0x9001);

    function setUp() public {
        vm.warp(1_800_000_000);
        imdo = new LaunchToken();
        reward0 = new AdversarialReward();
        reward1 = new AdversarialReward();
        dist = new ImdoStaking(address(imdo), address(reward0), MANAGER, EXTRA, address(0x9002));
        reward0.configure(dist, 0, false, false, false, false);
        reward1.configure(dist, 0, false, false, false, false);
        reward0.mint(address(this), 1e30);
        reward1.mint(address(this), 1e30);
        reward0.approve(address(dist), type(uint256).max);
        reward1.approve(address(dist), type(uint256).max);
        imdo.transfer(ALICE, 100_000_000e18);
        imdo.transfer(BOB, 100_000_000e18);
        vm.prank(ALICE);
        imdo.approve(address(dist), type(uint256).max);
        vm.prank(BOB);
        imdo.approve(address(dist), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        dist.stake(amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_taxedRewardCreditsOnlyReceivedTokens(uint256 amount, uint16 tax) public {
        amount = bound(amount, 1, 1e24);
        tax = uint16(bound(tax, 0, 9999));
        reward0.configure(dist, tax, false, false, false, false);
        _stake(ALICE, 1e18);
        uint256 supplyBefore = reward0.totalSupply();
        dist.notifyReward(address(reward0), amount);
        uint256 received = reward0.balanceOf(address(dist));
        uint256 burned = supplyBefore - reward0.totalSupply();
        assertEq(received + burned, amount);
        assertEq(dist.totalDistributed(address(reward0)), received);
        vm.prank(ALICE);
        dist.claim();
        assertApproxEqAbs(reward0.balanceOf(ALICE), received, 1);
        assertEq(reward0.balanceOf(ALICE) + reward0.balanceOf(address(dist)), received);
    }

    function test_oneWeiAndCompleteTransferTax() public {
        _stake(ALICE, 1);
        dist.notifyReward(address(reward0), 1);
        vm.prank(ALICE);
        dist.claim();
        assertEq(reward0.balanceOf(ALICE), 1);
        reward0.configure(dist, 10_000, false, false, false, false);
        uint256 beforeBalance = reward0.balanceOf(address(this));
        vm.expectRevert(ImdoStaking.ZeroAmount.selector);
        dist.notifyReward(address(reward0), 100);
        assertEq(reward0.balanceOf(address(this)), beforeBalance, "burn must roll back on zero receipt");
        assertEq(dist.totalDistributed(address(reward0)), 1);
    }

    function test_noReturnTokenCanNotifyAndClaim() public {
        reward0.configure(dist, 0, false, true, false, false);
        _stake(ALICE, 1e18);
        dist.notifyReward(address(reward0), 50e6);
        vm.prank(ALICE);
        dist.claim();
        assertApproxEqAbs(reward0.balanceOf(ALICE), 50e6, 1);
        assertEq(reward0.balanceOf(ALICE), dist.totalClaimed(address(reward0)));
    }

    function test_falseReturningIntakeCannotCreateCredit() public {
        _stake(ALICE, 1e18);
        reward0.configure(dist, 0, true, false, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward0)));
        dist.notifyReward(address(reward0), 1e6);
        assertEq(dist.totalDistributed(address(reward0)), 0);
        assertEq(dist.earned(ALICE, address(reward0)), 0);
        assertEq(reward0.balanceOf(address(dist)), 0);
    }

    function test_pausedRewardCannotTrapUnstakedPrincipal() public {
        _stake(ALICE, 1e18);
        dist.notifyReward(address(reward0), 100e6);
        uint256 principalBefore = imdo.balanceOf(ALICE);
        reward0.configure(dist, 0, false, false, true, false);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        dist.unstake(1e18);
        assertEq(imdo.balanceOf(ALICE), principalBefore + 1e18);
        assertEq(dist.stakedBalance(ALICE), 0);
        assertApproxEqAbs(dist.earned(ALICE, address(reward0)), 100e6, 1);
        reward0.configure(dist, 0, false, false, false, false);
        vm.prank(ALICE);
        dist.claim();
        assertApproxEqAbs(reward0.balanceOf(ALICE), 100e6, 1);
    }

    function test_notifyCallbackCannotReenterAnyHolderOrRewardAction() public {
        _stake(ALICE, 1e18);
        reward0.configure(dist, 0, false, false, false, true);
        dist.notifyReward(address(reward0), 100e6);
        assertEq(reward0.blockedCallbacks(), 5);
        assertEq(dist.totalDistributed(address(reward0)), 100e6);
        assertEq(dist.totalStaked(), 1e18);
    }

    function test_claimCallbackCannotReenterAnyHolderOrRewardAction() public {
        _stake(ALICE, 1e18);
        dist.notifyReward(address(reward0), 100e6);
        reward0.configure(dist, 0, false, false, false, true);
        vm.prank(ALICE);
        dist.claim();
        assertEq(reward0.blockedCallbacks(), 5);
        assertEq(reward0.balanceOf(ALICE), dist.totalClaimed(address(reward0)));
        assertEq(dist.earned(ALICE, address(reward0)), 0);
    }

    function test_failedStakeRollsBackBacklogAndShares() public {
        dist.notifyReward(address(reward0), 700e6);
        _stake(ALICE, dist.MIN_BACKLOG_STAKE());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 beforeIndex = dist.rewardPerShare(address(reward0));
        uint256 beforeReserve = dist.unallocated(address(reward0));
        uint256 beforeStake = dist.totalStaked();
        vm.prank(BOB);
        imdo.approve(address(dist), 0);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(dist), 0, 1e18)
        );
        dist.stake(1e18);
        assertEq(dist.totalStaked(), beforeStake);
        assertEq(dist.stakedBalance(BOB), 0);
        assertEq(dist.unallocated(address(reward0)), beforeReserve);
        assertEq(dist.rewardPerShare(address(reward0)), beforeIndex);
        assertEq(imdo.balanceOf(address(dist)), beforeStake);
    }

    function test_allFixedExclusionsRejectStakeBeforeTokenInteraction() public {
        address[8] memory excluded = [
            address(0), address(0xdead), address(dist), address(imdo), MANAGER, address(reward0), address(0x9002), EXTRA
        ];
        for (uint256 i; i < excluded.length; ++i) {
            vm.prank(excluded[i]);
            vm.expectRevert(abi.encodeWithSelector(ImdoStaking.Excluded.selector, excluded[i]));
            dist.stake(1);
            assertEq(dist.stakedBalance(excluded[i]), 0);
            assertEq(dist.earned(excluded[i], address(reward0)), 0);
        }
        assertEq(dist.totalStaked(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoEpochsFollowStakeOwnership(uint256 a, uint256 b, uint256 first, uint256 second) public {
        a = bound(a, 1, 100_000_000e18);
        b = bound(b, 1, 100_000_000e18);
        first = bound(first, 1, 1e24);
        second = bound(second, 1, 1e24);
        _stake(ALICE, a);
        _stake(BOB, b);
        dist.notifyReward(address(reward0), first);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        dist.unstake(a);
        dist.notifyReward(address(reward0), second);
        vm.prank(ALICE);
        dist.claim();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(BOB);
        dist.exit();
        // Independent rational allocation by ownership in each epoch; no accumulator reimplementation.
        assertApproxEqAbs(reward0.balanceOf(ALICE), first * a / (a + b), 1);
        assertApproxEqAbs(reward0.balanceOf(BOB), first * b / (a + b) + second, 2);
        assertEq(reward0.balanceOf(ALICE) + reward0.balanceOf(BOB) + reward0.balanceOf(address(dist)), first + second);
    }

    function test_fullSupplyCanStakeAndExit() public {
        uint256 aliceBalance = imdo.balanceOf(ALICE);
        uint256 bobBalance = imdo.balanceOf(BOB);
        vm.prank(ALICE);
        imdo.transfer(address(this), aliceBalance);
        vm.prank(BOB);
        imdo.transfer(address(this), bobBalance);
        imdo.approve(address(dist), type(uint256).max);
        dist.stake(imdo.totalSupply());
        dist.notifyReward(address(reward0), 1e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        dist.exit();
        assertEq(imdo.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(imdo.balanceOf(address(dist)), 0);
        assertApproxEqAbs(reward0.balanceOf(address(this)), 1e30, 1);
    }
}
