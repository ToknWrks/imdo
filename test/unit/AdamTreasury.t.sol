// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {LocalV4} from "../utils/LocalV4.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";
import {AdamDistributor} from "../../src/AdamDistributor.sol";

/// @dev Team wallet that refuses ETH until told otherwise.
/// @custom:x https://x.com/IaMaDamIMD
contract MoodyWallet {
    bool public accept;

    function setAccept(bool v) external {
        accept = v;
    }

    receive() external payable {
        require(accept, "no thanks");
    }
}

/// @dev Team wallet that tries to re-enter the treasury while being paid and records what happened.
/// @custom:x https://x.com/IaMaDamIMD
contract ReentrantWallet {
    AdamTreasury public treasury;
    bytes public lastRevert;
    bool public reentrySucceeded;
    bool public rejecting;
    uint8 public mode; // 0 = process, 1 = payTeam, 2 = flushRewards

    function setTreasury(AdamTreasury t) external {
        treasury = t;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setRejecting(bool v) external {
        rejecting = v;
    }

    receive() external payable {
        require(!rejecting, "rejecting");
        bool ok;
        bytes memory ret;
        if (mode == 0) (ok, ret) = address(treasury).call(abi.encodeWithSelector(AdamTreasury.process.selector));
        else if (mode == 1) (ok, ret) = address(treasury).call(abi.encodeWithSelector(AdamTreasury.payTeam.selector));
        else (ok, ret) = address(treasury).call(abi.encodeWithSelector(AdamTreasury.flushRewards.selector));
        lastRevert = ret;
        reentrySucceeded = ok;
    }
}

/// @custom:x https://x.com/IaMaDamIMD
contract AdamTreasuryTest is LocalV4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;

    function _fund(uint256 amount) internal {
        (bool ok,) = payable(address(treasury)).call{value: amount}("");
        require(ok);
    }

    function _newTreasury(address team, uint256 maxPerBuy, uint16 slippage) internal returns (AdamTreasury t) {
        t = new AdamTreasury(
            address(distributor),
            team,
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
            maxPerBuy,
            slippage,
            COOLDOWN
        );
    }

    // ------------------------------------------------------------------ construction

    function test_immutablesAndLegs() public view {
        assertEq(address(treasury.poolManager()), address(poolManager));
        assertEq(address(treasury.distributor()), address(distributor));
        assertEq(treasury.teamWallet(), teamWallet);
        assertEq(treasury.maxEthPerBuy(), MAX_ETH_PER_BUY);
        assertEq(treasury.slippageBps(), SLIPPAGE_BPS);
        assertEq(treasury.cooldown(), COOLDOWN);
        AdamTreasury.Leg memory l0 = treasury.leg(treasury.LEG_IMD());
        AdamTreasury.Leg memory l1 = treasury.leg(treasury.LEG_PNKSTR());
        assertEq(keccak256(abi.encode(l0.key)), keccak256(abi.encode(imdKey)));
        assertEq(keccak256(abi.encode(l1.key)), keccak256(abi.encode(pnkstrKey)));
        assertEq(l0.hookTaxBps, 0);
        assertEq(l1.hookTaxBps, PNKSTR_TAX_BPS);
    }

    function test_constructorValidation() public {
        vm.expectRevert(AdamTreasury.ZeroAddress.selector);
        _newTreasury(address(0), 1 ether, 300);
        vm.expectRevert(AdamTreasury.InvalidParameter.selector);
        _newTreasury(teamWallet, 0, 300);
        vm.expectRevert(AdamTreasury.InvalidParameter.selector);
        _newTreasury(teamWallet, 1 ether, 2001);
        vm.expectRevert(AdamTreasury.InvalidParameter.selector);
        new AdamTreasury(
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
            10_000,
            1 ether,
            300,
            COOLDOWN
        );
        vm.expectRevert(AdamTreasury.InvalidParameter.selector);
        new AdamTreasury(
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
            1000,
            1 ether,
            300,
            uint32(2 days)
        );
    }

    // ------------------------------------------------------------------ process(): split and buys

    function test_processSplitsTenNinetyAndBuysBothTokens() public {
        _fund(1 ether);
        uint256 teamBefore = teamWallet.balance;

        vm.expectEmit(false, false, false, true, address(treasury));
        emit AdamTreasury.Split(1 ether, 0.1 ether, 0.9 ether);
        treasury.process();

        assertEq(teamWallet.balance - teamBefore, 0.1 ether, "team gets 10%");
        assertEq(address(treasury).balance, 0, "all ETH used");
        assertEq(treasury.leg(0).pending, 0);
        assertEq(treasury.leg(1).pending, 0);

        uint256 imdGot = imd.balanceOf(address(distributor));
        uint256 pnkGot = pnkstr.balanceOf(address(distributor));
        assertGt(imdGot, 0, "IMD bought");
        assertGt(pnkGot, 0, "PNKSTR bought");
        // 45% of the ETH went to each leg, at least at the quoted floor.
        assertGe(imdGot, treasury.quoteMinOut(0, 0.45 ether));
        assertGe(pnkGot, treasury.quoteMinOut(1, 0.45 ether));
        // Nobody staked yet: rewards wait in `unallocated`.
        assertEq(distributor.unallocated(address(imd)), imdGot);
        assertEq(distributor.unallocated(address(pnkstr)), pnkGot);
        assertEq(treasury.lastProcessed(), block.timestamp);
    }

    function test_legsReceiveEqualEth() public {
        _fund(1 ether);
        uint256 pmBefore = address(poolManager).balance;
        uint256 taxBefore = pnkstr.balanceOf(address(pnkstrHook));
        treasury.process();
        assertEq(address(poolManager).balance - pmBefore, 0.9 ether, "0.45 + 0.45 ETH swapped");
        // The PNKSTR hook tax (10%) was paid by us, so the distributor got ~90% of the pool output.
        uint256 tax = pnkstr.balanceOf(address(pnkstrHook)) - taxBefore;
        uint256 got = pnkstr.balanceOf(address(distributor));
        assertApproxEqRel(tax * 9, got, 1e15, "tax is 1/9 of what we kept");
    }

    function test_processRevertsWhenNothingToDo() public {
        vm.expectRevert(AdamTreasury.NothingToProcess.selector);
        treasury.process();
    }

    function test_cooldownBetweenCalls() public {
        _fund(1 ether);
        treasury.process();
        _fund(1 ether);
        uint64 availableAt = uint64(block.timestamp + COOLDOWN);
        vm.expectRevert(abi.encodeWithSelector(AdamTreasury.CooldownActive.selector, availableAt));
        treasury.process();
        vm.warp(availableAt);
        treasury.process();
    }

    function test_capPerCallLeavesRemainderUnsplit() public {
        _fund(10 ether);
        uint256 teamBefore = teamWallet.balance;
        treasury.process();
        uint256 cap = (2 * MAX_ETH_PER_BUY * BPS) / (BPS - 1000); // 2.222... ETH
        assertEq(teamWallet.balance - teamBefore, (cap * 1000) / BPS);
        assertEq(treasury.unsplitEth(), 10 ether - cap);
        assertEq(treasury.leg(0).pending, 0);
        assertEq(treasury.leg(1).pending, 0);
        assertEq(address(treasury).balance, 10 ether - cap);
    }

    function test_anyoneCanProcess() public {
        _fund(1 ether);
        vm.prank(alice);
        treasury.process();
        assertEq(address(treasury).balance, 0);
    }

    // ------------------------------------------------------------------ slippage / failing legs

    function test_legFailsWhenHookTaxExceedsAssumption_pendingIsKept() public {
        pnkstrHook.setTaxBps(1500); // 15% > 10% assumed + 3% slippage
        _fund(1 ether);
        treasury.process();

        assertGt(imd.balanceOf(address(distributor)), 0, "IMD leg still succeeds");
        assertEq(pnkstr.balanceOf(address(distributor)), 0, "PNKSTR leg did not buy");
        AdamTreasury.Leg memory l = treasury.leg(1);
        assertEq(l.pending, 0.45 ether, "ETH stays earmarked");
        assertEq(l.failingSince, block.timestamp);
        assertEq(address(treasury).balance, 0.45 ether);

        // Tax goes back to normal: next call retries and succeeds.
        pnkstrHook.setTaxBps(1000);
        vm.warp(block.timestamp + COOLDOWN);
        treasury.process();
        assertGt(pnkstr.balanceOf(address(distributor)), 0);
        assertEq(treasury.leg(1).pending, 0.225 ether, "successful retry uses half the failed amount");
        assertEq(treasury.leg(1).failingSince, 0);
        vm.warp(block.timestamp + COOLDOWN);
        treasury.process();
        assertEq(treasury.leg(1).pending, 0);
    }

    function test_legFailureEmitsReason() public {
        pnkstrHook.setRevertSwaps(true);
        _fund(1 ether);
        vm.recordLogs();
        treasury.process();
        // The LegFailed event is emitted once, for the PNKSTR leg, carrying the hook's revert reason.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LegFailed(uint8,uint256,bytes)");
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            ++count;
            assertEq(uint256(logs[i].topics[1]), 1, "PNKSTR leg");
            (uint256 attempted,) = abi.decode(logs[i].data, (uint256, bytes));
            assertEq(attempted, 0.45 ether);
        }
        assertEq(count, 1);
    }

    function test_ownSwapImpactAboveSlippageIsRejected() public {
        // A treasury allowed to swap 150 ETH per leg against ~200 ETH pools would move price > 3%.
        AdamTreasury big = _newTreasury(teamWallet, 150 ether, 300);
        (bool ok,) = payable(address(big)).call{value: 340 ether}("");
        require(ok);
        big.process();
        assertEq(imd.balanceOf(address(distributor)), 0, "IMD leg refused");
        assertEq(pnkstr.balanceOf(address(distributor)), 0, "PNKSTR leg refused");
        assertEq(big.leg(0).pending, 150 ether);
        assertEq(big.leg(1).pending, 150 ether);
        uint256 cap = (2 * 150 ether * BPS) / (BPS - 1000);
        assertEq(address(big).balance, 340 ether - (cap * 1000) / BPS);
    }

    function test_rerouteAfterThreeDaysOfFailure() public {
        pnkstrHook.setRevertSwaps(true);
        _fund(1 ether);
        treasury.process(); // IMD ok, PNKSTR fails -> failingSince = now
        uint64 since = treasury.leg(1).failingSince;
        assertEq(since, block.timestamp);
        assertEq(treasury.leg(1).pending, 0.45 ether);

        for (uint256 hour = 1; hour <= 72; ++hour) {
            vm.warp(uint256(since) + hour * 1 hours);
            treasury.process();
            if (hour < 72) assertEq(treasury.leg(1).pending, 0.45 ether);
        }
        assertEq(treasury.leg(1).pending, 0);
        assertEq(treasury.leg(0).pending, 0.45 ether, "moved to the IMD leg");

        uint256 imdBefore = imd.balanceOf(address(distributor));
        vm.warp(block.timestamp + COOLDOWN);
        treasury.process();
        assertEq(treasury.leg(0).pending, 0);
        assertGt(imd.balanceOf(address(distributor)), imdBefore);
        assertEq(address(treasury).balance, 0);
    }

    function test_rerouteWorksInBothDirections() public {
        // Kill the IMD pool for the treasury by making its quote unreachable: deploy a treasury whose IMD
        // leg points at a pool that does not exist (uninitialized key) so the swap always reverts.
        AdamTreasury t = new AdamTreasury(
            address(distributor),
            teamWallet,
            address(poolManager),
            address(imd),
            3000,
            60,
            address(0),
            0,
            address(pnkstr),
            0,
            60,
            address(pnkstrHook),
            PNKSTR_TAX_BPS,
            1 ether,
            300,
            COOLDOWN
        );
        (bool ok,) = payable(address(t)).call{value: 1 ether}("");
        require(ok);
        t.process();
        assertEq(t.leg(0).pending, 0.45 ether, "IMD leg (dead pool) keeps its ETH");
        assertEq(t.leg(1).pending, 0);
        uint64 since = t.leg(0).failingSince;
        uint256 pnkBefore = pnkstr.balanceOf(address(distributor));
        for (uint256 hour = 1; hour <= 72; ++hour) {
            vm.warp(uint256(since) + hour * 1 hours);
            t.process();
        }
        assertEq(t.leg(0).pending, 0);
        // rerouted into PNKSTR which executes in the same call (leg order 0 then 1)
        assertEq(t.leg(1).pending, 0);
        assertGt(pnkstr.balanceOf(address(distributor)), pnkBefore);
    }

    function test_quoteMinOutMatchesSpotMath() public view {
        (uint160 sqrtP,,, uint24 lpFee) = IPoolManager(address(poolManager)).getSlot0(imdKey.toId());
        uint256 ethIn = 0.45 ether;
        uint256 afterFee = ethIn - FullMath.mulDiv(ethIn, lpFee, 1_000_000);
        uint256 spot = FullMath.mulDiv(afterFee, sqrtP, FixedPoint96.Q96);
        spot = FullMath.mulDiv(spot, sqrtP, FixedPoint96.Q96);
        uint256 expected = (spot * (BPS - SLIPPAGE_BPS)) / BPS;
        assertEq(treasury.quoteMinOut(0, ethIn), expected);

        (uint160 sqrtP2,,,) = IPoolManager(address(poolManager)).getSlot0(pnkstrKey.toId());
        uint256 spot2 = FullMath.mulDiv(FullMath.mulDiv(ethIn, sqrtP2, FixedPoint96.Q96), sqrtP2, FixedPoint96.Q96);
        uint256 expected2 = (((spot2 * (BPS - PNKSTR_TAX_BPS)) / BPS) * (BPS - SLIPPAGE_BPS)) / BPS;
        assertEq(treasury.quoteMinOut(1, ethIn), expected2);
    }

    // ------------------------------------------------------------------ team payment paths

    function test_teamPushFailureIsDeferredNotBlocking() public {
        MoodyWallet wallet = new MoodyWallet();
        AdamTreasury t = _newTreasury(address(wallet), 1 ether, 300);
        (bool ok,) = payable(address(t)).call{value: 1 ether}("");
        require(ok);

        t.process();
        assertEq(t.teamOwed(), 0.1 ether, "team share held");
        assertGt(imd.balanceOf(address(distributor)), 0, "holders still served");
        assertEq(address(t).balance, 0.1 ether);
        assertEq(t.unsplitEth(), 0);

        vm.expectRevert(AdamTreasury.TeamTransferFailed.selector);
        t.payTeam();
        assertEq(t.teamOwed(), 0.1 ether);

        wallet.setAccept(true);
        vm.prank(alice);
        t.payTeam();
        assertEq(address(wallet).balance, 0.1 ether);
        assertEq(t.teamOwed(), 0);
        vm.expectRevert(AdamTreasury.NothingOwed.selector);
        t.payTeam();
    }

    function test_teamWalletCannotReenterProcess() public {
        ReentrantWallet wallet = new ReentrantWallet();
        AdamTreasury t = _newTreasury(address(wallet), 1 ether, 300);
        wallet.setTreasury(t);
        (bool ok,) = payable(address(t)).call{value: 1 ether}("");
        require(ok);

        bytes4 guardError = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

        // process() -> team push -> wallet re-enters process(): blocked, outer call completes normally.
        t.process();
        assertFalse(wallet.reentrySucceeded());
        assertEq(bytes4(wallet.lastRevert()), guardError);
        assertEq(address(wallet).balance, 0.1 ether, "team paid exactly once");
        assertEq(t.teamOwed(), 0);
        assertGt(imd.balanceOf(address(distributor)), 0);
        assertGt(pnkstr.balanceOf(address(distributor)), 0);

        // payTeam() -> wallet re-enters payTeam(): blocked, no double payment.
        wallet.setRejecting(true);
        (ok,) = payable(address(t)).call{value: 1 ether}("");
        require(ok);
        vm.warp(block.timestamp + COOLDOWN);
        t.process();
        assertEq(t.teamOwed(), 0.1 ether, "deferred while rejecting");
        wallet.setRejecting(false);
        wallet.setMode(1);
        t.payTeam();
        assertFalse(wallet.reentrySucceeded());
        assertEq(bytes4(wallet.lastRevert()), guardError);
        assertEq(address(wallet).balance, 0.2 ether);
        assertEq(t.teamOwed(), 0);

        // flushRewards() re-entry is blocked the same way.
        wallet.setMode(2);
        wallet.setRejecting(true);
        (ok,) = payable(address(t)).call{value: 1 ether}("");
        require(ok);
        vm.warp(block.timestamp + COOLDOWN);
        t.process();
        wallet.setRejecting(false);
        t.payTeam();
        assertFalse(wallet.reentrySucceeded());
        assertEq(bytes4(wallet.lastRevert()), guardError);
    }

    // ------------------------------------------------------------------ callback and misc

    function test_unlockCallbackIsGuarded() public {
        vm.expectRevert(AdamTreasury.NotPoolManager.selector);
        treasury.unlockCallback(abi.encode(uint8(0), uint256(1 ether)));
        vm.prank(address(poolManager));
        vm.expectRevert(AdamTreasury.NotProcessing.selector);
        treasury.unlockCallback(abi.encode(uint8(0), uint256(1 ether)));
    }

    function test_flushRewardsForwardsStrandedTokens() public {
        imd.mint(address(treasury), 5e18);
        treasury.flushRewards();
        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(imd.balanceOf(address(distributor)), 5e18);
        assertEq(distributor.unallocated(address(imd)), 5e18);
    }

    function test_noWithdrawalPathForAnyone() public {
        _fund(1 ether);
        bytes4[5] memory selectors = [
            bytes4(keccak256("withdraw()")),
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("owner()"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(treasury).call(abi.encodeWithSelector(selectors[i], address(this), uint256(1 ether)));
            assertFalse(ok);
        }
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_distributorPendingRewardsFlowToStakersLater() public {
        _fund(1 ether);
        treasury.process();
        uint256 imdGot = imd.balanceOf(address(distributor));
        // Alice buys and stakes afterwards; the backlog vests over seven days from her stake.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        buyExactIn(1 ether);
        uint256 bal = adam.balanceOf(alice);
        vm.startPrank(alice);
        adam.approve(address(distributor), bal);
        distributor.stake(bal);
        vm.stopPrank();
        _fund(1 ether);
        vm.warp(block.timestamp + COOLDOWN);
        treasury.process();
        assertGt(distributor.unallocated(address(imd)), 0);
        vm.warp(block.timestamp + distributor.BACKLOG_DURATION());
        distributor.claim(); // permissionless checkpoint through a holder action
        assertEq(distributor.unallocated(address(imd)), 0);
        assertApproxEqAbs(
            distributor.earned(alice, address(imd)), imd.balanceOf(address(distributor)), 1, "only staker"
        );
        assertGt(distributor.earned(alice, address(imd)), imdGot);
    }
}
