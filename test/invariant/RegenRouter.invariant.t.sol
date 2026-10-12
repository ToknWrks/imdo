// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegenRegistry} from "../../src/regen/RegenRegistry.sol";
import {RegenRouter} from "../../src/regen/RegenRouter.sol";
import {IPriceFeed} from "../../src/regen/interfaces/IEthToTokenSwap.sol";
import {MockUsdc, MockKvcm, MockPool, MockFeed, MockAggregator, MockVenue, MockCredit} from "../unit/RegenRouter.t.sol";

/// @dev Drives the router from several depositors over several projects while the world moves: the kVCM pool's spot
///      and average, the ETH/USDC fill, credit supply, retirement reverts, the feed, keepers that cannot take ETH.
///      Every `process` that reverts is a failed invariant run (fail-on-revert), except the router's own refusals,
///      which the handler avoids or expects.
contract RegenRouterHandler is Test {
    RegenRouter public router;
    RegenRegistry public reg;
    MockUsdc public usdc;
    MockPool public pool;
    MockFeed public feed;
    MockAggregator public agg;
    MockVenue public venue;
    address[3] public credits;
    address[3] public depositors;
    uint256 public constant PROJECTS = 2;

    uint256 public deposited;
    uint256 public swapped;
    uint256 public bounties;
    uint256 public retiredTonnes;
    uint256 public usdcBought;
    uint256 public usdcSpent;
    uint256 public skips;
    uint256 public processed;
    bool public rejectBounty;
    uint256 public clock;

    constructor(
        RegenRouter r,
        RegenRegistry g,
        MockUsdc u,
        MockPool p,
        MockFeed f,
        MockAggregator a,
        MockVenue v,
        address[3] memory c
    ) {
        router = r;
        reg = g;
        usdc = u;
        pool = p;
        feed = f;
        agg = a;
        venue = v;
        credits = c;
        depositors = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2")];
        clock = vm.getBlockTimestamp();
    }

    receive() external payable {
        require(!rejectBounty, "bounty");
        bounties += msg.value;
    }

    function deposit(uint8 who, uint8 project, uint96 amount) external {
        address d = depositors[who % 3];
        uint256 id = project % PROJECTS + 1;
        uint256 value = bound(amount, 1, 0.3 ether);
        vm.deal(d, value);
        vm.prank(d);
        router.deposit{value: value}(id);
        deposited += value;
    }

    function moveSpot(uint16 bps) external {
        pool.setSpot(1e18 * bound(bps, 2000, 13_000) / 10_000);
    }

    function moveAverage(uint16 bps) external {
        pool.setTwap(1e18 * bound(bps, 5000, 12_000) / 10_000);
    }

    function moveFill(uint16 bps) external {
        venue.setRate(2500e6 * bound(bps, 9500, 10_200) / 10_000);
    }

    function supply(uint8 which, uint64 tonnes) external {
        agg.setCredit(credits[which % 3], uint256(tonnes) * 1e12); // the vault's balance: 0 .. ~18k t
    }

    function overPull(uint8 which, bool on) external {
        agg.setOverPull(credits[which % 3], on);
    }

    function breakRetire(uint8 which, bool broken) external {
        agg.setRetireBroken(credits[which % 3], broken);
    }

    function roundUp(uint8 extra) external {
        pool.setRoundUpExtra(extra % 3);
    }

    function tick(uint32 elapsed, bool stale) external {
        clock += bound(elapsed, 1, 3 hours);
        vm.warp(clock);
        feed.set(2500e8, stale ? clock - 3601 : clock);
    }

    function process(uint8 who, uint8 project, bool reject) external {
        address d = depositors[who % 3];
        uint256 id = project % PROJECTS + 1;
        uint256 bal = router.balanceOf(id, d);
        if (bal == 0) return;
        if (clock < router.lastRetiredAt(id, d) + router.processInterval()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    RegenRouter.TooSoon.selector, router.lastRetiredAt(id, d) + router.processInterval()
                )
            );
            router.process(id, d);
            return;
        }
        rejectBounty = reject;
        uint256 ethIn = bal > router.maxBatch() ? router.maxBatch() : bal;
        uint256 bounty = ethIn >= router.minBatch() ? ethIn * router.bountyBps() / router.BPS() : 0;
        uint256 usdcBefore = usdc.balanceOf(address(router));
        uint256 retiredBefore = router.totalRetired();
        uint256 venueBefore = address(venue).balance;
        try router.process(id, d) {
            if (router.balanceOf(id, d) == bal) {
                ++skips; // Skipped: nothing moved
                require(usdc.balanceOf(address(router)) == usdcBefore, "skip moved usdc");
                require(router.totalRetired() == retiredBefore, "skip retired");
                return;
            }
            ++processed;
            swapped += address(venue).balance - venueBefore;
            uint256 bought = usdc.balanceOf(address(router)) + agg.lastSpent() - usdcBefore;
            usdcBought += bought;
            usdcSpent += agg.lastSpent();
            retiredTonnes += router.totalRetired() - retiredBefore;
            // the oracle floor on the ETH leg held
            require(bought >= router.minUsdcOut(ethIn - bounty, 2500e8), "under the oracle floor");
            if (reject) require(router.balanceOf(id, d) == bal - ethIn + bounty, "forfeit not re-credited");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            // the router's own refusals, all of which leave state untouched
            require(
                sel == RegenRouter.NothingRetired.selector || sel == RegenRouter.SwapShort.selector
                    || keccak256(err) == keccak256(abi.encodeWithSignature("Error(string)", "venue: min")),
                "unexpected revert"
            );
            require(router.balanceOf(id, d) == bal, "revert moved eth");
            require(usdc.balanceOf(address(router)) == usdcBefore, "revert moved usdc");
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RegenRouterInvariantTest is Test {
    RegenRouterHandler handler;
    RegenRouter router;
    MockUsdc usdc;
    MockAggregator agg;
    MockVenue venue;
    address[3] credits;

    function setUp() public {
        vm.warp(1_800_000_000);
        RegenRegistry reg = new RegenRegistry("", "", address(0));
        usdc = new MockUsdc();
        MockKvcm kvcm = new MockKvcm();
        MockPool pool = new MockPool(address(kvcm), address(usdc));
        MockFeed feed = new MockFeed();
        venue = new MockVenue(usdc, 2500e6);
        credits = [address(new MockCredit("A")), address(new MockCredit("B")), address(new MockCredit("C"))];
        address vault = makeAddr("vault");
        agg = new MockAggregator(usdc, address(kvcm), pool, vault, 22e18);
        router = new RegenRouter(
            RegenRouter.Config({
                registry: reg,
                aggregator: agg,
                usdc: IERC20(address(usdc)),
                kvcm: IERC20(address(kvcm)),
                kvcmPool: pool,
                classVault: vault,
                creditA: credits[0],
                creditB: credits[1],
                creditC: credits[2],
                venue: venue,
                ethUsd: feed,
                sequencerUptime: IPriceFeed(address(0)),
                maxFeedAge: 3600,
                minBatch: 0.001 ether,
                maxBatch: 0.05 ether,
                bountyBps: 50,
                minOutBps: 9700,
                twapGranularity: 4,
                minTonnesBps: 9700,
                maxUsdcPerTonne: 45e6,
                processInterval: 7200
            })
        );
        reg.register("IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan", makeAddr("imdo-safe"));
        reg.register("Other", "regen1r23clxd5mzfsh79vn6pg0kaytjeq8w4usu4zh8", makeAddr("other-safe"));
        for (uint256 i; i < 3; ++i) {
            agg.setCredit(credits[i], 1000e18);
        }
        handler = new RegenRouterHandler(router, reg, usdc, pool, feed, agg, venue, credits);
        targetContract(address(handler));
    }

    /// @dev The handler really processes (not only skips), so the invariants above are exercised.
    function test_handlerProcessesAndSkips() public {
        handler.deposit(0, 0, 0.01 ether);
        handler.process(0, 0, false);
        assertEq(handler.processed(), 1);
        assertGt(handler.retiredTonnes(), 0);
        handler.process(0, 0, false); // too soon: expected revert, nothing moved
        assertEq(handler.processed(), 1);
        handler.deposit(1, 1, 0.01 ether);
        handler.moveSpot(2000);
        handler.process(1, 1, false);
        assertEq(handler.skips(), 1);
        handler.moveSpot(10_000);
        handler.breakRetire(0, true);
        handler.breakRetire(1, true);
        handler.breakRetire(2, true);
        handler.process(1, 1, true); // NothingRetired, caught: nothing moved
        assertEq(handler.processed(), 1);
        handler.breakRetire(0, false);
        handler.process(1, 1, true); // keeper that cannot take ETH: bounty re-credited
        assertEq(handler.processed(), 2);
        handler.tick(7200, false);
        handler.process(1, 1, false); // the re-credited remainder, no bounty
        assertEq(handler.processed(), 3);
        invariant_ethIsConserved();
        invariant_usdcIsConservedAndAttributed();
        invariant_tonnesAreCountedOnce();
    }

    /// @dev Every wei deposited is still in the router, went to the venue as a swap, or was paid as a bounty.
    function invariant_ethIsConserved() public view {
        assertEq(handler.deposited(), address(router).balance + handler.swapped() + handler.bounties());
    }

    /// @dev The router's ETH is exactly the sum of what depositors are owed.
    function invariant_routerEthIsTheSumOfBalances() public view {
        uint256 sum;
        for (uint256 p = 1; p <= handler.PROJECTS(); ++p) {
            for (uint256 i; i < 3; ++i) {
                sum += router.balanceOf(p, handler.depositors(i));
            }
        }
        assertEq(address(router).balance, sum);
    }

    /// @dev Dollars bought either went to the aggregator or sit here attributed to a project; nothing else.
    function invariant_usdcIsConservedAndAttributed() public view {
        uint256 carried;
        for (uint256 p = 1; p <= handler.PROJECTS(); ++p) {
            for (uint256 i; i < 3; ++i) {
                carried += router.usdcOf(p, handler.depositors(i));
            }
        }
        assertEq(usdc.balanceOf(address(router)), carried);
        assertEq(handler.usdcBought(), handler.usdcSpent() + carried);
        assertEq(usdc.balanceOf(address(agg)), handler.usdcSpent());
    }

    /// @dev Tonnes are counted once, per project and in total, and every retirement is whole steps of a tonne.
    function invariant_tonnesAreCountedOnce() public view {
        uint256 sum;
        for (uint256 p = 1; p <= handler.PROJECTS(); ++p) {
            sum += router.retiredOf(p);
        }
        assertEq(router.totalRetired(), sum);
        assertEq(router.totalRetired(), handler.retiredTonnes());
        assertEq(router.totalRetired() % router.TONNE_STEP(), 0);
    }

    /// @dev No allowance is left behind for the aggregator between calls.
    function invariant_noStandingAllowance() public view {
        assertEq(usdc.allowance(address(router), address(agg)), 0);
    }
}
