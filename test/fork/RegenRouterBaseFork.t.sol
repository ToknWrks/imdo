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

/// @dev The pool's swap surface, for the attacker.
interface IAerodromePoolSwap {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice Base mainnet fork. Real Klima aggregator, real Uniswap V3 USDC/WETH, real Chainlink, real Aerodrome
///         USDC/kVCM pool. Explicit fork profile; `BASE_RPC_URL` overrides the public RPC.
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

    RegenRegistry reg;
    RegenRouter router;
    address beneficiary = 0x6bbAC4329dcD4C1075A462Db6342Ac0Ce0C78099;
    address keeper = makeAddr("keeper");
    address pot = 0x55bEb053c003F98c1059F2a497132CBA72104a03;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), 52_335_751);
        reg = new RegenRegistry();
        reg.register("IMDO", REGEN, beneficiary);
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
                twapGranularity: 4,
                minTonnesBps: 9700
            })
        );
        vm.deal(pot, 1 ether);
    }

    function test_realRetirementEndToEnd() public {
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
        assertEq(router.usdcOf(1), IERC20(USDC).balanceOf(address(router)));
        assertLt(router.usdcOf(1), 100); // sub-step rounding only

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
        vm.prank(pot);
        router.deposit{value: 0.05 ether}(1);
        vm.prank(keeper);
        router.process(1, pot);
        uint256 spent = 125e6; // about what 0.0495 ETH bought at the fork block; the bar scales with the spend
        uint256 bar = router.referenceTonnes(C004, spent);
        emit log_named_uint("retired (1e18)", router.retiredOf(1));
        emit log_named_uint("bar for 125 USDC (1e18)", bar);
        assertGt(router.retiredOf(1), bar * 9700 / 10_000 * 9 / 10); // the real spend is near, not exactly, 125 USDC
    }

    function test_aPumpedKvcmPoolIsSkipped() public {
        vm.prank(pot);
        router.deposit{value: 0.05 ether}(1);

        // the keeper buys kVCM first, in the same transaction it would process in
        address attacker = makeAddr("attacker");
        deal(USDC, attacker, 8_000e6);
        vm.startPrank(attacker);
        IERC20(USDC).transfer(KVCM_POOL, 8_000e6);
        uint256 out = IAerodromePoolSwap(KVCM_POOL).getAmountOut(8_000e6, USDC);
        IAerodromePoolSwap(KVCM_POOL).swap(out, 0, attacker, ""); // kVCM is token0
        vm.stopPrank();
        emit log_named_uint("kVCM bought with 8,000 USDC (1e18)", out);

        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, pot, "priceOff");
        vm.prank(attacker);
        router.process(1, pot);
        assertEq(router.balanceOf(1, pot), 0.05 ether);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(router.retiredOf(1), 0);
    }

    function test_bridgedPathThroughAReceiver() public {
        RegenReceiverFactory f = new RegenReceiverFactory(router);
        address rcv = f.predict(1);
        vm.deal(rcv, 0.02 ether); // what the canonical bridge does
        f.deploy(1);
        RegenReceiver(payable(rcv)).forward();
        router.process(1, rcv);
        assertGt(router.retiredOf(1), 0);
    }
}
