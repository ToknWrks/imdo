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

import {LaunchToken} from "../../src/LaunchToken.sol";
import {AdamDistributor} from "../../src/AdamDistributor.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";
import {AdamHook} from "../../src/AdamHook.sol";
import {DeployAdam} from "../../script/DeployAdam.s.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";
import {MockTaxHook} from "./MockTaxHook.sol";

/// @notice Local Uniswap v4 environment: a real PoolManager, mock IMD / PNKSTR with ETH pools (the PNKSTR pool
/// carries a taxing hook like mainnet), and the ADAM system deployed through the real deploy script.
/// @custom:x https://x.com/IaMaDamIMD
abstract contract LocalV4 is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint16 internal constant PNKSTR_TAX_BPS = 1000;
    uint256 internal constant MAX_ETH_PER_BUY = 1 ether;
    uint16 internal constant SLIPPAGE_BPS = 300;
    uint32 internal constant COOLDOWN = 10 minutes;

    PoolManager internal poolManager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    MockERC20 internal imd;
    MockERC20 internal pnkstr;
    MockTaxHook internal pnkstrHook;
    PoolKey internal imdKey;
    PoolKey internal pnkstrKey;

    DeployAdam internal deployScript;
    DeployAdam.Config internal cfg;
    LaunchToken internal adam;
    AdamDistributor internal distributor;
    AdamTreasury internal treasury;
    AdamHook internal hook;
    PoolKey internal adamKey;

    address internal hookOwner = makeAddr("hookOwner");
    address internal teamWallet = makeAddr("teamWallet");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        poolManager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(poolManager);
        lpRouter = new PoolModifyLiquidityTest(poolManager);

        _deployRewardPools();
        _deployAdamSystem();
        _launchAdamPool();
    }

    // ---------------------------------------------------------------------------------------------
    // Environment
    // ---------------------------------------------------------------------------------------------

    function _deployRewardPools() internal {
        // Deterministic, sorted-above-ETH token addresses are guaranteed because ETH is address(0).
        imd = new MockERC20("Identity.md", "IMD", 18);
        pnkstr = new MockERC20("PunkStrategy", "PNKSTR", 18);
        imd.mint(address(this), 1e36);
        pnkstr.mint(address(this), 1e36);
        imd.approve(address(lpRouter), type(uint256).max);
        pnkstr.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(0x40 | 0x4),
            type(MockTaxHook).creationCode,
            abi.encode(address(poolManager), uint256(PNKSTR_TAX_BPS))
        );
        pnkstrHook = new MockTaxHook{salt: salt}(poolManager, PNKSTR_TAX_BPS);
        assertEq(address(pnkstrHook), expected, "tax hook address");

        imdKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        pnkstrKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(pnkstr)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(pnkstrHook))
        });

        // ~223 IMD per ETH and ~170k PNKSTR per ETH, roughly the mainnet prices on 2026-10-05.
        _initAndSeed(imdKey, 54_000, -887_200, 887_200, 200 ether);
        _initAndSeed(pnkstrKey, 120_420, -887_220, 887_220, 200 ether);
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

    function _deployAdamSystem() internal virtual {
        deployScript = new DeployAdam();
        cfg = deployScript.mainnetConfig(address(this), teamWallet, hookOwner, address(0));
        cfg.poolManager = address(poolManager);
        cfg.positionManager = address(0);
        cfg.permit2 = address(0);
        cfg.create2Deployer = address(deployScript);
        cfg.imd = address(imd);
        cfg.pnkstr = address(pnkstr);
        cfg.pnkstrHooks = address(pnkstrHook);
        cfg.pnkstrTaxBps = PNKSTR_TAX_BPS;
        cfg.maxEthPerBuy = MAX_ETH_PER_BUY;
        cfg.slippageBps = SLIPPAGE_BPS;
        cfg.cooldown = COOLDOWN;

        DeployAdam.Deployment memory d = deployScript.deployContracts(cfg);
        adam = d.token;
        distributor = d.distributor;
        treasury = d.treasury;
        hook = d.hook;
        adamKey = d.key;
    }

    /// @dev Pool initialization is owner-only; the single-sided ADAM position mirrors the deploy script's.
    function _launchAdamPool() internal {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(cfg.initialTick);
        vm.prank(hookOwner);
        poolManager.initialize(adamKey, sqrtP);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(cfg.lowerTick), sqrtP, cfg.liquidityAdam
        );
        adam.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            adamKey,
            ModifyLiquidityParams({
                tickLower: cfg.lowerTick,
                tickUpper: cfg.initialTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
        adam.approve(address(swapRouter), type(uint256).max);
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
        return _swap(adamKey, true, -int256(ethIn), ethIn);
    }

    function buyExactOut(uint256 adamOut, uint256 maxEth) internal returns (BalanceDelta) {
        return _swap(adamKey, true, int256(adamOut), maxEth);
    }

    function sellExactIn(uint256 adamIn) internal returns (BalanceDelta) {
        return _swap(adamKey, false, -int256(adamIn), 0);
    }

    function sellExactOut(uint256 ethOut) internal returns (BalanceDelta) {
        return _swap(adamKey, false, int256(ethOut), 0);
    }

    function warpPastDecay() internal {
        if (hook.launchTimestamp() == 0) buyExactIn(1); // starts trading without a rounded ETH fee
        vm.warp(uint256(hook.launchTimestamp()) + hook.DECAY_DURATION());
    }

    function adamPoolTick() internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(poolManager)).getSlot0(adamKey.toId());
    }
}
