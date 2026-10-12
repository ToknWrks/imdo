// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegenRegistry} from "../../src/regen/RegenRegistry.sol";
import {RegenRouter} from "../../src/regen/RegenRouter.sol";
import {RegenReceiverFactory, RegenReceiver} from "../../src/regen/RegenReceiver.sol";
import {UniswapV3Venue, ISwapRouter02} from "../../src/regen/UniswapV3Venue.sol";
import {IKlimaRetirementAggregator} from "../../src/regen/interfaces/IKlimaRetirementAggregator.sol";
import {IEthToTokenSwap, IPriceFeed} from "../../src/regen/interfaces/IEthToTokenSwap.sol";
import {IAerodromePool} from "../../src/regen/interfaces/IAerodromePool.sol";

/// @dev The pool's swap and sync surface, for the attacker.
interface IAerodromePoolSwap {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
}

/// @notice Base mainnet fork. Real Klima aggregator, real Uniswap V3 USDC/WETH, real Chainlink, real Aerodrome
///         USDC/kVCM pool. Explicit fork profile; `BASE_RPC_URL` overrides the public RPC. Most tests pin block
///         52,335,751; the honest-batch test pins a block where the spot sits inside the 24-hour bar (at the first
///         block it is 9% under the day's average, which is exactly a skip).
contract RegenRouterBaseForkTest is Test {
    address constant AGG = 0xdA0A793D7C32AB80bcdab7F8c725c96DB22464f4;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant KVCM = 0x00fBAC94Fec8D4089d3fe979F39454F48c71A65d;
    address constant KVCM_POOL = 0x5C0D76fab1822bDeb47308eD6028231761ED723E;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant VAULT = 0xf4699531e0a5F6e9351a36De3753Deaad329Bf45;
    address constant C004 = 0xE6628083Ab9A9Ab235e80f63e7ecd810B54A71B8;
    address constant C003 = 0x3D1bf942619cB9FC71543721Ef3D5496FAf283B8;
    address constant C006 = 0xb77A0be47A686c525a38fbb10c0D424929471d7D;
    string constant REGEN = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan";
    uint256 constant PINNED = 52_335_751;
    uint256 constant CALM = 52_487_479; // spot 2.7% under the 24h average

    RegenRegistry reg;
    RegenRouter router;
    address beneficiary = 0x6bbAC4329dcD4C1075A462Db6342Ac0Ce0C78099;
    address keeper = makeAddr("keeper");
    address pot = 0x55bEb053c003F98c1059F2a497132CBA72104a03;

    function setUp() public {
        _fork(PINNED);
    }

    function _fork(uint256 blockNumber) internal {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), blockNumber);
        reg = new RegenRegistry("IMDO", REGEN, beneficiary);
        router = new RegenRouter(
            RegenRouter.Config({
                registry: reg,
                aggregator: IKlimaRetirementAggregator(AGG),
                usdc: IERC20(USDC),
                kvcm: IERC20(KVCM),
                kvcmPool: IAerodromePool(KVCM_POOL),
                classVault: VAULT,
                creditA: C004,
                creditB: C003,
                creditC: C006,
                venue: IEthToTokenSwap(address(new UniswapV3Venue(ISwapRouter02(SWAP_ROUTER02), WETH, USDC, 500))),
                ethUsd: IPriceFeed(FEED),
                sequencerUptime: IPriceFeed(SEQUENCER),
                maxFeedAge: 86_400,
                minBatch: 0.001 ether,
                maxBatch: 0.05 ether,
                bountyBps: 100,
                minOutBps: 9700,
                twapGranularity: 48,
                minTonnesBps: 9500,
                maxUsdcPerTonne: 45e6,
                processInterval: 7200
            })
        );
        vm.deal(pot, 1 ether);
    }

    function test_realRetirementEndToEnd() public {
        _fork(CALM);
        vm.prank(pot);
        router.deposit{value: 0.01 ether}(1);

        vm.recordLogs();
        vm.prank(keeper);
        router.process(1, pot);

        emit log_named_uint("tonnes (1e18)", router.retiredOf(1));
        emit log_named_uint("usdc dust", IERC20(USDC).balanceOf(address(router)));
        assertGt(router.retiredOf(1), 0);
        assertEq(router.retiredOf(1) % 1e12, 0);
        assertEq(keeper.balance, 0.0001 ether);
        assertEq(address(router).balance, 0);
        assertEq(router.usdcOf(1, pot), IERC20(USDC).balanceOf(address(router)));
        assertLt(router.usdcOf(1, pot), 100); // sub-step rounding only
        assertEq(router.lastRetiredAt(1, pot), block.timestamp);

        // the aggregator's own event must carry our beneficiary, name and message byte for byte
        bytes32 topic0 = 0x6fc64daccb3e984a15ddc33e89be48bb68d451d2b125e3c84fe8aa218018ab9c;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == AGG && logs[i].topics[0] == topic0) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(router));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), beneficiary);
                (, string memory ent, string memory ben, string memory msg_,,,,,) =
                    abi.decode(logs[i].data, (uint8, string, string, string, address, uint256, uint256, uint8, uint256));
                assertEq(ent, "Regen Retirement Router");
                assertEq(ben, "IMDO");
                assertEq(
                    msg_,
                    string.concat(
                        "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:",
                        REGEN,
                        " | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03"
                    )
                );
                emit log_string(msg_);
            }
        }
        assertTrue(found, "no AggregatorRetired from the aggregator");
    }

    function test_aFullBatchRetiresAtLeastTheTimeWeightedBar() public {
        _fork(CALM);
        vm.prank(pot);
        router.deposit{value: 0.05 ether}(1);
        RegenRouter.Plan memory p = router.plan(125e6);
        assertEq(p.credit, C004);
        vm.prank(keeper);
        router.process(1, pot);
        uint256 ref = router.referenceKvcm(p.spend); // kVCM the spend buys at the day's average
        uint256 need = router.kvcmFor(C004, p.tonnes); // kVCM the aggregator needed at spot
        emit log_named_uint("retired (1e18)", router.retiredOf(1));
        emit log_named_uint("kVCM needed at spot (1e18)", need);
        emit log_named_uint("kVCM at the average (1e18)", ref);
        emit log_named_uint("usdc per tonne", p.spend * 1e18 / p.tonnes);
        assertGt(router.retiredOf(1), 0);
        assertGe(need, ref * 9500 / 10_000);
        assertLe(p.spend * 1e18 / p.tonnes, 45e6);
    }

    function test_aSpotFarUnderTheDaysAverageIsASkipNotALoss() public view {
        // at the pinned block the pool had moved 9% in the day: the honest batch waits for the average
        RegenRouter.Plan memory p = router.plan(125e6);
        assertEq(p.credit, address(0));
        assertEq(p.reason, bytes32("priceOff"));
    }

    function test_aPumpedKvcmPoolIsSkipped() public {
        vm.prank(pot);
        router.deposit{value: 0.05 ether}(1);
        address attacker = makeAddr("attacker");
        _pump(attacker, 8_000e6);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, pot, "priceOff");
        vm.prank(attacker);
        router.process(1, pot);
        assertEq(router.balanceOf(1, pot), 0.05 ether);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(router.retiredOf(1), 0);
    }

    /// @dev Round-2 high: a price held across the whole window, with the pool's observations written by free
    ///      `sync()` calls, becomes the average. The ceiling is what still refuses it.
    function test_aPumpHeldAcrossTheWholeWindowHitsTheCeiling() public {
        _fork(CALM);
        vm.prank(pot);
        router.deposit{value: 0.05 ether}(1);
        address attacker = makeAddr("attacker");
        _pump(attacker, 8_000e6); // about 2.3x the price: ~49 USDC per tonne
        uint256 t = block.timestamp;
        for (uint256 i; i < 50; ++i) {
            t += 1801; // vm.warp(block.timestamp + x) only takes once on a fork: drive the clock from a local
            vm.warp(t);
            IAerodromePoolSwap(KVCM_POOL).sync();
        }
        // the relative bar now follows the held price: what 125 USDC buys at spot clears 95% of the day's average
        (uint256 tonnes,,,,) =
            IKlimaRetirementAggregator(AGG).quoteRetireCreditForInputTokenInViaKlima(C004, 0, 125e6, USDC, VAULT, 0);
        tonnes = tonnes / 1e12 * 1e12;
        (, uint256 spend,,) = IKlimaRetirementAggregator(AGG).quoteRetireCreditViaKlima(C004, 0, tonnes, USDC, VAULT, 0);
        uint256 ref = router.referenceKvcm(spend);
        uint256 need = router.kvcmFor(C004, tonnes);
        emit log_named_uint("usdc per tonne after the hold", spend * 1e18 / tonnes);
        emit log_named_uint("tonnes offered (1e18)", tonnes);
        emit log_named_uint("kVCM needed at spot (1e18)", need);
        emit log_named_uint("kVCM at the held average (1e18)", ref);
        assertGe(need, ref * 9500 / 10_000, "the relative bar alone would have let it through");
        // ...and the ceiling is what refuses it; the feed is a day old by now, so the refusal is read off the plan
        assertGt(spend * 1e18 / tonnes, 45e6);
        RegenRouter.Plan memory p = router.plan(125e6);
        assertEq(p.credit, address(0));
        assertEq(p.reason, bytes32("priceOff"));
        assertEq(router.retiredOf(1), 0);
    }

    function test_oneBatchPerDepositorPerInterval() public {
        _fork(CALM);
        vm.prank(pot);
        router.deposit{value: 0.2 ether}(1);
        router.process(1, pot);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.TooSoon.selector, block.timestamp + 7200));
        router.process(1, pot);
    }

    function test_bridgedPathThroughAReceiver() public {
        _fork(CALM);
        RegenReceiverFactory f = new RegenReceiverFactory(router);
        address rcv = f.predict(1);
        vm.deal(rcv, 0.02 ether); // what the canonical bridge does
        f.deploy(1);
        RegenReceiver(payable(rcv)).forward();
        router.process(1, rcv);
        assertGt(router.retiredOf(1), 0);
    }

    function _pump(address attacker, uint256 usdcIn) internal {
        deal(USDC, attacker, usdcIn);
        vm.startPrank(attacker);
        IERC20(USDC).transfer(KVCM_POOL, usdcIn);
        uint256 out = IAerodromePoolSwap(KVCM_POOL).getAmountOut(usdcIn, USDC);
        IAerodromePoolSwap(KVCM_POOL).swap(out, 0, attacker, ""); // kVCM is token0
        vm.stopPrank();
        emit log_named_uint("kVCM bought (1e18)", out);
    }
}
