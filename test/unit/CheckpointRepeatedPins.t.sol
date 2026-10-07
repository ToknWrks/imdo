// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Swarm review job 37ac5d94, judge finding 1 (low): the rise bound was per buy, so repeated sandwiched dust buys ratcheted the floor above spot for days. Kept as a regression test; the rise now scales with ethIn / maxEthPerBuy.

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDOToken} from "src/IMDOToken.sol";
import {ImdoStaking} from "src/ImdoStaking.sol";
import {ImdoTreasury} from "src/ImdoTreasury.sol";

/// @notice The MAX_CHECKPOINT_RISE_BPS ceiling is applied per successful buy, relative to the floor that buy
/// enforced, and independent of how much ETH the buy spent. A 1-gwei buy at a pushed price therefore lifts the
/// checkpoint by the full 2% (sqrt), and repeating it every cooldown compounds: after N pins the floor is
/// ~1.02^N * 0.999^N of market. The decay only closes 0.1% per 600 s, so the stall after N pins is about
/// 7d * (1.02^N / 1.0153 - 1): 12 dust pins (2 hours of attacker time) stall the IMD leg for about 1.6 days,
/// not the "under an hour" one pin is documented to cost. The test asserts the leg recovers within a day.
contract RepeatedPinsTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 imd;
    IMDOToken imdo;
    ImdoStaking staking;
    ImdoTreasury treasury;
    PoolKey imdKey;
    address alice = makeAddr("alice");

    receive() external payable {}

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        vm.deal(address(this), 100_000 ether);
        imd = new MockERC20("Identity.md", "IMD", 18);
        imd.mint(address(this), 1e36);
        imd.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        imdKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(imd)), 10000, 200, IHooks(address(0)));
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(54000);
        manager.initialize(imdKey, sqrtP);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(-887200),
            TickMath.getSqrtPriceAtTick(887200),
            200 ether,
            type(uint128).max
        );
        lpRouter.modifyLiquidity{value: 200 ether}(
            imdKey, ModifyLiquidityParams(-887200, 887200, int256(uint256(liquidity)), 0), ""
        );
        imdo = new IMDOToken();
        staking =
            new ImdoStaking(address(imdo), address(imd), address(manager), makeAddr("claim"), makeAddr("regenSafe"));
        treasury = new ImdoTreasury(
            address(staking),
            makeAddr("ops"),
            makeAddr("offsets"),
            makeAddr("regenSafe"),
            address(manager),
            address(imd),
            10000,
            200,
            address(0),
            1 ether,
            300,
            600,
            0.5 ether,
            0.05 ether,
            5 ether
        );
        imdo.transfer(alice, 1e18);
        vm.startPrank(alice);
        imdo.approve(address(staking), type(uint256).max);
        staking.stake(1e18);
        vm.stopPrank();
    }

    function _spot() internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(imdKey.toId());
    }

    function _limitSwap(bool zeroForOne, uint160 limit, uint256 ethValue) internal {
        swapRouter.swap{value: ethValue}(
            imdKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1e30), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok);
    }

    function _floorNow() internal view returns (uint256) {
        ImdoTreasury.Leg memory l = treasury.leg(0);
        return FullMath.mulDiv(l.checkpointSqrtPriceX96, 7 days, 7 days + vm.getBlockTimestamp() - l.checkpointAt);
    }

    function test_repeatedDustPinsRatchetTheFloorAboveSpotForDays() public {
        _fund(1 ether);
        treasury.process(); // honest buy anchors the checkpoint at market
        uint160 market = _spot();
        uint256 cp0 = treasury.leg(0).checkpointSqrtPriceX96;
        // twelve cooldowns: sell IMD until the sqrt-price clears the next ceiling, let the treasury buy ~1 gwei
        // there, buy back to market. Each pin lifts the checkpoint by the full MAX_CHECKPOINT_RISE_BPS step.
        for (uint256 r; r < 12; ++r) {
            vm.warp(vm.getBlockTimestamp() + 600);
            uint160 target = uint160(_floorNow() * 103 / 100);
            if (target > _spot()) _limitSwap(false, target, 0);
            _fund(3 gwei);
            treasury.process();
            assertEq(treasury.leg(0).pending, 0, "dust buy fills at the pushed price");
            _limitSwap(true, market, 5000 ether);
        }
        uint256 cp = treasury.leg(0).checkpointSqrtPriceX96;
        emit log_named_uint("checkpoint / original checkpoint (bps)", cp * 10_000 / cp0);
        emit log_named_uint("checkpoint / market (bps)", cp * 10_000 / market);
        // the pool is back at market; the IMD leg must be live again within a day
        uint256 failed;
        bool bought;
        for (uint256 i; i < 144 && !bought; ++i) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _fund(0.01 ether);
            uint256 before = imd.balanceOf(address(staking));
            treasury.process();
            if (imd.balanceOf(address(staking)) > before) bought = true;
            else ++failed;
        }
        emit log_named_uint("failed process() calls before recovery", failed);
        assertTrue(bought, "IMD leg stalled for more than a day after twelve dust pins");
    }
}
