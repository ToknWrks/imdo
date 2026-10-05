// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {AdamDistributor} from "src/AdamDistributor.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Only these four actors own/stake ADAM. Ghost balances are changed from action inputs,
/// never copied from the distributor's accounting. Rewards use both 6 and 18 decimals.
contract DistributorHandler is Test {
    LaunchToken public immutable adam;
    AdamDistributor public immutable dist;
    MockERC20[2] public tokens;
    uint256[4] public wallets;
    uint256[4] public stakes;
    uint256[2] public notified;
    uint256[2] public donatedRewards;
    uint256[2] public paid;
    uint256 public donatedAdam;
    uint256 public calls;
    uint256 public clock;

    constructor(LaunchToken a, AdamDistributor d, MockERC20 t0, MockERC20 t1) {
        adam = a;
        dist = d;
        tokens = [t0, t1];
        clock = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            wallets[i] = 250_000_000e18;
            vm.prank(actor(i));
            a.approve(address(d), type(uint256).max);
        }
        t0.approve(address(d), type(uint256).max);
        t1.approve(address(d), type(uint256).max);
    }

    function actor(uint256 i) public pure returns (address) {
        return address(uint160(0xA100 + i % 4));
    }

    function stake(uint256 who, uint256 amount) public {
        ++calls;
        uint256 i = who % 4;
        if (wallets[i] == 0) return;
        amount = bound(amount, 1, wallets[i]);
        vm.prank(actor(i));
        dist.stake(amount);
        wallets[i] -= amount;
        stakes[i] += amount;
    }

    function unstake(uint256 who, uint256 amount) public {
        ++calls;
        uint256 i = who % 4;
        if (stakes[i] == 0) return;
        amount = bound(amount, 1, stakes[i]);
        vm.prank(actor(i));
        dist.unstake(amount);
        stakes[i] -= amount;
        wallets[i] += amount;
    }

    function move(uint256 from, uint256 to, uint256 amount, bool delegated) external {
        ++calls;
        uint256 i = from % 4;
        uint256 j = to % 4;
        amount = bound(amount, 0, wallets[i]);
        if (delegated) {
            vm.prank(actor(i));
            adam.approve(address(this), amount);
            adam.transferFrom(actor(i), actor(j), amount);
            assertEq(adam.allowance(actor(i), address(this)), 0);
        } else {
            vm.prank(actor(i));
            adam.transfer(actor(j), amount);
        }
        wallets[i] -= amount;
        wallets[j] += amount;
    }

    function reward(uint256 tokenSeed, uint256 amount) public {
        ++calls;
        uint256 j = tokenSeed % 2;
        amount = bound(amount, 1, 1e24);
        tokens[j].mint(address(this), amount);
        dist.notifyReward(address(tokens[j]), amount);
        notified[j] += amount;
    }

    function donate(uint256 who, uint256 amount, uint256 tokenSeed) external {
        ++calls;
        uint256 j = tokenSeed % 3;
        if (j == 2) {
            uint256 i = who % 4;
            amount = bound(amount, 0, wallets[i]);
            vm.prank(actor(i));
            adam.transfer(address(dist), amount);
            donatedAdam += amount;
            wallets[i] -= amount;
        } else {
            amount = bound(amount, 1, 1e24);
            tokens[j].mint(address(this), amount);
            tokens[j].transfer(address(dist), amount);
            donatedRewards[j] += amount;
        }
    }

    function claim(uint256 who, bool exitFirst) public {
        ++calls;
        uint256 i = who % 4;
        uint256[2] memory beforeBalances;
        uint256[2] memory owed;
        for (uint256 j; j < 2; ++j) {
            beforeBalances[j] = tokens[j].balanceOf(actor(i));
            owed[j] = dist.earned(actor(i), address(tokens[j]));
        }
        vm.prank(actor(i));
        if (exitFirst) dist.exit();
        else dist.claim();
        if (exitFirst) {
            wallets[i] += stakes[i];
            stakes[i] = 0;
        }
        for (uint256 j; j < 2; ++j) {
            uint256 received = tokens[j].balanceOf(actor(i)) - beforeBalances[j];
            assertEq(received, owed[j], "earned view must equal actual payment");
            paid[j] += received;
        }
        vm.prank(actor(i));
        dist.claim();
        for (uint256 j; j < 2; ++j) {
            assertEq(tokens[j].balanceOf(actor(i)), beforeBalances[j] + owed[j], "double claim");
        }
    }

    function elapse(uint256 seconds_) public {
        ++calls;
        clock += bound(seconds_, 0, 14 days);
        vm.warp(clock);
    }

    function roundTrip(uint256 who, uint256 amount) external {
        uint256 i = who % 4;
        if (wallets[i] == 0) return;
        amount = bound(amount, 1, wallets[i]);
        uint256 beforeBalance = adam.balanceOf(actor(i));
        uint256 beforeStake = dist.stakedBalance(actor(i));
        stake(i, amount);
        unstake(i, amount);
        assertEq(adam.balanceOf(actor(i)), beforeBalance, "round trip must return all principal");
        assertEq(dist.stakedBalance(actor(i)), beforeStake);
    }

    function invalidWithdrawal(uint256 who) external {
        ++calls;
        uint256 i = who % 4;
        vm.prank(actor(i));
        vm.expectRevert(AdamDistributor.InsufficientStake.selector);
        dist.unstake(stakes[i] + 1);
    }
}

