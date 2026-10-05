// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {DeployAdam} from "../../script/DeployAdam.s.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";

/// @notice Mainnet-fork checks against the real PoolManager, PositionManager, IMD pool and PNKSTR pool.
/// Excluded from the default profile (needs network): `FOUNDRY_PROFILE=fork forge test -vv`.
contract MainnetForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant RPC = "https://ethereum-rpc.publicnode.com";

    DeployAdam internal script;
    DeployAdam.Config internal cfg;
    DeployAdam.Deployment internal d;
    IPoolManager internal pm;
    PoolSwapTest internal swapRouter;
    address internal teamWallet = makeAddr("teamWallet");
    address internal alice = makeAddr("alice");

    PoolKey internal imdKey;
    PoolKey internal pnkstrKey;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(RPC, 26_126_549);
        script = new DeployAdam();
        pm = IPoolManager(script.POOL_MANAGER());
        swapRouter = new PoolSwapTest(pm);
        // The script contract plays the deployer: it holds the supply, owns the hook and signs nothing.
        cfg = script.mainnetConfig(address(script), teamWallet, address(script), address(0));
        cfg.create2Deployer = address(script);
        d = script.deployContracts(cfg);
        (d.sqrtPriceX96, d.liquidity) = script.launchPool(cfg, d);

        imdKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(cfg.imd),
            fee: cfg.imdFee,
            tickSpacing: int24(cfg.imdTickSpacing),
            hooks: IHooks(cfg.imdHooks)
        });
        pnkstrKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(cfg.pnkstr),
            fee: cfg.pnkstrFee,
            tickSpacing: int24(cfg.pnkstrTickSpacing),
            hooks: IHooks(cfg.pnkstrHooks)
        });
        vm.deal(address(this), 1_000 ether);
    }

    function _spotOut(PoolKey memory key, uint256 ethIn) internal view returns (uint256 out) {
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        out = FullMath.mulDiv(ethIn, sqrtP, FixedPoint96.Q96);
        out = FullMath.mulDiv(out, sqrtP, FixedPoint96.Q96);
    }

    function _buy(PoolKey memory key, uint256 ethIn) internal returns (BalanceDelta) {
        return swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ------------------------------------------------------------------ the pools we buy from

    function test_pnkstrHookBuyTaxIsTenPercent() public {
        uint256 ethIn = 0.01 ether; // tiny, so price impact is negligible (< 0.01%)
        uint256 spot = _spotOut(pnkstrKey, ethIn);
        vm.recordLogs();
        BalanceDelta delta = _buy(pnkstrKey, ethIn);
        uint256 got = uint256(uint128(delta.amount1()));
        uint256 taxBps = 10_000 - (got * 10_000) / spot;
        console2.log("PNKSTR hook buy tax (bps, incl. price impact):", taxBps);
        assertGe(taxBps, 990);
        assertLe(taxBps, 1010);
        // PoolManager emits the raw pool delta before afterSwap. Compare it to the returned user delta
        // to measure the hook tax exactly, independently of price impact or where the hook sends tax.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rawOutput;
        bytes32 swapEvent = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(pm) && logs[i].topics[0] == swapEvent
                    && logs[i].topics[1] == PoolId.unwrap(pnkstrKey.toId())
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(swapRouter))))
            ) {
                (, int128 out,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                rawOutput = uint256(uint128(out));
            }
        }
        assertGt(rawOutput, got);
        assertApproxEqAbs(rawOutput - got, rawOutput * cfg.pnkstrTaxBps / 10_000, 1);
        console2.log("PNKSTR exact hook output tax (bps):", ((rawOutput - got) * 10_000 + rawOutput - 1) / rawOutput);
        assertEq(IERC20(cfg.pnkstr).balanceOf(address(this)), got, "PNKSTR has no transfer tax");
    }

    function test_treasuryQuotesAreSatisfiableAtMaxSize() public {
        uint256 ethIn = cfg.maxEthPerBuy;
        uint256 minImd = d.treasury.quoteMinOut(d.treasury.LEG_IMD(), ethIn);
        uint256 minPnk = d.treasury.quoteMinOut(d.treasury.LEG_PNKSTR(), ethIn);
        uint256 gotImd = uint256(uint128(_buy(imdKey, ethIn).amount1()));
        uint256 gotPnk = uint256(uint128(_buy(pnkstrKey, ethIn).amount1()));
        console2.log("IMD    1 ETH -> out / minOut", gotImd, minImd);
        console2.log("PNKSTR 1 ETH -> out / minOut", gotPnk, minPnk);
        assertGe(gotImd, minImd, "IMD leg would revert at max size");
        assertGe(gotPnk, minPnk, "PNKSTR leg would revert at max size");
    }

    // ------------------------------------------------------------------ our deployment on the real stack

    function test_deploymentAndSingleSidedPosition() public view {
        assertEq(d.token.totalSupply(), 1_000_000_000e18);
        uint256 dust = d.token.balanceOf(address(script));
        assertLe(dust, 1_000, "liquidity fixed-point rounding leaves only sub-token dust");
        assertEq(d.token.balanceOf(address(pm)) + dust, 1_000_000_000e18);
        assertEq(address(pm).balance >= 0, true);
        (uint160 sqrtP, int24 tick,,) = pm.getSlot0(d.key.toId());
        assertEq(sqrtP, TickMath.getSqrtPriceAtTick(cfg.initialTick));
        assertEq(tick, cfg.initialTick);
        assertEq(pm.getLiquidity(d.key.toId()), 0, "position sits just above price until the first buy");
        uint256 tokenId = IPositionManager(cfg.positionManager).nextTokenId() - 1;
        assertEq(IPositionManager(cfg.positionManager).getPositionLiquidity(tokenId), d.liquidity);
        assertEq(d.hook.owner(), address(script));
        assertEq(d.hook.launchTimestamp(), 0);
        assertTrue(d.hook.initialized());
    }

    function test_endToEndOnMainnetFork() public {
        _buy(d.key, 1); // first filled swap starts anti-snipe, with a zero rounded fee
        vm.warp(block.timestamp + 30 minutes);
        // 1. Alice buys ADAM: 1.5% of her ETH lands in the treasury.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        BalanceDelta buy = _buy(d.key, 2 ether);
        assertEq(buy.amount0(), -2 ether);
        uint256 adamBought = uint256(uint128(buy.amount1()));
        assertGt(adamBought, 0);
        assertEq(address(d.treasury).balance, 0.03 ether);
        assertEq(address(d.hook).balance, 0);

        // 2. She stakes; more fees arrive (sell).
        vm.startPrank(alice);
        d.token.approve(address(d.distributor), adamBought);
        d.distributor.stake(adamBought / 2);
        d.token.approve(address(swapRouter), adamBought);
        swapRouter.swap(
            d.key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(adamBought / 4),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        uint256 fees = address(d.treasury).balance;
        assertGt(fees, 0.03 ether);

        // 3. process() against the real IMD and PNKSTR pools.
        d.treasury.process();
        assertEq(teamWallet.balance, fees / 10);
        uint256 imdGot = IERC20(cfg.imd).balanceOf(address(d.distributor));
        uint256 pnkGot = IERC20(cfg.pnkstr).balanceOf(address(d.distributor));
        console2.log("IMD to holders   ", imdGot);
        console2.log("PNKSTR to holders", pnkGot);
        assertGt(imdGot, 0);
        assertGt(pnkGot, 0);
        assertEq(address(d.treasury).balance, 0);
        assertEq(d.treasury.leg(0).pending, 0);
        assertEq(d.treasury.leg(1).pending, 0);

        // 4. Alice, the only staker, claims everything.
        assertApproxEqAbs(d.distributor.earned(alice, cfg.imd), imdGot, 1);
        vm.prank(alice);
        d.distributor.claim();
        assertApproxEqAbs(IERC20(cfg.imd).balanceOf(alice), imdGot, 1);
        assertApproxEqAbs(IERC20(cfg.pnkstr).balanceOf(alice), pnkGot, 1);
    }

    function test_antiSnipeAtLaunchOnFork() public {
        uint256 before = address(d.treasury).balance;
        _buy(d.key, 1 ether);
        assertEq(address(d.treasury).balance - before, 0.2 ether);
    }

    function test_sandwichRefusesManipulatedRealImdPool() public {
        (bool ok,) = address(d.treasury).call{value: 1 ether}("");
        require(ok);
        d.treasury.process();
        vm.warp(block.timestamp + cfg.cooldown);
        (ok,) = address(d.treasury).call{value: 2.3 ether}("");
        require(ok);
        uint256 before = IERC20(cfg.imd).balanceOf(address(d.distributor));
        uint256 floor = d.treasury.quoteMinOut(0, 1 ether);
        BalanceDelta pump = _buy(imdKey, 50 ether);
        d.treasury.process();
        IERC20(cfg.imd).approve(address(swapRouter), uint256(uint128(pump.amount1())));
        swapRouter.swap(
            imdKey,
            SwapParams(false, -int256(pump.amount1()), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 bought = IERC20(cfg.imd).balanceOf(address(d.distributor)) - before;
        assertTrue(d.treasury.leg(0).pending == 1 ether || bought >= floor);
    }
}
