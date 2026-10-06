// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IMDOToken} from "../../src/IMDOToken.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract StakingHandler is Test {
    IMDOToken public token;
    ImdoStaking public staking;
    MockERC20 public imd;
    uint256[4] public ghostStake;
    uint256[4] public lastCredit;
    uint256 public ghostNotified;
    uint256 public ghostWithdrawn;
    uint256 public ghostImd;
    uint256 public clock;

    constructor(IMDOToken t, ImdoStaking s, MockERC20 r) {
        token = t;
        staking = s;
        imd = r;
        clock = vm.getBlockTimestamp();
        for (uint256 i; i < 4; ++i) {
            vm.prank(actor(i));
            t.approve(address(s), type(uint256).max);
        }
        r.approve(address(s), type(uint256).max);
    }

    function actor(uint256 i) public pure returns (address) {
        return address(uint160(0xa100 + i % 4));
    }

    function _check() private {
        for (uint256 i; i < 4; ++i) {
            uint256 credit = staking.regenCreditOf(actor(i));
            assertGe(credit, lastCredit[i], "lifetime credit decreased");
            lastCredit[i] = credit;
        }
    }

    function stake(uint256 who, uint256 amount) external {
        uint256 i = who % 4;
        uint256 balance = token.balanceOf(actor(i));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor(i));
        staking.stake(amount);
        ghostStake[i] += amount;
        _check();
    }

    function unstake(uint256 who, uint256 amount, bool exit) external {
        uint256 i = who % 4;
        if (ghostStake[i] == 0 || clock < staking.unlockTime(actor(i))) return;
        amount = exit ? ghostStake[i] : bound(amount, 1, ghostStake[i]);
        vm.prank(actor(i));
        if (exit) staking.exit();
        else staking.unstake(amount);
        ghostStake[i] -= amount;
        _check();
    }

    function claim(uint256 who) external {
        vm.prank(actor(who));
        staking.claim();
        _check();
    }

    function notify(uint256 amount, bool regen) external {
        amount = bound(amount, 1, regen ? 100 ether : 1e24);
        if (regen) {
            vm.deal(address(this), amount);
            staking.notifyRegen{value: amount}();
            ghostNotified += amount;
        } else {
            imd.mint(address(this), amount);
            staking.notifyReward(address(imd), amount);
            ghostImd += amount;
        }
        _check();
    }

    function withdraw(uint256 amount) external {
        uint256 available = ghostNotified - ghostWithdrawn;
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(staking.regenSafe());
        staking.withdrawRegen(amount);
        ghostWithdrawn += amount;
        _check();
    }

    function advance(uint32 elapsed) external {
        clock += bound(elapsed, 1, 14 days);
        vm.warp(clock);
        _check();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StakingInvariantTest is Test {
    IMDOToken token;
    ImdoStaking staking;
    MockERC20 imd;
    StakingHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new IMDOToken();
        imd = new MockERC20("IMD", "IMD", 6);
        staking = new ImdoStaking(address(token), address(imd), address(0x9000), address(0xc1a1), address(0x5afe));
        handler = new StakingHandler(token, staking, imd);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actor(i), 250_000_000e18);
        }
        targetContract(address(handler));
    }

    function invariant_principalAndRewardConservation() public view {
        uint256 stake;
        uint256 wallet;
        uint256 paid;
        uint256 credit;
        for (uint256 i; i < 4; ++i) {
            address who = handler.actor(i);
            stake += handler.ghostStake(i);
            wallet += token.balanceOf(who);
            assertEq(staking.stakedBalance(who), handler.ghostStake(i));
            paid += imd.balanceOf(who);
            credit += staking.regenCreditOf(who);
        }
        assertEq(staking.totalStaked(), stake);
        assertEq(token.balanceOf(address(staking)), stake);
        assertEq(wallet + stake, token.totalSupply());
        assertEq(paid + imd.balanceOf(address(staking)), handler.ghostImd());
        assertLe(credit, handler.ghostNotified());
        assertEq(staking.totalRegenNotified(), handler.ghostNotified());
        assertEq(staking.totalRegenWithdrawn(), handler.ghostWithdrawn());
        assertGe(address(staking).balance, handler.ghostNotified() - handler.ghostWithdrawn());
    }
}
