// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LocalV4} from "../utils/LocalV4.sol";
import {DeployAdam} from "../../script/DeployAdam.s.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";

/// @notice End-to-end: trades pay ETH fees, process() turns them into IMD + PNKSTR, stakers claim pro-rata.
contract IntegrationTest is LocalV4 {
    function _buyFor(address who, uint256 ethIn) internal {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        buyExactIn(ethIn);
    }

    function _stakeAll(address who) internal {
        uint256 bal = adam.balanceOf(who);
        vm.startPrank(who);
        adam.approve(address(distributor), bal);
        distributor.stake(bal);
        vm.stopPrank();
    }

    function test_fullLifecycle() public {
        warpPastDecay();

        // 1. Alice and Bob buy; every buy pays 1.5% in ETH to the treasury.
        _buyFor(alice, 3 ether);
        _buyFor(bob, 1 ether);
        assertEq(address(treasury).balance, 0.06 ether);

        // 2. They stake what they hold.
        _stakeAll(alice);
        _stakeAll(bob);
        uint256 aliceStake = distributor.stakedBalance(alice);
        uint256 bobStake = distributor.stakedBalance(bob);
        assertGt(aliceStake, bobStake);

        // 3. More trading accrues more fees (a sell too).
        _buyFor(address(this), 20 ether);
        sellExactIn(adam.balanceOf(address(this)) / 2);
        uint256 fees = address(treasury).balance;
        assertGt(fees, 0.3 ether);

        // 4. Anyone processes: 10% team, the rest bought into IMD and PNKSTR and credited to stakers.
        uint256 teamBefore = teamWallet.balance;
        vm.prank(makeAddr("keeper"));
        treasury.process();
        uint256 cap = (2 * MAX_ETH_PER_BUY * 10_000) / 9000;
        uint256 processed = fees > cap ? cap : fees;
        assertEq(teamWallet.balance - teamBefore, processed / 10);

        uint256 imdTotal = distributor.totalDistributed(address(imd));
        uint256 pnkTotal = distributor.totalDistributed(address(pnkstr));
        assertGt(imdTotal, 0);
        assertGt(pnkTotal, 0);
        assertEq(distributor.unallocated(address(imd)), 0);

        // 5. Claims are pro-rata to stake, and the distributor keeps only dust.
        uint256 total = aliceStake + bobStake;
        assertApproxEqAbs(distributor.earned(alice, address(imd)), (imdTotal * aliceStake) / total, 1);
        assertApproxEqAbs(distributor.earned(bob, address(pnkstr)), (pnkTotal * bobStake) / total, 1);

        vm.prank(alice);
        distributor.claim();
        vm.prank(bob);
        distributor.exit();
        assertApproxEqAbs(imd.balanceOf(alice) + imd.balanceOf(bob), imdTotal, 2);
        assertApproxEqAbs(pnkstr.balanceOf(alice) + pnkstr.balanceOf(bob), pnkTotal, 2);
        assertEq(adam.balanceOf(bob), bobStake, "bob got all his ADAM back");
        assertEq(distributor.stakedBalance(bob), 0);
        assertEq(distributor.stakedBalance(alice), aliceStake);

        // 6. The hook never holds funds; the treasury only holds what is still unsplit.
        assertEq(address(hook).balance, 0);
        assertEq(address(treasury).balance, treasury.unsplitEth());
    }

    function test_excludedAddressesEarnNothing() public {
        warpPastDecay();
        _buyFor(alice, 1 ether);
        _stakeAll(alice);
        // The pool manager holds a lot of ADAM but cannot stake, so it never dilutes holders.
        assertGt(adam.balanceOf(address(poolManager)), 0);
        vm.prank(address(poolManager));
        vm.expectRevert();
        distributor.stake(1);
        treasury.process();
        assertApproxEqAbs(distributor.earned(alice, address(imd)), distributor.totalDistributed(address(imd)), 1);
    }
}

/// @notice The deploy script's wiring, exercised exactly as `run()` would call it.
contract DeployWiringTest is LocalV4 {
    function test_contractsAreWiredTogether() public view {
        assertEq(adam.balanceOf(address(this)) + adam.balanceOf(address(poolManager)), adam.totalSupply());
        assertEq(address(distributor.adam()), address(adam));
        assertEq(address(treasury.distributor()), address(distributor));
        assertEq(hook.treasury(), address(treasury));
        assertEq(hook.adam(), address(adam));
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.owner(), hookOwner);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, deployScript.hookFlags());
        assertEq(Currency.unwrap(adamKey.currency1), address(adam));
        assertEq(address(adamKey.hooks), address(hook));
        assertEq(adamKey.fee, 0);
        assertEq(adamKey.tickSpacing, 60);
    }

    function test_mainnetConfigConstants() public view {
        DeployAdam.Config memory c = deployScript.mainnetConfig(alice, bob, alice, address(0));
        assertEq(c.poolManager, 0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(c.imd, 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(c.pnkstr, 0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF);
        assertEq(c.pnkstrHooks, 0xfAaad5B731F52cDc9746F2414c823eca9B06E844);
        assertEq(c.pnkstrFee, 0);
        assertEq(c.pnkstrTickSpacing, 60);
        assertEq(c.imdFee, 10_000);
        assertEq(c.imdTickSpacing, 200);
        assertEq(c.pnkstrTaxBps, 1000);
        assertEq(c.initialTick % c.tickSpacing, 0);
        assertEq(c.lowerTick % c.tickSpacing, 0);
        assertLt(c.lowerTick, c.initialTick);
        assertEq(c.liquidityAdam, 1_000_000_000e18);
    }

    function test_launchPoolRejectsMisconfiguration() public {
        DeployAdam.Config memory c = cfg;
        DeployAdam.Deployment memory d;
        c.hookOwner = alice;
        vm.expectRevert(DeployAdam.DeployerMustOwnHookAtLaunch.selector);
        deployScript.launchPool(c, d);

        c.hookOwner = c.deployer;
        c.initialTick = 177_241;
        vm.expectRevert(DeployAdam.TickNotAligned.selector);
        deployScript.launchPool(c, d);

        c.initialTick = 108_180;
        c.lowerTick = 108_180;
        vm.expectRevert(DeployAdam.TickNotAligned.selector);
        deployScript.launchPool(c, d);
    }

    function test_deployWithExistingToken() public {
        DeployAdam.Config memory c = cfg;
        c.adamToken = address(adam);
        c.hookOwner = bob; // different constructor args -> different hook address, salt re-mined
        DeployAdam.Deployment memory d = deployScript.deployContracts(c);
        assertEq(address(d.token), address(adam));
        assertEq(d.hook.owner(), bob);
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, deployScript.hookFlags());
        assertTrue(address(d.hook) != address(hook));
    }
}
