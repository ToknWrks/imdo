// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalV4} from "../utils/LocalV4.sol";
import {AdamTreasury} from "../../src/AdamTreasury.sol";

/// @notice Property tests for the Treasury's split accounting and ETH conservation.
/// @custom:x https://x.com/IaMaDamIMD
contract TreasuryFuzzTest is LocalV4 {
    uint256 internal constant BPS = 10_000;

    function _fund(uint256 amount) internal {
        (bool ok,) = payable(address(treasury)).call{value: amount}("");
        require(ok);
    }

    /// @dev For any amount below the per-call cap: team gets exactly 10%, the legs share the other 90% to the wei,
    /// and nothing is left behind after both buys succeed.
    function testFuzz_splitIsExact(uint256 amount) public {
        uint256 cap = (2 * MAX_ETH_PER_BUY * BPS) / (BPS - 1000);
        amount = bound(amount, 1e10, cap);
        _fund(amount);
        uint256 teamBefore = teamWallet.balance;
        uint256 pmBefore = address(poolManager).balance;

        treasury.process();

        uint256 team = (amount * 1000) / BPS;
        uint256 holders = amount - team;
        assertEq(teamWallet.balance - teamBefore, team, "team share");
        assertEq(address(poolManager).balance - pmBefore, holders, "holders' share fully swapped");
        assertEq(address(treasury).balance, 0, "nothing stranded");
        assertEq(treasury.unsplitEth(), 0);
        assertGt(imd.balanceOf(address(distributor)), 0);
        assertGt(pnkstr.balanceOf(address(distributor)), 0);
    }

    /// @dev Above the cap the remainder waits, unsplit, and ETH is conserved exactly.
    function testFuzz_capAndConservation(uint256 amount) public {
        uint256 cap = (2 * MAX_ETH_PER_BUY * BPS) / (BPS - 1000);
        amount = bound(amount, cap + 1, 500 ether);
        _fund(amount);
        uint256 teamBefore = teamWallet.balance;
        uint256 pmBefore = address(poolManager).balance;

        treasury.process();

        uint256 team = (cap * 1000) / BPS;
        assertEq(teamWallet.balance - teamBefore, team);
        assertEq(address(poolManager).balance - pmBefore, cap - team);
        assertEq(address(treasury).balance, amount - cap);
        assertEq(treasury.unsplitEth(), amount - cap);
        assertEq(treasury.leg(0).pending, 0);
        assertEq(treasury.leg(1).pending, 0);
    }

    /// @dev Whatever the hook tax does, the treasury never loses ETH: balance == unsplit + pending + teamOwed.
    function testFuzz_accountingIdentityHolds(uint256 amount, uint16 tax, uint8 rounds) public {
        amount = bound(amount, 1e12, 20 ether);
        tax = uint16(bound(tax, 0, 5000));
        rounds = uint8(bound(rounds, 1, 4));
        pnkstrHook.setTaxBps(tax);
        uint256 teamPaid;
        // via-IR may cache block.timestamp within a call, so advance an explicit clock instead of re-reading it.
        uint256 clock = block.timestamp;
        for (uint256 i; i < rounds; ++i) {
            _fund(amount);
            uint256 teamBefore = teamWallet.balance;
            treasury.process();
            teamPaid += teamWallet.balance - teamBefore;
            clock += COOLDOWN;
            vm.warp(clock);
            assertEq(
                address(treasury).balance,
                treasury.unsplitEth() + treasury.leg(0).pending + treasury.leg(1).pending + treasury.teamOwed()
            );
        }
        // The IMD leg always succeeds (no tax), so at least the IMD side is bought every round.
        assertGt(imd.balanceOf(address(distributor)), 0);
        if (tax > 1000 + 300) {
            assertEq(pnkstr.balanceOf(address(distributor)), 0, "over-taxed leg refused");
            assertGt(treasury.leg(1).pending, 0);
        } else if (tax <= 1000 + 200) {
            // within the assumed tax plus 2% headroom (the remaining 1% covers price impact), the leg buys
            assertGt(pnkstr.balanceOf(address(distributor)), 0);
            assertEq(treasury.leg(1).pending, 0);
        }
        assertGt(teamPaid, 0);
    }

    /// @dev The output minimum scales linearly with input (spot quote), so the slippage check cannot be
    /// bypassed by splitting a swap.
    function testFuzz_quoteIsLinear(uint256 ethIn) public view {
        ethIn = bound(ethIn, 1e9, 10 ether);
        uint256 q1 = treasury.quoteMinOut(0, ethIn);
        uint256 q2 = treasury.quoteMinOut(0, ethIn * 2);
        assertApproxEqRel(q2, q1 * 2, 1e9); // 1e-9 relative: only fixed-point rounding differs
        uint256 p1 = treasury.quoteMinOut(1, ethIn);
        uint256 p2 = treasury.quoteMinOut(1, ethIn * 2);
        assertApproxEqRel(p2, p1 * 2, 1e9);
    }
}
