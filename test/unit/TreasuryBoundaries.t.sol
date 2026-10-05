// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "../utils/LocalV4.sol";
import {AdamTreasury} from "src/AdamTreasury.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract CallbackTeamWallet {
    AdamTreasury public treasury;
    bool public rejecting = true;
    uint256 public blocked;

    function configure(AdamTreasury target, bool rejectPayment) external {
        treasury = target;
        rejecting = rejectPayment;
    }

    receive() external payable {
        require(!rejecting, "team unavailable");
        bytes[3] memory attempts = [
            abi.encodeCall(AdamTreasury.process, ()),
            abi.encodeCall(AdamTreasury.payTeam, ()),
            abi.encodeCall(AdamTreasury.flushRewards, ())
        ];
        uint256 rejected;
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok, bytes memory reason) = address(treasury).call(attempts[i]);
            require(
                !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "unguarded callback"
            );
            ++rejected;
        }
        blocked += rejected;
    }
}

/// @notice Boundary regressions supplement the accepted suites without changing their fixtures.
/// @custom:x https://x.com/IaMaDamIMD
contract TreasuryBoundariesTest is LocalV4 {
    function _fund(AdamTreasury target, uint256 amount) private {
        (bool ok,) = address(target).call{value: amount}("");
        assertTrue(ok);
    }

    function test_cooldownRejectsOneSecondEarlyAndAcceptsExactBoundary() public {
        _fund(treasury, 1 ether);
        treasury.process();
        uint64 processed = treasury.lastProcessed();
        uint64 available = processed + COOLDOWN;
        _fund(treasury, 1 ether);
        uint256 imdBefore = imd.balanceOf(address(distributor));
        uint256 pnkBefore = pnkstr.balanceOf(address(distributor));
        uint256 teamBefore = teamWallet.balance;

        vm.warp(available - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AdamTreasury.CooldownActive.selector, available));
        treasury.process();
        assertEq(treasury.lastProcessed(), processed);
        assertEq(treasury.unsplitEth(), 1 ether);
        assertEq(teamWallet.balance, teamBefore);
        assertEq(imd.balanceOf(address(distributor)), imdBefore);
        assertEq(pnkstr.balanceOf(address(distributor)), pnkBefore);

        vm.warp(available);
        vm.prank(bob);
        treasury.process();
        assertEq(treasury.lastProcessed(), available);
        assertEq(teamWallet.balance - teamBefore, 0.1 ether);
        assertGt(imd.balanceOf(address(distributor)), imdBefore);
        assertGt(pnkstr.balanceOf(address(distributor)), pnkBefore);
        assertEq(address(treasury).balance, 0);
    }

    function test_failureGapContinuesAtBoundaryAndResetsOneSecondLater() public {
        pnkstrHook.setRevertSwaps(true);
        _fund(treasury, 1 ether);
        treasury.process();
        uint256 first = vm.getBlockTimestamp();
        uint256 gap = treasury.MAX_FAILURE_GAP();
        assertEq(treasury.leg(1).pending, 0.45 ether);
        assertEq(treasury.leg(1).retryCap, 0.225 ether);

        vm.warp(first + gap);
        treasury.process();
        AdamTreasury.Leg memory continued = treasury.leg(1);
        assertEq(continued.failures, 2);
        assertEq(continued.failingSince, first);
        assertEq(continued.retryCap, 0.1125 ether);
        assertEq(continued.pending, 0.45 ether);

        uint256 resumedAt = first + 2 * gap + 1;
        vm.warp(resumedAt);
        treasury.process();
        AdamTreasury.Leg memory restarted = treasury.leg(1);
        assertEq(restarted.failures, 1);
        assertEq(restarted.failingSince, resumedAt);
        assertEq(restarted.lastFailure, resumedAt);
        assertEq(restarted.retryCap, 0.225 ether, "new streak must use the full available amount");
        assertEq(restarted.pending, 0.45 ether);
        assertEq(address(treasury).balance, 0.45 ether);
        assertEq(teamWallet.balance, 0.1 ether, "retry must not pay the team twice");
        assertEq(pnkstr.balanceOf(address(distributor)), 0);

        pnkstrHook.setRevertSwaps(false);
        vm.warp(resumedAt + COOLDOWN);
        treasury.process();
        assertGt(pnkstr.balanceOf(address(distributor)), 0, "failed leg remains recoverable");
        assertEq(treasury.leg(1).pending, 0.225 ether);
        assertEq(treasury.leg(1).failures, 0);
        assertEq(treasury.leg(1).retryCap, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_directionalProtocolFeesPreserveExecutableOutputFloors(uint16 buyFee, uint16 sellFee) public {
        buyFee = uint16(bound(buyFee, 1, 1000));
        sellFee = uint16(bound(sellFee, 1, 1000));
        uint256 quoteBefore = treasury.quoteMinOut(0, 0.45 ether);
        poolManager.setProtocolFeeController(address(this));

        // v4 packs the two directions separately. A sell-only fee cannot reduce a buy quote.
        poolManager.setProtocolFee(imdKey, uint24(sellFee) << 12);
        assertEq(treasury.quoteMinOut(0, 0.45 ether), quoteBefore);
        uint24 packed = uint24(buyFee) | (uint24(sellFee) << 12);
        poolManager.setProtocolFee(imdKey, packed);
        poolManager.setProtocolFee(pnkstrKey, packed);
        uint256 imdFloor = treasury.quoteMinOut(0, 0.45 ether);
        uint256 pnkFloor = treasury.quoteMinOut(1, 0.45 ether);
        assertGt(imdFloor, 0);
        assertGt(pnkFloor, 0);
        assertLt(imdFloor, quoteBefore);

        uint256 managerBefore = address(poolManager).balance;
        _fund(treasury, 1 ether);
        treasury.process();
        assertGe(imd.balanceOf(address(distributor)), imdFloor);
        assertGe(pnkstr.balanceOf(address(distributor)), pnkFloor);
        assertGt(poolManager.protocolFeesAccrued(CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(address(poolManager).balance - managerBefore, 0.9 ether);
        assertEq(teamWallet.balance, 0.1 ether);
        assertEq(address(treasury).balance, 0);
        assertEq(treasury.leg(0).pending, 0);
        assertEq(treasury.leg(1).pending, 0);
    }

    function test_deferredAndDirectTeamPaymentsGuardEveryMaintenanceEntryPoint() public {
        CallbackTeamWallet wallet = new CallbackTeamWallet();
        AdamTreasury target = new AdamTreasury(
            address(distributor),
            address(wallet),
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
            MAX_ETH_PER_BUY,
            SLIPPAGE_BPS,
            COOLDOWN
        );
        wallet.configure(target, true);
        _fund(target, 1 ether);
        target.process();
        assertEq(target.teamOwed(), 0.1 ether);
        assertEq(address(target).balance, 0.1 ether);
        assertGt(imd.balanceOf(address(distributor)), 0);
        assertGt(pnkstr.balanceOf(address(distributor)), 0);

        vm.expectRevert(AdamTreasury.TeamTransferFailed.selector);
        target.payTeam();
        assertEq(target.teamOwed(), 0.1 ether, "failed payout restores debt");
        wallet.configure(target, false);
        vm.prank(alice);
        target.payTeam();
        assertEq(wallet.blocked(), 3);
        assertEq(address(wallet).balance, 0.1 ether);
        assertEq(target.teamOwed(), 0);
        assertEq(address(target).balance, 0);
        vm.expectRevert(AdamTreasury.NothingOwed.selector);
        target.payTeam();

        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        _fund(target, 1 ether);
        target.process();
        assertEq(wallet.blocked(), 6, "gas-capped direct push must also complete guarded callbacks");
        assertEq(address(wallet).balance, 0.2 ether);
        assertEq(target.teamOwed(), 0);
        assertEq(address(target).balance, 0);
    }
}
