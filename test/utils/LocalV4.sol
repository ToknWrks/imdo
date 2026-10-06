// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IMDOToken} from "../../src/IMDOToken.sol";
import {ImdoStaking} from "../../src/ImdoStaking.sol";
import {ImdoTreasury} from "../../src/ImdoTreasury.sol";
import {ImdoHook} from "../../src/ImdoHook.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";

abstract contract LocalV4 is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    uint256 internal constant MAX_ETH_PER_BUY = 1 ether;
    uint16 internal constant SLIPPAGE_BPS = 300;
    uint32 internal constant COOLDOWN = 600;
    PoolManager internal poolManager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    MockERC20 internal imd;
    PoolKey internal imdKey;
    IMDOToken internal imdo;
    ImdoStaking internal distributor;
    ImdoTreasury internal treasury;
    ImdoHook internal hook;
    PoolKey internal imdoKey;
    address internal hookOwner = makeAddr("hookOwner");
    address internal opsWallet = makeAddr("opsWallet");
    address internal offsetsSafe = makeAddr("offsetsSafe");
    address internal regenSafe = makeAddr("regenSafe");
    address internal claimAddress = makeAddr("claimAddress");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        poolManager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(poolManager);
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        vm.deal(address(this), 10_000 ether);
        imd = new MockERC20("Identity.md", "IMD", 18);
        imd.mint(address(this), 1e36);
        imd.approve(address(lpRouter), type(uint256).max);
        imdKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(imd)), 10000, 200, IHooks(address(0)));
        _initAndSeed(imdKey, 54000, -887200, 887200, 200 ether);
        imdo = new IMDOToken();
        distributor = new ImdoStaking(address(imdo), address(imd), address(poolManager), claimAddress, regenSafe);
        treasury = _newTreasury(address(distributor), address(poolManager));
        bytes memory args = abi.encode(address(poolManager), address(imdo), address(treasury), hookOwner);
        (address expected, bytes32 salt) = HookMiner.find(address(this), 0x20cc, type(ImdoHook).creationCode, args);
        hook = new ImdoHook{salt: salt}(poolManager, address(imdo), address(treasury), hookOwner);
        assertEq(address(hook), expected);
        imdoKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(imdo)), 0, 60, IHooks(address(hook)));
        vm.prank(hookOwner);
        poolManager.initialize(imdoKey, TickMath.getSqrtPriceAtTick(177240));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(108180), TickMath.getSqrtPriceAtTick(177240), 890_000_000e18
        );
        imdo.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(imdoKey, ModifyLiquidityParams(108180, 177240, int256(uint256(liquidity)), 0), "");
        imdo.approve(address(swapRouter), type(uint256).max);
    }

    function _newTreasury(address staker, address manager) internal returns (ImdoTreasury) {
        return new ImdoTreasury(
            staker,
            opsWallet,
            offsetsSafe,
            regenSafe,
            manager,
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
    }

    function _initAndSeed(PoolKey memory key, int24 tick, int24 lower, int24 upper, uint256 ethAmount) internal {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        poolManager.initialize(key, sqrtP);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), ethAmount, type(uint128).max
        );
        lpRouter.modifyLiquidity{value: ethAmount}(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Swap helpers (test contract is the trader unless pranked by the caller)
    // ---------------------------------------------------------------------------------------------

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function buyExactIn(uint256 ethIn) internal returns (BalanceDelta) {
        return _swap(imdoKey, true, -int256(ethIn), ethIn);
    }

    function buyExactOut(uint256 imdoOut, uint256 maxEth) internal returns (BalanceDelta) {
        return _swap(imdoKey, true, int256(imdoOut), maxEth);
    }

    function sellExactIn(uint256 imdoIn) internal returns (BalanceDelta) {
        return _swap(imdoKey, false, -int256(imdoIn), 0);
    }

    function sellExactOut(uint256 ethOut) internal returns (BalanceDelta) {
        return _swap(imdoKey, false, int256(ethOut), 0);
    }

    function warpPastDecay() internal {
        if (hook.launchTimestamp() == 0) buyExactIn(1); // starts trading without a rounded ETH fee
        vm.warp(uint256(hook.launchTimestamp()) + hook.DECAY_DURATION());
    }

    function imdoPoolTick() internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(poolManager)).getSlot0(imdoKey.toId());
    }
}
