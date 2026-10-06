// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookDeferredFeesFixture, DeferredFeeRecipient} from "../unit/HookDeferredFees.t.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMDOToken} from "src/IMDOToken.sol";
import {ImdoHook} from "src/ImdoHook.sol";

contract HookHandler is Test {
    PoolManager public manager;
    PoolSwapTest public router;
    IMDOToken public token;
    ImdoHook public hook;
    DeferredFeeRecipient public recipient;
    PoolKey internal key;
    uint256 public fees;
    uint256 public launch;
    uint256 public clock;
    uint16 public base = 150;
    uint256 public buys;
    uint256 public sells;

    constructor(PoolManager m, PoolSwapTest r, IMDOToken t, ImdoHook h, DeferredFeeRecipient p, PoolKey memory k) {
        manager = m;
        router = r;
        token = t;
        hook = h;
        recipient = p;
        key = k;
        clock = vm.getBlockTimestamp();
        t.approve(address(r), type(uint256).max);
    }

    receive() external payable {}

    function feeRate() public view returns (uint256) {
        if (launch == 0) return 2000;
        if (clock >= launch + 1800) return base;
        return base + (2000 - uint256(base)) * (1800 - (clock - launch)) / 1800;
    }

    function _feeBalance() private view returns (uint256) {
        return address(recipient).balance + manager.balanceOf(address(hook), 0);
    }

    function buy(uint96 raw, bool exactOutput) external {
        uint256 amount = exactOutput ? bound(raw, 1e12, 100_000e18) : bound(raw, 1 gwei, 0.1 ether);
        uint256 rate = feeRate();
        uint256 beforeFees = _feeBalance();
        uint256 beforeEth = address(this).balance;
        uint256 beforeTokens = token.balanceOf(address(this));
        router.swap{value: exactOutput ? 1 ether : amount}(
            key,
            SwapParams(true, exactOutput ? int256(amount) : -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        if (launch == 0) launch = clock;
        uint256 spent = beforeEth - address(this).balance;
        uint256 charged = _feeBalance() - beforeFees;
        if (exactOutput) {
            assertEq(token.balanceOf(address(this)) - beforeTokens, amount);
            assertEq(charged, (spent - charged) * rate / (10_000 - rate));
        } else {
            assertEq(spent, amount);
            assertGt(token.balanceOf(address(this)), beforeTokens);
            assertEq(charged, amount * rate / 10_000);
        }
        fees += charged;
        buys++;
    }

    function sell(uint96 raw) external {
        uint256 available = token.balanceOf(address(this));
        if (available < 1e12) return;
        uint256 amount = bound(raw, 1e12, available);
        uint256 beforeFees = _feeBalance();
        uint256 beforeEth = address(this).balance;
        uint256 rate = feeRate();
        router.swap(
            key,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 charged = _feeBalance() - beforeFees;
        uint256 received = address(this).balance - beforeEth;
        assertEq(token.balanceOf(address(this)), available - amount);
        assertGt(received, 0);
        assertEq(charged, (received + charged) * rate / 10_000);
        fees += charged;
        sells++;
    }

    function redeem(bool reject) external {
        uint256 claims = manager.balanceOf(address(hook), 0);
        uint256 beforeFees = _feeBalance();
        uint256 beforeBalance = address(this).balance;
        recipient.setReject(reject);
        if (claims == 0) vm.expectRevert(ImdoHook.NothingToRedeem.selector);
        else if (reject) vm.expectRevert(); // PoolManager wraps the failed native transfer.
        hook.redeemFees();
        recipient.setReject(false);
        assertEq(_feeBalance(), beforeFees);
        assertEq(address(this).balance, beforeBalance, "caller must never receive treasury fees");
        assertEq(manager.balanceOf(address(hook), 0), reject ? claims : 0);
    }

    function lower(uint16 raw) external {
        if (base == 0) return;
        uint16 next = uint16(bound(raw, 0, base - 1));
        vm.prank(hook.owner());
        hook.lowerFee(next);
        base = next;
    }

    function advance(uint32 elapsed) external {
        clock += bound(elapsed, 1, 900);
        vm.warp(clock);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HookInvariantTest is HookDeferredFeesFixture {
    HookHandler internal handler;
    uint256 internal initialTokens;

    function setUp() public override {
        super.setUp();
        initialTokens = token.balanceOf(address(pm));
        assertEq(address(pm).balance, 0, "fresh token-only manager");
        handler = new HookHandler(pm, router, token, hook, recipient, key);
        vm.deal(address(handler), 1000 ether);
        // Every history starts with a real deferred claim, then random trades/redeems exercise it.
        handler.buy(uint96(0.01 ether), false);
        assertEq(pm.balanceOf(address(hook), 0), 0.002 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.lower.selector;
        selectors[4] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allChargedFeesRemainRedeemableOnlyToTreasury() public view {
        uint256 deferred = pm.balanceOf(address(hook), 0);
        assertEq(address(recipient).balance + deferred, handler.fees());
        assertGe(address(pm).balance, deferred);
        assertEq(address(pm).balance + address(recipient).balance + address(handler).balance, 1000 ether);
        assertEq(token.balanceOf(address(pm)) + token.balanceOf(address(handler)), initialTokens);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.launchTimestamp(), handler.launch());
        assertEq(hook.feeBps(), handler.base());
        assertEq(hook.currentFeeBps(), handler.feeRate());
    }

    function afterInvariant() public {
        handler.redeem(false);
        assertEq(pm.balanceOf(address(hook), 0), 0);
        assertEq(address(recipient).balance, handler.fees());
        invariant_allChargedFeesRemainRedeemableOnlyToTreasury();
    }
}
