// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Swarm review job 37ac5d94, judge finding 3 (low): a floor-clamped refresh reset the decay anchor, so under repeated sandwiched buys the floor decayed geometrically below the documented 7-day hyperbola. Kept as a regression test; the anchor now moves only on a true rise.

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

/// @notice `_refreshCheckpoint` writes `checkpointSqrtPriceX96 = floorNow` and `checkpointAt = now` whenever the
/// post-swap price sits under the floor. Each refresh therefore restarts the 7-day hyperbola from a lower anchor:
/// after N sandwiched buys spaced dt apart the enforced floor is cp0 * prod(7d / (7d + dt)) = cp0 * (7d/(7d+dt))^N,
/// a geometric decay, instead of the documented cp0 * 7d / (7d + N*dt). Three days of 600 s rounds give 0.651 vs
/// 0.700 of the original checkpoint (sqrt price), i.e. the treasury accepts ~15% fewer IMD per ETH than the stated
/// decay allows. The test asserts the floor never falls under the documented hyperbola.
contract FloorCompoundsTest is Test {
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

    function test_sandwichedRefreshesCompoundTheDecayBelowTheDocumentedHyperbola() public {
        _fund(1 ether);
        treasury.process(); // honest buy: the checkpoint is anchored at (cp0, t0)
        uint160 market = _spot();
        uint256 cp0 = treasury.leg(0).checkpointSqrtPriceX96;
        uint256 t0 = vm.getBlockTimestamp();
        // three days of cooldown-spaced buys, each pushed 0.9% under the floor the treasury enforces
        for (uint256 r; r < 432; ++r) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _fund(1 ether);
            uint160 target = uint160(_floorNow() * 991 / 1000);
            if (target < _spot()) _limitSwap(true, target, 5000 ether);
            treasury.process();
            assertEq(treasury.leg(0).pending, 0, "treasury buy must still fill");
            _limitSwap(false, market, 0);
        }
        uint256 elapsed = vm.getBlockTimestamp() - t0;
        uint256 documented = FullMath.mulDiv(cp0, 7 days, 7 days + elapsed); // cp0 * 7d / (7d + 3d) = 0.700 cp0
        uint256 enforced = _floorNow();
        emit log_named_uint("elapsed seconds", elapsed);
        emit log_named_uint("documented floor / cp0 (bps)", documented * 10_000 / cp0);
        emit log_named_uint("enforced floor / cp0 (bps)", enforced * 10_000 / cp0);
        // The 7-day decay is the stated bound on how far a sandwich may lower the floor. Allow 0.1% rounding.
        assertGe(enforced, documented * 999 / 1000, "floor fell below cp0 * 7d / (7d + elapsed)");
    }
}
