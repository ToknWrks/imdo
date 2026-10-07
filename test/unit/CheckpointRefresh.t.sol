// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

/// @notice Audit finding (medium): the post-buy checkpoint refresh used to copy the post-swap spot with no
/// bound relative to the floor the same call enforced. Downward, a sandwicher who pushed the price ~1% under
/// the floor each cooldown ratcheted it down geometrically (77% of market after 20 rounds, stakers paid ~38%
/// more per IMD). Upward, one dust buy at a pushed price pinned the floor above spot for 3.4 days.
/// `_refreshCheckpoint` now clamps the refresh to [floor, floor * (1 + MAX_CHECKPOINT_RISE_BPS)].
/// The first test is the judge's proof as delivered; the second is the upward case.
contract CheckpointRefreshTest is Test {
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
            sqrtP, TickMath.getSqrtPriceAtTick(-887200), TickMath.getSqrtPriceAtTick(887200), 200 ether, type(uint128).max
        );
        lpRouter.modifyLiquidity{value: 200 ether}(
            imdKey, ModifyLiquidityParams(-887200, 887200, int256(uint256(liquidity)), 0), ""
        );
        imdo = new IMDOToken();
        staking = new ImdoStaking(
            address(imdo), address(imd), address(manager), makeAddr("claim"), makeAddr("regenSafe")
        );
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

    function test_checkpointRatchetsDownUnderSandwichedBuys() public {
        _fund(1 ether);
        treasury.process(); // honest buy: checkpoint == market
        uint160 market = _spot();
        uint256 firstOut;
        uint256 lastOut;
        for (uint256 r; r < 20; ++r) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _fund(1 ether);
            ImdoTreasury.Leg memory l = treasury.leg(0);
            uint256 floor =
                FullMath.mulDiv(l.checkpointSqrtPriceX96, 7 days, 7 days + vm.getBlockTimestamp() - l.checkpointAt);
            // front-run: buy IMD until the sqrt-price sits 0.9% under the floor the treasury will enforce
            uint160 target = uint160(floor * 991 / 1000);
            if (target < _spot()) _limitSwap(true, target, 5000 ether);
            uint256 before = imd.balanceOf(address(staking));
            treasury.process();
            assertEq(treasury.leg(0).pending, 0, "treasury buy must still fill");
            uint256 out = imd.balanceOf(address(staking)) - before;
            if (r == 2) firstOut = out;
            lastOut = out;
            // back-run: sell IMD until the pool is back at the market price
            _limitSwap(false, market, 0);
        }
        uint160 cp = treasury.leg(0).checkpointSqrtPriceX96;
        emit log_named_uint("checkpoint / market (bps)", uint256(cp) * 10_000 / market);
        emit log_named_uint("IMD bought in round 2", firstOut);
        emit log_named_uint("IMD bought in round 19", lastOut);
        // 20 cooldowns are 12,000 s; the 7-day decay alone allows at most ~2% of relaxation.
        assertGe(uint256(cp), uint256(market) * 95 / 100, "checkpoint fell far below what the decay allows");
    }

    function test_inflatedDustBuyCannotPinFloorAboveSpotForDays() public {
        _fund(1 ether);
        treasury.process(); // honest buy: checkpoint == market
        uint160 market = _spot();
        // attacker sells IMD until the sqrt-price is 1.5x market, then has the treasury buy 1 gwei there
        uint160 pushed = uint160(uint256(market) * 3 / 2);
        _limitSwap(false, pushed, 0);
        _fund(3 gwei);
        vm.warp(vm.getBlockTimestamp() + 600);
        treasury.process();
        assertEq(treasury.leg(0).pending, 0, "dust buy fills at the pushed price");
        uint160 cp = treasury.leg(0).checkpointSqrtPriceX96;
        uint256 ceiling = uint256(market) * (10_000 + treasury.MAX_CHECKPOINT_RISE_BPS()) / 10_000;
        assertLe(uint256(cp), ceiling, "checkpoint rose more than one bounded step above the enforced floor");
        // attacker buys back to market
        _limitSwap(true, market, 5000 ether);
        // the IMD leg must be live again within the hour, not after 3.4 days of failed calls
        uint256 failed;
        bool bought;
        for (uint256 i; i < 6 && !bought; ++i) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _fund(0.01 ether);
            uint256 before = imd.balanceOf(address(staking));
            treasury.process();
            if (imd.balanceOf(address(staking)) > before) bought = true;
            else ++failed;
        }
        emit log_named_uint("failed process() calls before recovery", failed);
        assertTrue(bought, "IMD leg stalled for more than an hour after one inflated dust buy");
    }
}
