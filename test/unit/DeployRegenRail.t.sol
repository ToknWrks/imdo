// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRegenRail} from "../../script/DeployRegenRail.s.sol";
import {RegenReceiver, RegenReceiverFactory} from "../../src/regen/RegenReceiver.sol";
import {MockUsdc, MockKvcm, MockPool, MockFeed, MockAggregator, MockCredit} from "./RegenRouter.t.sol";

contract HasCode {}

contract MockV3Factory {
    function getPool(address, address, uint24 fee) external pure returns (address) {
        return fee == 500 ? address(0xB001) : address(0);
    }
}

contract MockSwapRouter02 {
    address public factory;

    constructor() {
        factory = address(new MockV3Factory());
    }
}

contract DeployRegenRailTest is Test {
    DeployRegenRail internal script;
    MockUsdc internal usdc;
    MockKvcm internal kvcm;
    MockPool internal pool;
    MockFeed internal feed;
    MockAggregator internal agg;
    address internal beneficiary = makeAddr("imdo-safe");
    string internal constant REGEN = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan";

    function _config() internal returns (DeployRegenRail.Config memory c) {
        script = new DeployRegenRail();
        usdc = new MockUsdc();
        kvcm = new MockKvcm();
        pool = new MockPool(address(kvcm), address(usdc));
        feed = new MockFeed();
        address vault = address(new HasCode());
        agg = new MockAggregator(usdc, address(kvcm), pool, vault, 22e18);
        address a = address(new MockCredit("A"));
        address b = address(new MockCredit("B"));
        address cc = address(new MockCredit("C"));
        agg.setCredit(a, 1000e18);
        agg.setCredit(b, 1000e18);
        agg.setCredit(cc, 1000e18);
        c = DeployRegenRail.Config({
            chainId: block.chainid,
            deployer: address(script),
            aggregator: address(agg),
            usdc: address(usdc),
            kvcm: address(kvcm),
            kvcmPool: address(pool),
            classVault: vault,
            creditA: a,
            creditB: b,
            creditC: cc,
            swapRouter02: address(new MockSwapRouter02()),
            weth: address(new HasCode()),
            v3Fee: 500,
            ethUsd: address(feed),
            sequencerUptime: address(new MockFeed()),
            maxFeedAge: 3600,
            minBatch: 0.001 ether,
            maxBatch: 0.05 ether,
            bountyBps: 50,
            minOutBps: 9700,
            twapGranularity: 48,
            minTonnesBps: 9500,
            maxUsdcPerTonne: 45e6,
            processInterval: 7200,
            projectName: "IMDO",
            regenAddress: REGEN,
            beneficiary: beneficiary
        });
    }

    function test_deploysRegistersFirstAndDeploysTheReceiver() public {
        DeployRegenRail.Config memory c = _config();
        DeployRegenRail.Deployment memory d = script.deploy(c);
        assertEq(d.projectId, 1);
        assertEq(d.registry.project(1).beneficiary, beneficiary);
        assertEq(d.registry.project(1).name, "IMDO");
        assertEq(address(d.router.registry()), address(d.registry));
        assertEq(address(d.router.venue()), address(d.venue));
        assertEq(d.venue.token(), address(usdc));
        assertEq(d.venue.fee(), 500);
        assertEq(d.router.maxBatch(), 0.05 ether);
        assertEq(d.router.twapGranularity(), 48);
        assertEq(d.router.minTonnesBps(), 9500);
        assertEq(d.router.maxUsdcPerTonne(), 45e6);
        assertEq(d.router.processInterval(), 7200);
        assertEq(d.registry.count(), 1); // registered in the registry's own creation
        assertEq(address(d.router.sequencerUptime()), c.sequencerUptime);
        assertEq(address(d.factory.router()), address(d.router));
        assertEq(d.receiver, d.factory.predict(1));
        assertGt(d.receiver.code.length, 0);
    }

    function test_preflightRefusesBeforeAnyCreation() public {
        DeployRegenRail.Config memory c = _config();
        uint64 nonce = vm.getNonce(address(script));
        c.aggregator = makeAddr("no-code");
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.chainId++;
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.minTonnesBps = 0;
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.kvcmPool = address(new MockPool(address(kvcm), makeAddr("other")));
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.v3Fee = 1234; // no WETH/USDC pool at that tier
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.projectName = "";
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.sequencerUptime = makeAddr("no-code-either");
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.beneficiary = address(0);
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        assertEq(vm.getNonce(address(script)), nonce);
    }

    /// @dev Round-3 info: the credit leg's reads all run inside try/catch in the router, so a rail deployed with a
    ///      granularity the pool cannot answer, a nonsense fee or an unquotable credit would skip "priceOff" forever.
    function test_preflightExercisesTheCreditLeg() public {
        DeployRegenRail.Config memory c = _config();
        uint64 nonce = vm.getNonce(address(script));
        pool.setQuoteBroken(true); // the pool cannot quote at twapGranularity
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        pool.aeroFactory().setFee(10_000);
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        c.creditC = address(new MockCredit("unknown")); // the aggregator does not quote it
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        c = _config();
        vm.mockCall(
            address(agg),
            abi.encodeWithSelector(agg.quoteRetireCreditForInputTokenInViaKlima.selector),
            abi.encode(uint256(0), uint256(0), uint256(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0))
        );
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        vm.clearMockedCalls();
        assertEq(vm.getNonce(address(script)), nonce);
    }

    /// @dev Round-3 info: `factory.deploy(1)` is permissionless; a receiver landed by someone else between the
    ///      factory's creation and the script's call is the same CREATE2 receiver, so the script takes it.
    function test_aReceiverDeployedBySomeoneElseFirstIsTaken() public {
        DeployRegenRail.Config memory c = _config();
        uint64 nonce = vm.getNonce(address(script));
        // registry, venue, router, factory: the factory is the script's fourth creation, the router its third
        address router = vm.computeCreateAddress(address(script), nonce + 2);
        address factory = vm.computeCreateAddress(address(script), nonce + 3);
        bytes32 initHash = keccak256(abi.encodePacked(type(RegenReceiver).creationCode, abi.encode(router, uint256(1))));
        address receiver = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, bytes32(uint256(1)), initHash))))
        );
        vm.etch(receiver, hex"600160005260206000f3"); // someone got there first (any code at the predicted address)
        DeployRegenRail.Deployment memory d = script.deploy(c);
        assertEq(address(d.factory), factory);
        assertEq(d.factory.predict(1), receiver);
        assertEq(d.receiver, receiver);
        vm.expectRevert(abi.encodeWithSelector(RegenReceiverFactory.AlreadyDeployed.selector, receiver));
        d.factory.deploy(1);
    }

    function test_aBadRegenAddressFailsTheWholeDeployment() public {
        DeployRegenRail.Config memory c = _config();
        c.regenAddress = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvaq"; // a typo
        vm.expectRevert();
        script.deploy(c);
    }
}
