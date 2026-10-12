// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegenRegistry} from "../../src/regen/RegenRegistry.sol";
import {RegenRouter} from "../../src/regen/RegenRouter.sol";
import {RegenReceiver, RegenReceiverFactory} from "../../src/regen/RegenReceiver.sol";
import {
    IKlimaRetirementAggregator,
    RetireDetails,
    DiscountedForwardBalanceContext,
    UpdateLiquidSupplyRateLimiterParams
} from "../../src/regen/interfaces/IKlimaRetirementAggregator.sol";
import {IEthToTokenSwap, IPriceFeed} from "../../src/regen/interfaces/IEthToTokenSwap.sol";
import {IAerodromePool} from "../../src/regen/interfaces/IAerodromePool.sol";

contract MockUsdc is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockKvcm is ERC20 {
    constructor() ERC20("kVCM", "kVCM") {}
}

contract MockFeed is IPriceFeed {
    int256 public answer = 2500e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev The USDC/kVCM pool as the aggregator and the router see it: a SPOT rate (what a swap pays right now, movable
///      within a transaction) and a TIME-WEIGHTED rate (what `quote` answers, movable only across observations). Both
///      are kVCM (1e18) per USDC (1e6); the pool's own fee is left out of both, as on the real pool's `quote`.
contract MockPool is IAerodromePool {
    address public token0;
    address public token1;
    uint256 public spot = 1e18;
    uint256 public twap = 1e18;
    uint256 public roundUpExtra;
    bool public quoteBroken;

    constructor(address kvcm, address usdc) {
        token0 = kvcm;
        token1 = usdc;
    }

    function setSpot(uint256 s) external {
        spot = s;
    }

    function setTwap(uint256 t) external {
        twap = t;
    }

    function setRoundUpExtra(uint256 e) external {
        roundUpExtra = e;
    }

    function setQuoteBroken(bool b) external {
        quoteBroken = b;
    }

    function getAmountOut(uint256 usdcIn) external view returns (uint256) {
        return usdcIn * spot / 1e6;
    }

    function getAmountIn(uint256 kvcmOut) external view returns (uint256) {
        return (kvcmOut * 1e6 + spot - 1) / spot + roundUpExtra;
    }

    function quote(address tokenIn, uint256 amountIn, uint256) external view returns (uint256) {
        require(!quoteBroken, "pool: quote");
        require(tokenIn == token1, "pool: tokenIn");
        return amountIn * twap / 1e6;
    }
}

/// @dev Honest venue: USDC per ETH `fillRate` (6 dec), enforces minOut like a real pool. Can re-enter the router or
///      pump the kVCM pool during the swap, to stand in for anything that runs between the plan and the retirement.
contract MockVenue is IEthToTokenSwap {
    MockUsdc public token;
    uint256 public fillRate;
    RegenRouter public reenter;
    MockPool public pumpPool;
    uint256 public pumpSpot;

    constructor(MockUsdc t, uint256 rate) {
        token = t;
        fillRate = rate;
    }

    function setRate(uint256 f) external {
        fillRate = f;
    }

    function setReenter(RegenRouter r) external {
        reenter = r;
    }

    function setPump(MockPool p, uint256 s) external {
        pumpPool = p;
        pumpSpot = s;
    }

    function swapEthToToken(address, uint256 minOut, address to) external payable returns (uint256 out) {
        if (address(reenter) != address(0)) reenter.process(1, address(0xD0));
        if (address(pumpPool) != address(0)) pumpPool.setSpot(pumpSpot);
        out = msg.value * fillRate / 1e18;
        require(out >= minOut, "venue: min");
        token.mint(to, out);
    }
}

/// @dev Ignores minOut and under-delivers: the router's own balance check must catch it.
contract LyingVenue is IEthToTokenSwap {
    function swapEthToToken(address, uint256, address) external payable returns (uint256) {
        return 0;
    }
}

contract NoReceive {
    function run(RegenRouter r, uint256 id, address d) external {
        r.process(id, d);
    }
}

/// @dev Klima stand-in. USDC is turned into kVCM at the pool's SPOT (that is what the real aggregator does), kVCM
///      retires at `kvcmPerTonne` (18 dec, Klima's own curve), supply per credit token caps a quote, the USDC it asks
///      for is rounded up, and it pulls USDC from the caller.
contract MockAggregator is IKlimaRetirementAggregator {
    MockUsdc public usdc;
    address public kvcm;
    MockPool public pool;
    uint256 public kvcmPerTonne;
    mapping(address => uint256) public supply;
    mapping(address => bool) public supported;
    mapping(address => bool) public retireBroken;
    RetireDetails public last;
    address public lastCredit;
    uint256 public lastTonnes;
    uint256 public retirements;

    error TokenNotSupported();
    error SlippageExceeded(uint256 required, uint256 maxAllowed);
    error InvalidAmountReceived();

    constructor(MockUsdc u, address k, MockPool p, uint256 perTonne) {
        usdc = u;
        kvcm = k;
        pool = p;
        kvcmPerTonne = perTonne;
    }

    function setCredit(address c, uint256 tonnes) external {
        supported[c] = true;
        supply[c] = tonnes;
    }

    function setRetireBroken(address c, bool b) external {
        retireBroken[c] = b;
    }

    function quoteRetireCreditForInputTokenInViaKlima(
        address creditToken,
        uint256,
        uint256 amount,
        address inputToken,
        address,
        uint256
    )
        external
        view
        returns (
            uint256 tonnes,
            uint256,
            uint256,
            DiscountedForwardBalanceContext memory d,
            UpdateLiquidSupplyRateLimiterParams memory u
        )
    {
        if (!supported[creditToken]) revert TokenNotSupported();
        uint256 kvcmIn = inputToken == address(usdc) ? pool.getAmountOut(amount) : amount;
        tonnes = kvcmIn * 1e18 / kvcmPerTonne;
        if (tonnes > supply[creditToken]) tonnes = supply[creditToken];
        return (tonnes, amount, 0, d, u);
    }

    function quoteRetireCreditViaKlima(
        address creditToken,
        uint256,
        uint256 tonnes,
        address inputToken,
        address,
        uint256
    )
        external
        view
        returns (
            uint256,
            uint256,
            DiscountedForwardBalanceContext memory d,
            UpdateLiquidSupplyRateLimiterParams memory u
        )
    {
        if (!supported[creditToken] || tonnes > supply[creditToken]) {
            revert TokenNotSupported();
        }
        return (tonnes, _cost(tonnes, inputToken), d, u);
    }

    function retireCreditViaKlima(
        address creditToken,
        uint256,
        uint256,
        uint256 tonnes,
        address inputToken,
        address,
        uint256 maxIn,
        uint256,
        RetireDetails memory details
    ) external {
        if (!supported[creditToken] || tonnes > supply[creditToken]) revert TokenNotSupported();
        if (retireBroken[creditToken]) revert InvalidAmountReceived();
        uint256 cost = _cost(tonnes, inputToken);
        if (cost > maxIn) revert SlippageExceeded(cost, maxIn);
        require(usdc.transferFrom(msg.sender, address(this), cost), "pull");
        supply[creditToken] -= tonnes;
        last = details;
        lastCredit = creditToken;
        lastTonnes = tonnes;
        ++retirements;
    }

    function _cost(uint256 tonnes, address inputToken) private view returns (uint256) {
        uint256 kvcmNeeded = (tonnes * kvcmPerTonne + 1e18 - 1) / 1e18;
        return inputToken == address(usdc) ? pool.getAmountIn(kvcmNeeded) : kvcmNeeded;
    }
}

contract RegenRouterTest is Test {
    RegenRegistry internal reg;
    MockUsdc internal usdc;
    MockKvcm internal kvcm;
    MockPool internal pool;
    MockFeed internal feed;
    MockAggregator internal agg;
    MockVenue internal venue;
    RegenRouter internal router;
    RegenReceiverFactory internal factory;

    address internal creditA = makeAddr("C02-004");
    address internal creditB = makeAddr("C02-003");
    address internal creditC = makeAddr("C02-006");
    address internal vault = makeAddr("class-vault");
    address internal beneficiary = makeAddr("imdo-safe");
    address internal depositor = makeAddr("pot-safe");
    address internal keeper = makeAddr("keeper");
    string internal constant REGEN = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan";

    uint256 internal constant RATE = 2500e6; // USDC per ETH, equal to the oracle
    /// @dev 22 kVCM per tonne; the pool pays 1 kVCM per USDC, so a tonne costs 22 USDC.
    uint256 internal constant PER_TONNE = 22e18;

    /// @dev The test contract calls `process` directly in most tests and must be able to take the bounty.
    receive() external payable {}

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new RegenRegistry();
        usdc = new MockUsdc();
        kvcm = new MockKvcm();
        pool = new MockPool(address(kvcm), address(usdc));
        feed = new MockFeed();
        feed.set(2500e8, block.timestamp);
        agg = new MockAggregator(usdc, address(kvcm), pool, PER_TONNE);
        venue = new MockVenue(usdc, RATE);
        router = new RegenRouter(_config(0.001 ether, 0.02 ether, 100, 9700));
        factory = new RegenReceiverFactory(router);
        reg.register("IMDO", REGEN, beneficiary);
        agg.setCredit(creditA, 1000e18);
        agg.setCredit(creditB, 1000e18);
        agg.setCredit(creditC, 1000e18);
        vm.deal(depositor, 10 ether);
    }

    function _config(uint256 minB, uint256 maxB, uint256 bounty, uint256 minOut)
        internal
        view
        returns (RegenRouter.Config memory c)
    {
        c = RegenRouter.Config({
            registry: reg,
            aggregator: agg,
            usdc: IERC20(address(usdc)),
            kvcm: IERC20(address(kvcm)),
            kvcmPool: pool,
            classVault: vault,
            creditA: creditA,
            creditB: creditB,
            creditC: creditC,
            venue: venue,
            ethUsd: feed,
            maxFeedAge: 3600,
            minBatch: minB,
            maxBatch: maxB,
            bountyBps: bounty,
            minOutBps: minOut,
            twapGranularity: 4,
            minTonnesBps: 9700
        });
    }

    function _deposit(uint256 amount) internal {
        vm.prank(depositor);
        router.deposit{value: amount}(1);
    }

    // ---- deposits -------------------------------------------------------------------------------------------------

    function test_depositNeedsAProjectAndValue() public {
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.UnknownProject.selector, 2));
        router.deposit{value: 1}(2);
        vm.expectRevert(RegenRouter.ZeroDeposit.selector);
        router.deposit(1);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Deposited(1, depositor, 0.5 ether);
        _deposit(0.5 ether);
        assertEq(router.balanceOf(1, depositor), 0.5 ether);
        assertTrue(router.projectExists(1));
        assertFalse(router.projectExists(2));
    }

    function test_plainEthIsRefused() public {
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---- process ---------------------------------------------------------------------------------------------------

    function test_processRetiresWithTheProjectAsBeneficiary() public {
        _deposit(0.01 ether);
        vm.prank(keeper);
        router.process(1, depositor);

        // 1% bounty, 0.0099 ETH swapped at 2500 → 24.75 USDC → 1.125 t at 22 USDC/t
        assertEq(keeper.balance, 0.0001 ether);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(agg.lastCredit(), creditA);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(router.retiredOf(1), 1.125e18);
        assertEq(router.totalRetired(), 1.125e18);
        assertEq(usdc.allowance(address(router), address(agg)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(router.usdcOf(1), 0);

        (address ra, string memory res, address ba, string memory bs, string memory msg_,,,,) = agg.last();
        assertEq(ra, address(router));
        assertEq(res, "Regen Retirement Router");
        assertEq(ba, beneficiary);
        assertEq(bs, "IMDO");
        assertEq(
            msg_,
            string.concat(
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:",
                REGEN,
                " | src:8453:",
                _lower(depositor)
            )
        );
    }

    function test_messageIsGrammarV1ByteForByte() public view {
        RegenRegistry.Project memory p = reg.project(1);
        string memory m = router.message(1, p, 0x55bEb053c003F98c1059F2a497132CBA72104a03);
        assertEq(
            m,
            "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03"
        );
        assertLe(bytes(m).length, 512);
        p.name = "A name with spaces & 64 bytes max";
        m = router.message(123456, p, address(0));
        assertEq(
            m,
            "regen-klima-retire | mode:hook | project:123456 | name:A name with spaces & 64 bytes max | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x0000000000000000000000000000000000000000"
        );
    }

    function test_batchIsCappedAndTheRestWaits() public {
        _deposit(0.05 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.03 ether);
        assertEq(keeper.balance, 0.0002 ether); // 1% of 0.02
        vm.prank(keeper);
        router.process(1, depositor);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(agg.retirements(), 3);
    }

    function test_aRemainderUnderMinBatchIsProcessedWithNoBounty() public {
        _deposit(0.0009 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(keeper.balance, 0);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(agg.lastTonnes(), 0.102272e18); // 0.0009 ETH × 2500 = 2.25 USDC / 22, floored to a step
        // the slice after the last full batch, too
        _deposit(0.0205 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.0005 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(keeper.balance, 0.0002 ether); // the full batch's bounty only
    }

    function test_nothingToProcessReverts() public {
        vm.expectRevert(RegenRouter.NothingToProcess.selector);
        router.process(1, makeAddr("nobody"));
        vm.expectRevert(abi.encodeWithSelector(RegenRegistry.UnknownProject.selector, 9));
        router.process(9, depositor);
    }

    function test_emptyClassSkipsAndKeepsTheEth() public {
        agg.setCredit(creditA, 0);
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        _deposit(0.01 ether);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "classEmpty");
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
        assertEq(address(router).balance, 0.01 ether);
        assertEq(keeper.balance, 0);
        assertEq(agg.retirements(), 0);
        assertEq(usdc.balanceOf(address(router)), 0); // nothing was swapped
    }

    function test_creditTokensFallThroughInOrder() public {
        agg.setCredit(creditA, 0);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        agg.setCredit(creditB, 0);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditC);
    }

    function test_anUnsupportedTokenIsSkippedNotFatal() public {
        MockAggregator a2 = new MockAggregator(usdc, address(kvcm), pool, PER_TONNE);
        a2.setCredit(creditC, 10e18); // A and B never registered: the quote reverts TokenNotSupported
        agg = a2;
        router = new RegenRouter(_config(0.001 ether, 0.02 ether, 100, 9700));
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(a2.lastCredit(), creditC);
    }

    function test_aCreditWhoseRetirementRevertsIsPassedOver() public {
        agg.setRetireBroken(creditA, true); // quotes fine (1 wei of it sits on the diamond), retire reverts
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(usdc.allowance(address(router), address(agg)), 0);
    }

    function test_whenEveryRetirementRevertsTheBatchRevertsAndTheEthStays() public {
        agg.setRetireBroken(creditA, true);
        agg.setRetireBroken(creditB, true);
        agg.setRetireBroken(creditC, true);
        _deposit(0.01 ether);
        vm.expectRevert(RegenRouter.NothingRetired.selector);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_dustCarriesToTheNextBatchOfTheSameProject() public {
        // 24.75 USDC at 23/t = 1.076086956… t, floored to 1.076086 t → spends 24.749978, 22 micro-USDC dust
        agg = new MockAggregator(usdc, address(kvcm), pool, 23e18);
        agg.setCredit(creditA, 1000e18);
        router = new RegenRouter(_config(0.001 ether, 0.02 ether, 100, 9700));
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(usdc.balanceOf(address(router)), 22);
        assertEq(router.usdcOf(1), 22);
        assertEq(agg.lastTonnes(), 1.076086e18);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertLt(router.usdcOf(1), 24); // under one six-decimal step's worth of USDC
        assertEq(usdc.balanceOf(address(router)), router.usdcOf(1));
    }

    function test_theAggregatorsRoundUpIsGivenAStepOfSlack() public {
        pool.setRoundUpExtra(1); // the aggregator asks one micro-USDC more than the quote implies
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 1.124999e18); // one step under 1.125 t, instead of SlippageExceeded
        assertEq(router.usdcOf(1), 24.75e6 - 24_749_979);
    }

    // ---- the ETH leg: oracle ceiling ------------------------------------------------------------------------------

    function test_aSandwichedSwapIsRefusedAtTheCeiling() public {
        _deposit(0.01 ether);
        venue.setRate(RATE * 96 / 100); // pool 4% under the oracle
        vm.expectRevert("venue: min");
        router.process(1, depositor);
        venue.setRate(RATE * 975 / 1000); // 2.5% under: inside the 3% ceiling
        router.process(1, depositor);
    }

    function test_theBarIsTheOracleNotThePool() public {
        _deposit(0.01 ether);
        // an attacker who pushes the pool down 10% lowers what the venue pays, never what the router demands
        venue.setRate(RATE * 90 / 100);
        vm.expectRevert("venue: min");
        router.process(1, depositor);
    }

    function test_theRouterChecksTheFillItselfNotJustTheVenue() public {
        RegenRouter.Config memory c = _config(0.001 ether, 0.02 ether, 100, 9700);
        c.venue = new LyingVenue();
        RegenRouter r2 = new RegenRouter(c);
        vm.prank(depositor);
        r2.deposit{value: 0.01 ether}(1);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.SwapShort.selector, 0, 24.75e6 * 9700 / 10000));
        r2.process(1, depositor);
    }

    function test_staleOrBrokenFeedSkipsAndKeepsTheEth() public {
        _deposit(0.01 ether);
        feed.set(2500e8, block.timestamp - 3601);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "feedStale");
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
        feed.set(0, block.timestamp);
        router.process(1, depositor);
        feed.set(-1, block.timestamp);
        router.process(1, depositor);
        feed.set(2500e8, block.timestamp + 1); // dated in the future: a skip, not a panic
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "feedStale");
        router.process(1, depositor);
        assertEq(agg.retirements(), 0);
        feed.set(2500e8, block.timestamp);
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
    }

    function test_minOutFollowsTheOracle() public view {
        assertEq(router.minUsdcOut(1 ether, 2500e8), 2425e6); // 97% of $2,500
        assertEq(router.minUsdcOut(0.0099 ether, 3000e8), 28.809e6);
    }

    // ---- the credit leg: time-weighted bar ------------------------------------------------------------------------

    function test_aPumpedKvcmPoolIsSkippedBeforeAnythingIsSpent() public {
        _deposit(0.01 ether);
        pool.setSpot(0.5e18); // the caller bought kVCM first: a dollar now buys half as much
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(keeper.balance, 0);
        assertEq(agg.retirements(), 0);
        // a view says the same
        RegenRouter.Plan memory p = router.plan(24.75e6);
        assertEq(p.credit, address(0));
        assertEq(p.reason, bytes32("priceOff"));
    }

    function test_theBarIsTheTimeWeightedPriceWithinTheTolerance() public {
        _deposit(0.03 ether);
        pool.setSpot(0.96e18); // 4% under the average
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
        router.process(1, depositor);
        pool.setSpot(0.98e18); // 2% under: inside the bar
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 2.205e18); // 0.0198 ETH → 49.5 USDC × 0.98 / 22
        pool.setSpot(1.1e18); // better than the average is always fine
        router.process(1, depositor);
        assertEq(agg.retirements(), 2);
    }

    function test_aPoolMovedBetweenThePlanAndTheRetirementRevertsTheBatch() public {
        _deposit(0.01 ether);
        venue.setPump(pool, 0.5e18); // the price moves while the ETH leg runs
        vm.expectRevert(RegenRouter.NothingRetired.selector);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
    }

    function test_anAverageMovedWithThePriceIsTheDocumentedLimit() public {
        _deposit(0.01 ether);
        pool.setSpot(0.5e18);
        pool.setTwap(0.5e18); // held there for the whole window
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 0.5625e18);
    }

    function test_aBrokenPoolQuoteSkips() public {
        _deposit(0.01 ether);
        pool.setQuoteBroken(true);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
    }

    function test_referenceTonnesIsTheAverageAtTheAggregatorsRate() public {
        assertEq(router.referenceTonnes(creditA, 22e6), 1e18);
        pool.setTwap(2e18);
        assertEq(router.referenceTonnes(creditA, 22e6), 2e18);
        pool.setSpot(0.1e18); // the spot plays no part
        assertEq(router.referenceTonnes(creditA, 22e6), 2e18);
    }

    // ---- the project's own dollars ---------------------------------------------------------------------------------

    function test_aPartialAbsorptionStaysWithTheProject() public {
        reg.register("Other", REGEN, makeAddr("other-safe"));
        address other = makeAddr("other-depositor");
        vm.deal(other, 1 ether);
        agg.setCredit(creditA, 0.5e18); // credit A can take 0.5 t of the 1.125 t batch
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditA);
        assertEq(agg.lastTonnes(), 0.5e18);
        assertEq(router.usdcOf(1), 24.75e6 - 11e6);
        // another project's batch retires only its own dollars
        vm.prank(other);
        router.deposit{value: 0.01 ether}(2);
        router.process(2, other);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(router.retiredOf(2), 1.125e18);
        assertEq(router.usdcOf(1), 13.75e6);
        assertEq(router.usdcOf(2), 0);
        // the project's next batch spends its remainder, from the next credit
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 1.75e18); // (13.75 + 24.75) / 22
        assertEq(router.usdcOf(1), 0);
        assertEq(router.retiredOf(1), 2.25e18);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_aRemainderAloneCanBeRetiredWithTheNextSlice() public {
        agg.setCredit(creditA, 0.5e18);
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(router.usdcOf(1), 13.75e6);
        agg.setCredit(creditB, 1000e18);
        _deposit(0.0001 ether); // a sliver of ETH is enough to carry the remainder into a retirement
        router.process(1, depositor);
        assertLt(router.usdcOf(1), 23); // rounding only
        assertEq(agg.lastTonnes(), 0.636363e18); // (13.75 + 0.25) / 22, floored
    }

    function test_donatedUsdcBelongsToNobody() public {
        usdc.mint(address(router), 1000e6);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(usdc.balanceOf(address(router)), 1000e6);
        assertEq(router.usdcOf(1), 0);
    }

    // ---- bounty ----------------------------------------------------------------------------------------------------

    function test_aCallerThatCannotTakeEthForfeitsTheBounty() public {
        _deposit(0.01 ether);
        NoReceive caller = new NoReceive();
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.BountyForfeited(1, address(caller), 0.0001 ether);
        caller.run(router, 1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.0001 ether);
        assertEq(address(router).balance, 0.0001 ether);
        // the forfeited slice is under minBatch; anyone retires it, for no bounty
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(keeper.balance, 0);
        assertEq(agg.retirements(), 2);
    }

    function test_reentryFromTheVenueIsRefused() public {
        _deposit(0.03 ether);
        venue.setReenter(router);
        vm.expectRevert();
        router.process(1, depositor);
    }

    // ---- end to end with a receiver ------------------------------------------------------------------------------

    function test_bridgedEthNamesTheReceiverAsSource() public {
        address rcv = factory.deploy(1);
        vm.deal(rcv, 0.01 ether);
        RegenReceiver(payable(rcv)).forward();
        assertEq(router.balanceOf(1, rcv), 0.01 ether);
        router.process(1, rcv);
        (,,,, string memory m,,,,) = agg.last();
        assertEq(
            m,
            string.concat(
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:", REGEN, " | src:8453:", _lower(rcv)
            )
        );
    }

    // ---- construction ----------------------------------------------------------------------------------------------

    function test_constructorBounds() public {
        RegenRouter.Config memory c = _config(0, 1, 100, 9700);
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(2, 1, 100, 9700);
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 10_000, 9700);
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 0);
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 10_001);
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.maxFeedAge = 0;
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.twapGranularity = 0;
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.minTonnesBps = 0;
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.minTonnesBps = 10_001;
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.kvcmPool = new MockPool(address(kvcm), makeAddr("not-usdc")); // a pool of some other pair
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.kvcmPool = new MockPool(address(usdc), address(kvcm)); // either order is fine
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.creditB = address(0);
        vm.expectRevert(RegenRouter.ZeroAddress.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.kvcm = IERC20(address(0));
        vm.expectRevert(RegenRouter.ZeroAddress.selector);
        new RegenRouter(c);
    }

    // ---- fuzz: ETH is conserved -----------------------------------------------------------------------------------

    function testFuzz_ethConservation(uint96 amount, uint8 rounds) public {
        amount = uint96(bound(amount, 0.001 ether, 1 ether));
        rounds = uint8(bound(rounds, 1, 12));
        vm.deal(depositor, amount);
        _deposit(amount);
        uint256 swapped;
        uint256 bounties;
        for (uint256 i; i < rounds; ++i) {
            uint256 bal = router.balanceOf(1, depositor);
            if (bal == 0) break;
            uint256 ethIn = bal > 0.02 ether ? 0.02 ether : bal;
            uint256 bounty = ethIn >= 0.001 ether ? ethIn * 100 / 10_000 : 0;
            uint256 before = keeper.balance;
            vm.prank(keeper);
            router.process(1, depositor);
            if (router.balanceOf(1, depositor) == bal) break; // skipped: a sliver too small to retire a step
            bounties += keeper.balance - before;
            swapped += ethIn - bounty;
        }
        assertEq(address(router).balance, router.balanceOf(1, depositor));
        assertEq(uint256(amount), address(router).balance + swapped + bounties);
    }

    function _lower(address a) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory b = new bytes(42);
        b[0] = "0";
        b[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 41; i > 1; --i) {
            b[i] = alphabet[v & 0xf];
            v >>= 4;
        }
        return string(b);
    }
}
