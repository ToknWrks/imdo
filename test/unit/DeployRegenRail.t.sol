// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRegenRail} from "../../script/DeployRegenRail.s.sol";
import {MockUsdc, MockKvcm, MockPool, MockFeed, MockAggregator} from "./RegenRouter.t.sol";

contract HasCode {}

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
        agg = new MockAggregator(usdc, address(kvcm), pool, 22e18);
        c = DeployRegenRail.Config({
            chainId: block.chainid,
            deployer: address(script),
            aggregator: address(agg),
            usdc: address(usdc),
            kvcm: address(kvcm),
            kvcmPool: address(pool),
            classVault: address(new HasCode()),
            creditA: address(new HasCode()),
            creditB: address(new HasCode()),
            creditC: address(new HasCode()),
            swapRouter02: address(new HasCode()),
            weth: address(new HasCode()),
            v3Fee: 500,
            ethUsd: address(feed),
            maxFeedAge: 3600,
            minBatch: 0.001 ether,
            maxBatch: 0.05 ether,
            bountyBps: 50,
            minOutBps: 9700,
            twapGranularity: 4,
            minTonnesBps: 9700,
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
        assertEq(d.router.twapGranularity(), 4);
        assertEq(d.router.minTonnesBps(), 9700);
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
        c.beneficiary = address(0);
        vm.expectRevert(DeployRegenRail.InvalidConfiguration.selector);
        script.deploy(c);
        assertEq(vm.getNonce(address(script)), nonce);
    }

    function test_aBadRegenAddressFailsTheWholeDeployment() public {
        DeployRegenRail.Config memory c = _config();
        c.regenAddress = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvaq"; // a typo
        vm.expectRevert();
        script.deploy(c);
    }
}