/// @notice Conservation and withdrawal guarantees for the accepted staking architecture.
/// Wallet-holder eligibility is a separate specification finding, not asserted correct here.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DistributorInvariantTest is Test {
    LaunchToken internal adam;
    AdamDistributor internal dist;
    MockERC20[2] internal tokens;
    DistributorHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        adam = new LaunchToken();
        tokens[0] = new MockERC20("Six decimals", "SIX", 6);
        tokens[1] = new MockERC20("Eighteen decimals", "EIGHTEEN", 18);
        dist = new AdamDistributor(address(adam), address(tokens[0]), address(tokens[1]), address(0x9000), address(0));
        handler = new DistributorHandler(adam, dist, tokens[0], tokens[1]);
        for (uint256 i; i < 4; ++i) {
            adam.transfer(handler.actor(i), 250_000_000e18);
        }

        // Reach both backlog and immediate-reward branches before random actions start.
        handler.reward(0, 700e6);
        handler.reward(1, 700e18);
        handler.stake(0, dist.MIN_BACKLOG_STAKE());
        handler.elapse(1 days);
        handler.stake(1, dist.MIN_BACKLOG_STAKE());
        handler.reward(0, 100e6);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.move.selector;
        selectors[3] = handler.reward.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.roundTrip.selector;
        selectors[8] = handler.invalidWithdrawal.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_principalAndFixedSupplyAreConserved() public view {
        uint256 stakeSum;
        uint256 walletSum;
        for (uint256 i; i < 4; ++i) {
            assertEq(adam.balanceOf(handler.actor(i)), handler.wallets(i), "wallet ghost");
            assertEq(dist.stakedBalance(handler.actor(i)), handler.stakes(i), "stake ghost");
            stakeSum += handler.stakes(i);
            walletSum += handler.wallets(i);
        }
        assertEq(dist.totalStaked(), stakeSum);
        assertEq(adam.balanceOf(address(dist)), stakeSum + handler.donatedAdam());
        assertEq(adam.totalSupply(), 1_000_000_000e18);
        assertEq(walletSum + adam.balanceOf(address(dist)), adam.totalSupply());
    }

    function invariant_rewardsAreBackedAndConserved() public view {
        for (uint256 j; j < 2; ++j) {
            address token = address(tokens[j]);
            uint256 paidSum;
            uint256 earnedSum;
            for (uint256 i; i < 4; ++i) {
                paidSum += tokens[j].balanceOf(handler.actor(i));
                earnedSum += dist.earned(handler.actor(i), token);
            }
            assertEq(paidSum, handler.paid(j));
            assertEq(dist.totalClaimed(token), paidSum);
            assertEq(tokens[j].balanceOf(address(dist)) + paidSum, handler.notified(j) + handler.donatedRewards(j));
            assertEq(dist.totalDistributed(token) + dist.unallocated(token), handler.notified(j));
            assertLe(earnedSum + paidSum, handler.notified(j), "no claims on unsolicited donations");
            assertLe(paidSum, dist.totalDistributed(token));

            // Each accumulator increment loses < 1 reward wei in aggregate (ADAM supply < 2**128).
            // Each account settlement loses < 1 more. Sixteen per handler call safely bounds
            // both tokens' settlements, releases and notifications; it is not a percentage tolerance.
            assertGe(paidSum + earnedSum + 16 * (handler.calls() + 1), dist.totalDistributed(token));
        }
    }

    function afterInvariant() public {
        for (uint256 i; i < 4; ++i) {
            handler.claim(i, true);
        }
        assertEq(dist.totalStaked(), 0, "all principal remains withdrawable after every sequence");
        assertEq(adam.balanceOf(address(dist)), handler.donatedAdam());
        invariant_principalAndFixedSupplyAreConserved();
        invariant_rewardsAreBackedAndConserved();
    }
}
