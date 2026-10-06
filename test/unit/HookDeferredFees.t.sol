// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IMDOToken} from "../../src/IMDOToken.sol";
import {ImdoHook} from "../../src/ImdoHook.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";

contract DeferredFeeRecipient {
    bool public reject;

    function setReject(bool flag) external {
        reject = flag;
    }

    receive() external payable {
        require(!reject);
    }
}

abstract contract HookDeferredFeesFixture is Test {
    PoolManager pm;
    PoolSwapTest router;
    IMDOToken token;
    ImdoHook hook;
    PoolKey key;
    DeferredFeeRecipient recipient;
    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 100 ether);
        pm = new PoolManager(address(this));
        router = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        token = new IMDOToken();
        recipient = new DeferredFeeRecipient();
        (, bytes32 salt) = HookMiner.find(
            address(this),
            0x20cc,
            type(ImdoHook).creationCode,
            abi.encode(address(pm), address(token), address(recipient), address(this))
        );
        hook = new ImdoHook{salt: salt}(pm, address(token), address(recipient), address(this));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 60, IHooks(address(hook)));
        uint160 price = TickMath.getSqrtPriceAtTick(177240);
        pm.initialize(key, price);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(108180), price, 890_000_000e18);
        token.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(108180, 177240, int256(uint256(liquidity)), 0), "");
    }

    function _buy() internal {
        router.swap{value: 1 ether}(
            key,
            SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}

contract HookDeferredFeesTest is HookDeferredFeesFixture {
    function test_firstBuyOnTokenOnlyManagerThenPermissionlessRedemption() public {
        assertEq(address(pm).balance, 0);
        uint256 before = token.balanceOf(address(this));
        _buy();
        assertGt(token.balanceOf(address(this)), before);
        assertEq(pm.balanceOf(address(hook), 0), 0.2 ether);
        assertEq(address(recipient).balance, 0);
        vm.prank(address(0xb0b));
        hook.redeemFees();
        assertEq(address(recipient).balance, 0.2 ether);
        assertEq(pm.balanceOf(address(hook), 0), 0);
        assertEq(address(pm).balance, 0.8 ether);
        vm.expectRevert(ImdoHook.NothingToRedeem.selector);
        hook.redeemFees();
    }

    function test_failedRedemptionPreservesClaimAndCannotRedirect() public {
        recipient.setReject(true);
        _buy();
        vm.expectRevert();
        hook.redeemFees();
        assertEq(pm.balanceOf(address(hook), 0), 0.2 ether);
        recipient.setReject(false);
        hook.redeemFees();
        assertEq(address(recipient).balance, 0.2 ether);
        vm.expectRevert(ImdoHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(1));
        vm.prank(address(pm));
        vm.expectRevert(ImdoHook.NotRedeeming.selector);
        hook.unlockCallback(abi.encode(1));
    }

    function test_fundedManagerUsesOriginalDirectPayment() public {
        vm.deal(address(pm), 0.2 ether);
        _buy();
        assertEq(address(recipient).balance, 0.2 ether);
        assertEq(pm.balanceOf(address(hook), 0), 0);
    }

    function test_freshManagerExactOutputBuyAlsoDefersFee() public {
        router.swap{value: 1 ether}(
            key,
            SwapParams(true, int256(1_000_000e18), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 fee = pm.balanceOf(address(hook), 0);
        assertGt(fee, 0);
        hook.redeemFees();
        assertEq(address(recipient).balance, fee);
    }
}
