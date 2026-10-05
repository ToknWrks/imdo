// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LocalV4} from "../utils/LocalV4.sol";
import {MockTaxHook} from "../utils/MockTaxHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AdamTreasury} from "src/AdamTreasury.sol";
import {AdamDistributor} from "src/AdamDistributor.sol";

/// @custom:x https://x.com/IaMaDamIMD
contract InvariantTeamWallet {
    bool public accepting;

    function setAccepting(bool value) external {
        accepting = value;
    }

    receive() external payable {
        require(accepting, "team unavailable");
    }
}

/// @dev Uses the real local v4 PoolManager. No storage writes or balance cheats on custody contracts.
/// @custom:x https://x.com/IaMaDamIMD
contract TreasuryHandler is Test {
    AdamTreasury public immutable treasury;
    AdamDistributor public immutable dist;
    InvariantTeamWallet public immutable team;
    MockTaxHook public immutable taxHook;
    MockERC20[2] public tokens;
    uint256 public funding;
    uint256 public splitTotal;
    uint256 public teamEntitlement;
    uint256[2] public allocated;
    uint256[2] public spent;
    uint256[2] public bought;
    uint256[2] public donated;
    uint256[2] public flushed;
    uint256 public successes;
    uint256 public failures;
    uint256 public clock;

    constructor(AdamTreasury t, AdamDistributor d, InvariantTeamWallet w, MockTaxHook h, MockERC20 t0, MockERC20 t1) {
        treasury = t;
        dist = d;
        team = w;
        taxHook = h;
        tokens = [t0, t1];
        clock = block.timestamp;
    }

    function fund(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(treasury).call{value: amount}("");
        assertTrue(ok);
        funding += amount;
    }

    function elapse(uint256 seconds_) public {
        clock += bound(seconds_, 0, 4 days);
        vm.warp(clock);
    }

    function market(uint256 tax, bool stopped) public {
        taxHook.setTaxBps(bound(tax, 0, 5000));
        taxHook.setRevertSwaps(stopped);
    }

    function teamAvailability(bool accepting) external {
        team.setAccepting(accepting);
    }

    function process(uint256 keeper) public {
        if (clock < uint256(treasury.lastProcessed()) + treasury.cooldown()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AdamTreasury.CooldownActive.selector, treasury.lastProcessed() + treasury.cooldown()
                )
            );
            vm.prank(address(uint160(0xB100 + keeper % 4)));
            treasury.process();
            return;
        }
        if (funding == splitTotal && allocated[0] == spent[0] && allocated[1] == spent[1]) {
            vm.expectRevert(AdamTreasury.NothingToProcess.selector);
            vm.prank(address(uint160(0xB100 + keeper % 4)));
            treasury.process();
            return;
        }
        vm.recordLogs();
        vm.prank(address(uint160(0xB100 + keeper % 4)));
        treasury.process();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[2] memory callSpend;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(treasury)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("Split(uint256,uint256,uint256)")) {
                (uint256 amount, uint256 teamShare, uint256 holders) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(teamShare, amount / 10, "fixed team share");
                assertEq(holders + teamShare, amount);
                assertLe(amount, 2 * treasury.maxEthPerBuy() * 10_000 / 9000, "split cap");
                splitTotal += amount;
                teamEntitlement += teamShare;
                allocated[0] += holders / 2;
                allocated[1] += holders - holders / 2;
            } else if (topic == keccak256("LegBought(uint8,address,uint256,uint256)")) {
                uint256 j = uint256(logs[i].topics[1]);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(tokens[j]));
                (uint256 ethIn, uint256 amountOut) = abi.decode(logs[i].data, (uint256, uint256));
                spent[j] += ethIn;
                bought[j] += amountOut;
                callSpend[j] += ethIn;
                ++successes;
            } else if (topic == keccak256("LegRerouted(uint8,uint8,uint256)")) {
                uint256 from = uint256(logs[i].topics[1]);
                uint256 to = uint256(logs[i].topics[2]);
                uint256 amount = abi.decode(logs[i].data, (uint256));
                allocated[from] -= amount;
                allocated[to] += amount;
            } else if (topic == keccak256("LegFailed(uint8,uint256,bytes)")) {
                ++failures;
            }
        }
        for (uint256 j; j < 2; ++j) {
            assertLe(callSpend[j], treasury.maxEthPerBuy(), "per-leg per-call cap");
            AdamTreasury.Leg memory l = treasury.leg(uint8(j));
            assertLe(l.failures, treasury.MIN_FAILURES());
            if (l.failures == 0) {
                assertEq(l.retryCap, 0);
                assertEq(l.failingSince, 0);
                assertEq(l.lastFailure, 0);
            } else {
                assertGe(l.retryCap, treasury.MIN_ETH_PER_BUY());
                assertLe(l.retryCap, treasury.maxEthPerBuy());
                assertLe(l.failingSince, l.lastFailure);
                assertLe(l.lastFailure, clock);
            }
        }
    }

    function payTeam(uint256 caller) external {
        if (treasury.teamOwed() == 0) vm.expectRevert(AdamTreasury.NothingOwed.selector);
        else if (!team.accepting()) vm.expectRevert(AdamTreasury.TeamTransferFailed.selector);
        vm.prank(address(uint160(0xB100 + caller % 4)));
        treasury.payTeam();
    }

    function donateReward(uint256 tokenSeed, uint256 amount) external {
        uint256 j = tokenSeed % 2;
        amount = bound(amount, 1, 1e24);
        tokens[j].mint(address(treasury), amount);
        donated[j] += amount;
    }

    function flush(uint256 caller) external {
        uint256[2] memory balances;
        for (uint256 j; j < 2; ++j) {
            balances[j] = tokens[j].balanceOf(address(treasury));
        }
        vm.prank(address(uint160(0xB100 + caller % 4)));
        treasury.flushRewards();
        for (uint256 j; j < 2; ++j) {
            flushed[j] += balances[j];
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
/// @custom:x https://x.com/IaMaDamIMD
contract TreasuryInvariantTest is LocalV4 {
    InvariantTeamWallet internal wallet;
    TreasuryHandler internal handler;
    uint256 internal initialManagerEth;

    function setUp() public override {
        super.setUp();
        wallet = new InvariantTeamWallet();
        treasury = new AdamTreasury(
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
            1 ether,
            300,
            COOLDOWN
        );
        initialManagerEth = address(poolManager).balance;
        handler = new TreasuryHandler(treasury, distributor, wallet, pnkstrHook, imd, pnkstr);
        // Seed a real buy, failed leg and deferred team payment, avoiding vacuous invariants.
        handler.market(1500, false);
        handler.fund(2 ether);
        handler.process(0);
        assertEq(handler.successes(), 1);
        assertEq(handler.failures(), 1);
        assertGt(treasury.teamOwed(), 0);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.elapse.selector;
        selectors[2] = handler.market.selector;
        selectors[3] = handler.teamAvailability.selector;
        selectors[4] = handler.process.selector;
        selectors[5] = handler.payTeam.selector;
        selectors[6] = handler.donateReward.selector;
        selectors[7] = handler.flush.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ethIsConservedAcrossIndependentCustodians() public view {
        uint256 poolReceipts = address(poolManager).balance - initialManagerEth;
        assertEq(poolReceipts, handler.spent(0) + handler.spent(1), "swap events must match real ETH receipts");
        assertEq(handler.funding(), address(treasury).balance + address(wallet).balance + poolReceipts);
        assertEq(address(wallet).balance + treasury.teamOwed(), handler.teamEntitlement());
        assertEq(treasury.unsplitEth(), handler.funding() - handler.splitTotal());
        for (uint8 j; j < 2; ++j) {
            assertEq(treasury.leg(j).pending, handler.allocated(j) - handler.spent(j));
        }
        assertEq(handler.splitTotal(), handler.teamEntitlement() + handler.allocated(0) + handler.allocated(1));
    }

    function invariant_rewardsReachDistributorWithoutUnbackedCredit() public view {
        for (uint256 j; j < 2; ++j) {
            MockERC20 token = j == 0 ? imd : pnkstr;
            assertEq(token.balanceOf(address(distributor)), handler.bought(j) + handler.flushed(j));
            assertEq(token.balanceOf(address(treasury)), handler.donated(j) - handler.flushed(j));
            assertEq(distributor.unallocated(address(token)), handler.bought(j) + handler.flushed(j));
            assertEq(token.allowance(address(treasury), address(distributor)), 0, "reward pull consumes approval");
        }
    }
}
