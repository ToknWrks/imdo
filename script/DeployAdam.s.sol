// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LaunchToken} from "../src/LaunchToken.sol";
import {AdamDistributor} from "../src/AdamDistributor.sol";
import {AdamTreasury} from "../src/AdamTreasury.sol";
import {AdamHook} from "../src/AdamHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @title DeployAdam
/// @notice Legacy deployment helpers and manual hook-only integration with an existing ADAM Treasury.
/// @dev The continuation entry point for new application contracts is DeployAdamExtension.run(Config).
/// This run() requires existing ADAM and Treasury addresses and never mints a token. It mines the
/// accepted hook, initializes a separate fee-bearing PoolKey, and seeds the owner's chosen liquidity.
/// deployContracts/launchPool remain available for the accepted local/fork regression fixtures;
/// their zero-token branch creates only a simulation fixture and is not used by either run() entry point.
/// @custom:x https://x.com/IaMaDamIMD
contract DeployAdam is Script {
    using CurrencyLibrary for Currency;

    // ---- Ethereum mainnet addresses (verified with `cast code` / `symbol()` on 2026-10-05) ----
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant PNKSTR = 0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF;
    address public constant PNKSTR_HOOK = 0xfAaad5B731F52cDc9746F2414c823eca9B06E844;

    // ETH/IMD pool with the live liquidity (poolId 0xb07d640f...fb3): fee 1%, tick spacing 200, no hook.
    uint24 public constant IMD_POOL_FEE = 10_000;
    uint24 public constant IMD_POOL_TICK_SPACING = 200;
    // ETH/PNKSTR pool as given by the brief. Hook buy tax measured on a mainnet fork: 10.00% of output.
    uint24 public constant PNKSTR_POOL_FEE = 0;
    uint24 public constant PNKSTR_POOL_TICK_SPACING = 60;
    uint16 public constant PNKSTR_BUY_TAX_BPS = 1000;

    // Treasury limits.
    uint256 public constant MAX_ETH_PER_BUY = 1 ether;
    uint16 public constant SLIPPAGE_BPS = 300;
    uint32 public constant COOLDOWN = 10 minutes;

    // ETH/ADAM pool: LP fee 0 (all fees flow through the hook), tick spacing 60.
    uint24 public constant ADAM_POOL_FEE = 0;
    int24 public constant ADAM_POOL_TICK_SPACING = 60;
    // Opening price 1.0001^177240 = 49.8M ADAM per ETH (1B supply = 20.1 ETH). Position covers prices up to
    // 1.0001^108180 = 50k ADAM per ETH (1000x). Both ticks are multiples of 60.
    int24 public constant INITIAL_TICK = 177_240;
    int24 public constant LOWER_TICK = 108_180;
    uint256 public constant LIQUIDITY_ADAM = 1_000_000_000e18;

    struct Config {
        address deployer;
        address teamWallet;
        address hookOwner;
        address adamToken; // address(0) => deploy LaunchToken (ignored when `treasury` is set)
        address treasury; // address(0) => deploy Distributor + Treasury; else hook-only against this Treasury
        address poolManager;
        address positionManager;
        address permit2;
        address create2Deployer;
        address imd;
        uint24 imdFee;
        uint24 imdTickSpacing;
        address imdHooks;
        uint16 imdTaxBps;
        address pnkstr;
        uint24 pnkstrFee;
        uint24 pnkstrTickSpacing;
        address pnkstrHooks;
        uint16 pnkstrTaxBps;
        uint256 maxEthPerBuy;
        uint16 slippageBps;
        uint32 cooldown;
        uint24 poolFee;
        int24 tickSpacing;
        int24 initialTick;
        int24 lowerTick;
        uint256 liquidityAdam;
    }

    struct Deployment {
        LaunchToken token;
        AdamDistributor distributor;
        AdamTreasury treasury;
        AdamHook hook;
        bytes32 hookSalt;
        PoolKey key;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    error HookAddressMismatch(address expected, address actual);
    error DeployerMustOwnHookAtLaunch();
    error TickNotAligned();
    error PipelineTokenMismatch(address configured, address pipeline);
    error PipelineRewardMismatch(uint8 leg, address configured, address pipeline);
    error InsufficientAdamForLiquidity(uint256 held, uint256 required);

    function mainnetConfig(address deployer, address teamWallet, address hookOwner, address adamToken)
        public
        pure
        returns (Config memory cfg)
    {
        cfg.deployer = deployer;
        cfg.teamWallet = teamWallet;
        cfg.hookOwner = hookOwner;
        cfg.adamToken = adamToken;
        cfg.treasury = address(0);
        cfg.poolManager = POOL_MANAGER;
        cfg.positionManager = POSITION_MANAGER;
        cfg.permit2 = PERMIT2;
        cfg.create2Deployer = CREATE2_DEPLOYER;
        cfg.imd = IMD;
        cfg.imdFee = IMD_POOL_FEE;
        cfg.imdTickSpacing = IMD_POOL_TICK_SPACING;
        cfg.imdHooks = address(0);
        cfg.imdTaxBps = 0;
        cfg.pnkstr = PNKSTR;
        cfg.pnkstrFee = PNKSTR_POOL_FEE;
        cfg.pnkstrTickSpacing = PNKSTR_POOL_TICK_SPACING;
        cfg.pnkstrHooks = PNKSTR_HOOK;
        cfg.pnkstrTaxBps = PNKSTR_BUY_TAX_BPS;
        cfg.maxEthPerBuy = MAX_ETH_PER_BUY;
        cfg.slippageBps = SLIPPAGE_BPS;
        cfg.cooldown = COOLDOWN;
        cfg.poolFee = ADAM_POOL_FEE;
        cfg.tickSpacing = ADAM_POOL_TICK_SPACING;
        cfg.initialTick = INITIAL_TICK;
        cfg.lowerTick = LOWER_TICK;
        cfg.liquidityAdam = LIQUIDITY_ADAM;
    }

    /// @notice Manual hook-only entry point. Required: DEPLOYER, TEAM_WALLET, ADAM_TOKEN, TREASURY.
    /// @dev LIQUIDITY_ADAM is the owner's available allocation after funding NFTClaim; choose explicitly.
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address teamWallet = vm.envAddress("TEAM_WALLET");
        address adamToken = vm.envAddress("ADAM_TOKEN");
        require(adamToken != address(0), "Reuse existing ADAM; no new token");
        Config memory cfg = mainnetConfig(deployer, teamWallet, deployer, adamToken);
        cfg.treasury = vm.envAddress("TREASURY");
        require(cfg.treasury != address(0), "DeployAdamExtension deploys the application");
        cfg.liquidityAdam = vm.envOr("LIQUIDITY_ADAM", LIQUIDITY_ADAM);

        vm.startBroadcast();
        Deployment memory d = deployContracts(cfg);
        (d.sqrtPriceX96, d.liquidity) = launchPool(cfg, d);
        vm.stopBroadcast();

        console2.log("ADAM token        ", address(d.token));
        console2.log("AdamDistributor   ", address(d.distributor));
        console2.log("AdamTreasury      ", address(d.treasury));
        console2.log("AdamHook          ", address(d.hook));
        console2.log("hook salt         ", uint256(d.hookSalt));
        console2.log("pool sqrtPriceX96 ", d.sqrtPriceX96);
        console2.log("position liquidity", d.liquidity);
    }

    /// @notice Steps 1-4, or hook-only (step 4) when `cfg.treasury` names an existing AdamTreasury. Works both
    /// under `vm.startBroadcast` (CREATE2 through the deterministic deployer) and when called from a test
    /// (CREATE2 from this contract) as long as `cfg.create2Deployer` matches.
    function deployContracts(Config memory cfg) public returns (Deployment memory d) {
        if (cfg.treasury != address(0)) {
            (d.token, d.distributor, d.treasury) = resolvePipeline(cfg);
        } else {
            if (cfg.adamToken == address(0)) {
                d.token = new LaunchToken();
                // In a test the token mints to this contract; under broadcast it mints to the deployer directly.
                uint256 held = d.token.balanceOf(address(this));
                if (held != 0 && cfg.deployer != address(this)) d.token.transfer(cfg.deployer, held);
            } else {
                d.token = LaunchToken(cfg.adamToken);
            }

            d.distributor = new AdamDistributor(address(d.token), cfg.imd, cfg.pnkstr, cfg.poolManager, address(0));

            d.treasury = new AdamTreasury(
                address(d.distributor),
                cfg.teamWallet,
                cfg.poolManager,
                cfg.imd,
                cfg.imdFee,
                cfg.imdTickSpacing,
                cfg.imdHooks,
                cfg.imdTaxBps,
                cfg.pnkstr,
                cfg.pnkstrFee,
                cfg.pnkstrTickSpacing,
                cfg.pnkstrHooks,
                cfg.pnkstrTaxBps,
                cfg.maxEthPerBuy,
                cfg.slippageBps,
                cfg.cooldown
            );
        }

        bytes memory ctorArgs = abi.encode(cfg.poolManager, address(d.token), address(d.treasury), cfg.hookOwner);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(cfg.create2Deployer, hookFlags(), type(AdamHook).creationCode, ctorArgs);
        d.hook = new AdamHook{salt: salt}(
            IPoolManager(cfg.poolManager), address(d.token), address(d.treasury), cfg.hookOwner
        );
        if (address(d.hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(d.hook));
        d.hookSalt = salt;

        d.key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(d.token)),
            fee: cfg.poolFee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(address(d.hook))
        });
    }

    /// @notice Hook-only mode: read the ADAM token and the AdamDistributor from an existing AdamTreasury and
    /// check that it was built for the configured reward tokens. Nothing is deployed here.
    function resolvePipeline(Config memory cfg)
        public
        view
        returns (LaunchToken token, AdamDistributor distributor, AdamTreasury treasury)
    {
        treasury = AdamTreasury(payable(cfg.treasury));
        distributor = AdamDistributor(address(treasury.distributor()));
        token = LaunchToken(address(distributor.adam()));
        if (cfg.adamToken != address(0) && cfg.adamToken != address(token)) {
            revert PipelineTokenMismatch(cfg.adamToken, address(token));
        }
        address legImd = Currency.unwrap(treasury.leg(0).key.currency1);
        address legPnkstr = Currency.unwrap(treasury.leg(1).key.currency1);
        if (legImd != cfg.imd) revert PipelineRewardMismatch(0, cfg.imd, legImd);
        if (legPnkstr != cfg.pnkstr) revert PipelineRewardMismatch(1, cfg.pnkstr, legPnkstr);
    }

    /// @notice Steps 5-6. Must be called by the hook owner holding `cfg.liquidityAdam` ADAM.
    function launchPool(Config memory cfg, Deployment memory d)
        public
        returns (uint160 sqrtPriceX96, uint128 liquidity)
    {
        if (cfg.hookOwner != cfg.deployer) {
            revert DeployerMustOwnHookAtLaunch();
        }
        if (cfg.initialTick % cfg.tickSpacing != 0 || cfg.lowerTick % cfg.tickSpacing != 0) revert TickNotAligned();
        if (cfg.lowerTick >= cfg.initialTick) revert TickNotAligned();
        uint256 held = d.token.balanceOf(cfg.deployer);
        if (held < cfg.liquidityAdam) revert InsufficientAdamForLiquidity(held, cfg.liquidityAdam);

        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(cfg.initialTick);
        IPoolManager(cfg.poolManager).initialize(d.key, sqrtPriceX96);

        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(cfg.lowerTick), sqrtPriceX96, cfg.liquidityAdam
        );

        IERC20(address(d.token)).approve(cfg.permit2, cfg.liquidityAdam);
        IAllowanceTransfer(cfg.permit2)
            .approve(
                address(d.token), cfg.positionManager, uint160(cfg.liquidityAdam), uint48(block.timestamp + 1 hours)
            );

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            d.key,
            cfg.lowerTick,
            cfg.initialTick,
            uint256(liquidity),
            uint128(0),
            uint128(cfg.liquidityAdam),
            cfg.deployer,
            ""
        );
        params[1] = abi.encode(d.key.currency0, d.key.currency1);
        IPositionManager(cfg.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function hookFlags() public pure returns (uint160) {
        return uint160(
            0x2000 /* BEFORE_INITIALIZE */ | 0x80 /* BEFORE_SWAP */ | 0x40 /* AFTER_SWAP */
                | 0x8 /* BEFORE_SWAP_RETURNS_DELTA */ | 0x4 /* AFTER_SWAP_RETURNS_DELTA */
        );
    }
}
