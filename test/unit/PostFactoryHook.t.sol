// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LocalV4} from "../utils/LocalV4.sol";
import {DeployAdam} from "../../script/DeployAdam.s.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {AdamDistributor} from "../../src/AdamDistributor.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";

/// @notice Post-factory launch path: a third party (the launch factory) constructs LaunchToken, AdamDistributor and
/// AdamTreasury and hands the owner only their allocation. The deploy script then runs in hook-only mode against
/// that Treasury, and the fees of the hooked pool must reach the Distributor the factory deployed.
/// @custom:x https://x.com/IaMaDamIMD
contract PostFactoryHookTest is LocalV4 {
    address internal factory = makeAddr("factory");
    uint256 internal constant OWNER_ALLOCATION = 100_000_000e18;

    function _deployAdamSystem() internal override {
        // The factory: constructor-only wiring with primitive arguments, supply minted to the factory.
        vm.startPrank(factory);
        adam = new LaunchToken();
        distributor =
            new AdamDistributor(address(adam), address(imd), address(pnkstr), address(poolManager), address(0));
        treasury = new AdamTreasury(
            address(distributor),
            teamWallet,
            address(poolManager),
            address(imd),
            10_000,
            200,
            address(0),
            0,
            address(pnkstr),
            0,
            60,
            address(pnkstrHook),
            PNKSTR_TAX_BPS,
            MAX_ETH_PER_BUY,
            SLIPPAGE_BPS,
            COOLDOWN
        );
        adam.transfer(address(this), OWNER_ALLOCATION);
        vm.stopPrank();

        // The owner's hook-only run: TREASURY set, LIQUIDITY_ADAM equal to what they actually hold.
        deployScript = new DeployAdam();
        cfg = deployScript.mainnetConfig(address(this), teamWallet, hookOwner, address(0));
        cfg.treasury = address(treasury);
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
        cfg.liquidityAdam = OWNER_ALLOCATION;

        DeployAdam.Deployment memory d = deployScript.deployContracts(cfg);
        hook = d.hook;
        adamKey = d.key;
        assertEq(address(d.token), address(adam), "token read from the pipeline");
        assertEq(address(d.distributor), address(distributor), "distributor read from the pipeline");
        assertEq(address(d.treasury), address(treasury), "treasury reused, not redeployed");
    }

    function test_hookOnlyDeploymentReusesManifestedPipeline() public view {
        assertEq(hook.treasury(), address(treasury));
        assertEq(hook.adam(), address(adam));
        assertEq(address(treasury.distributor()), address(distributor));
        assertEq(address(distributor.adam()), address(adam));
        assertEq(hook.owner(), hookOwner);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, deployScript.hookFlags());
        assertEq(Currency.unwrap(adamKey.currency1), address(adam));
        assertEq(address(adamKey.hooks), address(hook));
        // Only the owner's allocation went into the pool; the factory still holds the rest.
        assertEq(adam.balanceOf(factory), adam.totalSupply() - OWNER_ALLOCATION);
        assertLe(adam.balanceOf(address(poolManager)), OWNER_ALLOCATION);
        assertGt(adam.balanceOf(address(poolManager)), OWNER_ALLOCATION - 1e18);
    }

    function test_feesFromHookedPoolReachManifestedDistributor() public {
        warpPastDecay();
        uint256 before = address(treasury).balance;
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        buyExactIn(2 ether);
        assertEq(address(treasury).balance - before, 0.03 ether, "1.5% of the buy reached the existing Treasury");

        // A holder stakes in the factory-deployed Distributor and receives the processed rewards.
        uint256 held = adam.balanceOf(alice);
        vm.startPrank(alice);
        adam.approve(address(distributor), held);
        distributor.stake(held);
        vm.stopPrank();

        uint256 teamBefore = teamWallet.balance;
        uint256 fees = address(treasury).balance;
        vm.prank(makeAddr("keeper"));
        treasury.process();
        assertEq(teamWallet.balance - teamBefore, fees / 10);
        uint256 imdTotal = distributor.totalDistributed(address(imd));
        uint256 pnkTotal = distributor.totalDistributed(address(pnkstr));
        assertGt(imdTotal, 0);
        assertGt(pnkTotal, 0);
        assertEq(distributor.unallocated(address(imd)), 0);

        vm.prank(alice);
        distributor.claim();
        assertApproxEqAbs(imd.balanceOf(alice), imdTotal, 1);
        assertApproxEqAbs(pnkstr.balanceOf(alice), pnkTotal, 1);
        assertEq(address(hook).balance, 0);
    }

    function test_resolvePipelineRejectsMismatchedConfig() public {
        DeployAdam.Config memory c = cfg;
        c.adamToken = address(imd);
        vm.expectRevert(abi.encodeWithSelector(DeployAdam.PipelineTokenMismatch.selector, address(imd), address(adam)));
        deployScript.deployContracts(c);

        c = cfg;
        c.imd = address(pnkstr);
        vm.expectRevert(
            abi.encodeWithSelector(DeployAdam.PipelineRewardMismatch.selector, uint8(0), address(pnkstr), address(imd))
        );
        deployScript.deployContracts(c);

        c = cfg;
        c.pnkstr = address(imd);
        vm.expectRevert(
            abi.encodeWithSelector(DeployAdam.PipelineRewardMismatch.selector, uint8(1), address(imd), address(pnkstr))
        );
        deployScript.deployContracts(c);
    }

    function test_launchPoolRejectsAllocationAboveHolding() public {
        DeployAdam.Config memory c = cfg;
        c.hookOwner = c.deployer;
        DeployAdam.Deployment memory d;
        d.token = adam;
        uint256 held = adam.balanceOf(address(this));
        c.liquidityAdam = held + 1;
        vm.expectRevert(abi.encodeWithSelector(DeployAdam.InsufficientAdamForLiquidity.selector, held, held + 1));
        deployScript.launchPool(c, d);
    }
}
