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
import {IEthToTokenSwap, IPriceFeed, IPriceFeedAggregator} from "../../src/regen/interfaces/IEthToTokenSwap.sol";
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

/// @dev A credit token (18 dec = tonnes). The class vault holds the retirable supply; anyone may mint or burn here.
contract MockCredit is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function burn(address from, uint256 a) external {
        _burn(from, a);
    }
}

contract MockAeroFactory {
    uint256 public fee = 30;

    function setFee(uint256 f) external {
        fee = f;
    }

    function getFee(address, bool) external view returns (uint256) {
        return fee;
    }
}

/// @dev The aggregator behind a Chainlink proxy, with its clamp.
contract MockClamp is IPriceFeedAggregator {
    int192 public minAnswer = 1;
    int192 public maxAnswer = type(int192).max;

    function set(int192 lo, int192 hi) external {
        minAnswer = lo;
        maxAnswer = hi;
    }
}

/// @dev A Chainlink proxy: ETH/USD by default; also stands in for the sequencer uptime feed (answer 0/1, startedAt).
contract MockFeed is IPriceFeed {
    int256 public answer = 2500e8;
    uint256 public startedAt;
    uint256 public updatedAt;
    MockClamp public clamp;
    address public clampAddress;
    bool public noAggregator;

    constructor() {
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
        clamp = new MockClamp();
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        startedAt = t;
    }

    function setNoAggregator(bool b) external {
        noAggregator = b;
    }

    function setAggregatorAddress(address a) external {
        clampAddress = a;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }

    function aggregator() external view returns (IPriceFeedAggregator) {
        require(!noAggregator, "no aggregator");
        return clampAddress != address(0) ? IPriceFeedAggregator(clampAddress) : clamp;
    }
}

/// @dev The USDC/kVCM pool as the aggregator and the router see it: a SPOT rate (what a swap pays right now, movable
///      within a transaction) and a TIME-WEIGHTED rate (what `quote` answers, movable only across observations). Both
///      are kVCM (1e18) per USDC (1e6); the pool's own fee is left out of both, as on the real pool's `quote`.
contract MockPool is IAerodromePool {
    address public token0;
    address public token1;
    MockAeroFactory public aeroFactory;
    uint256 public spot = 1e18;
    uint256 public twap = 1e18;
    uint256 public roundUpExtra;
    bool public quoteBroken;

    constructor(address kvcm, address usdc) {
        token0 = kvcm;
        token1 = usdc;
        aeroFactory = new MockAeroFactory();
    }

    function stable() external pure returns (bool) {
        return false;
    }

    function factory() external view returns (address) {
        return address(aeroFactory);
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

/// @dev Klima stand-in, shaped like the chain: USDC is turned into kVCM at the pool's SPOT, kVCM retires at
///      `kvcmPerTonne` (18 dec, Klima's own curve), a QUOTE never looks at the vault (the real one quotes its curve
///      regardless), a RETIREMENT burns the credit from the class vault and reverts when the vault is short, the USDC
///      it asks for is rounded up, and it pulls USDC from the caller. `setCredit(c, t)` sets the vault's balance.
contract MockAggregator is IKlimaRetirementAggregator {
    MockUsdc public usdc;
    address public kvcm;
    MockPool public pool;
    address public vault;
    uint256 public kvcmPerTonne;
    mapping(address => bool) public supported;
    mapping(address => bool) public retireBroken;
    mapping(address => bool) public overPull;
    /// @dev The live quoter caps a dollar-budget quote at the class's liquid tonnes; the mock's default is the bare curve.
    bool public capAtVault;
    RetireDetails public last;
    address public lastCredit;
    uint256 public lastTonnes;
    uint256 public lastSpent;
    uint256 public retirements;

    error TokenNotSupported();
    error SlippageExceeded(uint256 required, uint256 maxAllowed);
    error InvalidAmountReceived();
    error InsufficientCredit();

    constructor(MockUsdc u, address k, MockPool p, address v, uint256 perTonne) {
        usdc = u;
        kvcm = k;
        pool = p;
        vault = v;
        kvcmPerTonne = perTonne;
    }

    /// @dev Makes `c` a known credit whose vault balance is `tonnes`.
    function setCredit(address c, uint256 tonnes) external {
        supported[c] = true;
        uint256 have = MockCredit(c).balanceOf(vault);
        if (tonnes > have) MockCredit(c).mint(vault, tonnes - have);
        else if (have > tonnes) MockCredit(c).burn(vault, have - tonnes);
    }

    function supply(address c) external view returns (uint256) {
        return MockCredit(c).balanceOf(vault);
    }

    function setRetireBroken(address c, bool b) external {
        retireBroken[c] = b;
    }

    /// @dev The execution path prices unlike the quote path (an upgraded diamond): pulls twice the quoted USDC.
    function setOverPull(address c, bool b) external {
        overPull[c] = b;
    }

    function setCapAtVault(bool b) external {
        capAtVault = b;
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
        tonnes = kvcmIn * 1e18 / kvcmPerTonne; // the curve, whatever the vault holds
        if (capAtVault) {
            uint256 have = MockCredit(creditToken).balanceOf(vault);
            if (tonnes > have) tonnes = have;
        }
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
        if (!supported[creditToken]) revert TokenNotSupported();
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
        if (!supported[creditToken]) revert TokenNotSupported();
        if (retireBroken[creditToken]) revert InvalidAmountReceived();
        if (MockCredit(creditToken).balanceOf(vault) < tonnes) revert InsufficientCredit();
        uint256 cost = _cost(tonnes, inputToken);
        if (overPull[creditToken]) cost *= 2;
        if (cost > maxIn) revert SlippageExceeded(cost, maxIn);
        require(usdc.transferFrom(msg.sender, address(this), cost), "pull");
        MockCredit(creditToken).burn(vault, tonnes);
        last = details;
        lastCredit = creditToken;
        lastTonnes = tonnes;
        lastSpent = cost;
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

    address internal creditA;
    address internal creditB;
    address internal creditC;
    address internal vault = makeAddr("class-vault");
    address internal beneficiary = makeAddr("imdo-safe");
    address internal depositor = makeAddr("pot-safe");
    address internal keeper = makeAddr("keeper");
    string internal constant REGEN = "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan";

    uint256 internal constant RATE = 2500e6; // USDC per ETH, equal to the oracle
    /// @dev 22 kVCM per tonne; the pool pays 1 kVCM per USDC, so a tonne costs 22 USDC.
    uint256 internal constant PER_TONNE = 22e18;
    uint256 internal constant CEILING = 45e6; // USDC per tonne
    uint256 internal constant INTERVAL = 7200;

    /// @dev The test contract calls `process` directly in most tests and must be able to take the bounty.
    receive() external payable {}

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new RegenRegistry("", "", address(0));
        usdc = new MockUsdc();
        kvcm = new MockKvcm();
        pool = new MockPool(address(kvcm), address(usdc));
        feed = new MockFeed();
        feed.set(2500e8, block.timestamp);
        creditA = address(new MockCredit("C02-004"));
        creditB = address(new MockCredit("C02-003"));
        creditC = address(new MockCredit("C02-006"));
        agg = new MockAggregator(usdc, address(kvcm), pool, vault, PER_TONNE);
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
            sequencerUptime: IPriceFeed(address(0)),
            maxFeedAge: 3600,
            minBatch: minB,
            maxBatch: maxB,
            bountyBps: bounty,
            minOutBps: minOut,
            twapGranularity: 4,
            minTonnesBps: 9700,
            maxUsdcPerTonne: CEILING,
            processInterval: INTERVAL
        });
    }

    function _deposit(uint256 amount) internal {
        vm.prank(depositor);
        router.deposit{value: amount}(1);
    }

    /// @dev Past the interval, so the same (project, depositor) may be processed again.
    function _later() internal {
        vm.warp(block.timestamp + INTERVAL);
        feed.set(2500e8, block.timestamp);
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
        assertEq(router.usdcOf(1, depositor), 0);

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
        _later();
        vm.prank(keeper);
        router.process(1, depositor);
        _later();
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(agg.retirements(), 3);
    }

    function test_oneRetirementPerDepositorPerInterval() public {
        _deposit(0.05 ether);
        router.process(1, depositor);
        uint256 nextAt = block.timestamp + INTERVAL;
        assertEq(router.lastRetiredAt(1, depositor), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.TooSoon.selector, nextAt));
        router.process(1, depositor);
        vm.warp(nextAt - 1);
        feed.set(2500e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.TooSoon.selector, nextAt));
        router.process(1, depositor);
        vm.warp(nextAt);
        router.process(1, depositor);
        assertEq(agg.retirements(), 2);
        // another depositor of the same project is not held up
        address other = makeAddr("other-depositor");
        vm.deal(other, 1 ether);
        vm.prank(other);
        router.deposit{value: 0.01 ether}(1);
        router.process(1, other);
        assertEq(agg.retirements(), 3);
        // a skip does not start the clock
        _later();
        pool.setSpot(0.5e18);
        router.process(1, depositor); // priceOff
        pool.setSpot(1e18);
        router.process(1, depositor);
        assertEq(agg.retirements(), 4);
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
        _later();
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.0005 ether);
        _later();
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
        _later();
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditC);
    }

    function test_theAggregatorIsPaidAtMostThePlannedSpendPlusASliver() public {
        agg.setOverPull(creditA, true); // the execution path prices unlike the quote path: passed over
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        assertEq(usdc.allowance(address(router), address(agg)), 0);
        agg.setOverPull(creditB, true);
        agg.setOverPull(creditC, true);
        _deposit(0.01 ether);
        _later();
        vm.expectRevert(RegenRouter.NothingRetired.selector);
        router.process(1, depositor);
    }

    function test_anUnsupportedTokenIsSkippedNotFatal() public {
        MockAggregator a2 = new MockAggregator(usdc, address(kvcm), pool, vault, PER_TONNE);
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
        agg = new MockAggregator(usdc, address(kvcm), pool, vault, 23e18);
        agg.setCredit(creditA, 1000e18);
        router = new RegenRouter(_config(0.001 ether, 0.02 ether, 100, 9700));
        _deposit(0.01 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(usdc.balanceOf(address(router)), 22);
        assertEq(router.usdcOf(1, depositor), 22);
        assertEq(agg.lastTonnes(), 1.076086e18);
        assertEq(keeper.balance, 0.0001 ether); // rounding dust is not parking: the full bounty
        assertEq(router.balanceOf(1, depositor), 0);
        _deposit(0.01 ether);
        _later();
        router.process(1, depositor);
        assertLt(router.usdcOf(1, depositor), 24); // under one six-decimal step's worth of USDC
        assertEq(usdc.balanceOf(address(router)), router.usdcOf(1, depositor));
    }

    function test_theAggregatorsRoundUpIsGivenAStepOfSlack() public {
        pool.setRoundUpExtra(1); // the aggregator asks one micro-USDC more than the quote implies
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 1.124999e18); // one step under 1.125 t, instead of SlippageExceeded
        assertEq(router.usdcOf(1, depositor), 24.75e6 - 24_749_979);
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

    function test_theCeilingHoldsWhateverThePoolSays() public {
        _deposit(0.03 ether);
        pool.setSpot(0.4e18);
        pool.setTwap(0.4e18); // held for the whole window: 55 USDC per tonne
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.03 ether);
        pool.setSpot(0.5e18);
        pool.setTwap(0.5e18); // 44 USDC per tonne: under the 45 ceiling
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 1.125e18); // 49.5 × 0.5 / 22
        RegenRouter.Plan memory pl = router.plan(49.5e6);
        assertEq(pl.spend * 1e18 / pl.tonnes, 44e6);
    }

    function test_theReferenceTakesThePoolFeeOff() public {
        _deposit(0.03 ether);
        pool.aeroFactory().setFee(300); // a 3% pool fee
        pool.setSpot(0.965e18); // 3.5% under the fee-exclusive average, 0.5% under the fee-inclusive one
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
        assertEq(router.referenceKvcm(22e6), 21.34e18);
        pool.aeroFactory().setFee(10_000); // nonsense: nothing passes, nothing spent
        _later();
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
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

    /// @dev Round-3 info: `abi.decode(ret, (address))` reverts on a word with dirty upper bits, which contradicted
    ///      "a malformed answer means no clamp".
    function test_anAggregatorWordWithDirtyUpperBitsIsNotAClamp() public {
        vm.mockCall(address(feed), abi.encodeCall(IPriceFeed.aggregator, ()), abi.encode((uint256(1) << 160) | 0x1234));
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
    }

    function test_aProxyWithoutAnAggregatorOrAMalformedOneIsNotAClamp() public {
        _deposit(0.03 ether);
        feed.setNoAggregator(true); // aggregator() reverts
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
        feed.setNoAggregator(false);
        feed.setAggregatorAddress(makeAddr("no-code")); // aggregator() names an address with no code
        _later();
        router.process(1, depositor);
        assertEq(agg.retirements(), 2);
    }

    function test_anAnswerOnTheClampIsStale() public {
        _deposit(0.03 ether);
        feed.clamp().set(2500e8, 10_000e8); // the market fell to the floor of the feed's range
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "feedStale");
        router.process(1, depositor);
        feed.clamp().set(1, 2500e8); // or rose to its ceiling
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "feedStale");
        router.process(1, depositor);
        feed.clamp().set(1, 10_000e8);
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
        feed.setNoAggregator(true); // a feed with no clamp to read is fine
        _later();
        router.process(1, depositor);
        assertEq(agg.retirements(), 2);
    }

    function test_theSequencerMustBeUpForAnHour() public {
        MockFeed sequencer = new MockFeed();
        RegenRouter.Config memory c = _config(0.001 ether, 0.02 ether, 100, 9700);
        c.sequencerUptime = sequencer;
        router = new RegenRouter(c);
        _deposit(0.03 ether);
        sequencer.set(1, block.timestamp - 7200); // down
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "feedStale");
        router.process(1, depositor);
        sequencer.set(0, block.timestamp - 3599); // back, but not for an hour yet
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "feedStale");
        router.process(1, depositor);
        sequencer.set(0, block.timestamp - 3600);
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
        assertEq(address(router.sequencerUptime()), address(sequencer));
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
        _later();
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
        pool.setSpot(0.6e18);
        pool.setTwap(0.6e18); // held there for the whole window; 36.7 USDC per tonne, under the ceiling
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 0.675e18);
    }

    function test_aBrokenPoolQuoteSkips() public {
        _deposit(0.01 ether);
        pool.setQuoteBroken(true);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
        router.process(1, depositor);
        assertEq(router.balanceOf(1, depositor), 0.01 ether);
    }

    function test_referenceKvcmIsTheAverageLessTheFee() public {
        assertEq(router.referenceKvcm(22e6), 21.934e18); // 30 bps off
        pool.setTwap(2e18);
        assertEq(router.referenceKvcm(22e6), 43.868e18);
        pool.setSpot(0.1e18); // the spot plays no part in the reference...
        assertEq(router.referenceKvcm(22e6), 43.868e18);
        assertEq(router.kvcmFor(creditA, 1e18), 22e18); // ...and none in the aggregator's kVCM per tonne
    }

    /// @dev Round-3 low: the live quoter caps a dollar-budget quote at the class's liquid tonnes, so with the bar
    ///      compared in tonnes a class under one batch compared L with L and a same-transaction pump went through
    ///      up to the ceiling. Compared in kVCM, neither side is capped.
    function test_theBarHoldsWhenTheClassIsUnderOneBatch() public {
        agg.setCapAtVault(true);
        agg.setCredit(creditA, 2e18);
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        pool.setSpot(0.5e18); // pumped in this transaction: 44 USDC per tonne, under the 45 ceiling; average unmoved
        RegenRouter.Plan memory p = router.plan(121e6);
        assertEq(p.credit, address(0), "the plan accepted a 2x same-tx pump with no hold");
        assertEq(p.reason, bytes32("priceOff"));
        agg.setCredit(creditA, 1000e18); // the control: a deep class was always refused
        p = router.plan(121e6);
        assertEq(p.reason, bytes32("priceOff"));
        // and through process(): the last tonne of the class, refused while pumped, retired once the pool is back
        agg.setCredit(creditA, 1e18);
        _deposit(0.05 ether);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, depositor, "priceOff");
        router.process(1, depositor);
        pool.setSpot(1e18);
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 1e18);
        assertEq(agg.lastSpent(), 22e6);
        assertEq(router.usdcOf(1, depositor), 49.5e6 - 22e6);
    }

    // ---- the project's own dollars ---------------------------------------------------------------------------------

    function test_aVaultThatAbsorbsOnlyPartLeavesTheRestWithTheDepositor() public {
        reg.register("Other", REGEN, makeAddr("other-safe"));
        address other = makeAddr("other-depositor");
        vm.deal(other, 1 ether);
        agg.setCredit(creditA, 0.5e18); // the vault holds 0.5 t of credit A; the quote still says 1.125 t
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        _deposit(0.01 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditA);
        assertEq(agg.lastTonnes(), 0.5e18);
        assertEq(agg.supply(creditA), 0);
        assertEq(router.usdcOf(1, depositor), 24.75e6 - 11e6);
        // the bounty is for the 11 USDC retired out of the 24.75 bought; the rest of it stays with the depositor
        assertEq(keeper.balance, uint256(0.0001 ether) * 11e6 / 24_750_000);
        assertEq(router.balanceOf(1, depositor), 0.0001 ether - uint256(0.0001 ether) * 11e6 / 24_750_000);
        uint256 unpaid = router.balanceOf(1, depositor);
        // another project's batch retires only its own dollars
        agg.setCredit(creditB, 1000e18);
        vm.prank(other);
        router.deposit{value: 0.01 ether}(2);
        router.process(2, other);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(router.retiredOf(2), 1.125e18);
        assertEq(router.usdcOf(1, depositor), 13.75e6);
        assertEq(router.usdcOf(2, other), 0);
        // a 1-wei depositor of the same project cannot retire that remainder under its own name
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1);
        vm.prank(stranger);
        router.deposit{value: 1}(1);
        vm.expectEmit(true, true, false, true);
        emit RegenRouter.Skipped(1, stranger, "classEmpty");
        router.process(1, stranger);
        assertEq(router.usdcOf(1, depositor), 13.75e6);
        // the depositor's next batch spends its remainder, from the next credit
        _deposit(0.01 ether);
        _later();
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        // (13.75 + 99% of (0.01 ETH + the unpaid bounty) at 2500) / 22
        uint256 ethIn = 0.01 ether + unpaid;
        uint256 bought = (ethIn - ethIn / 100) * 2500e6 / 1e18;
        assertEq(agg.lastTonnes(), (13.75e6 + bought) * 1e18 / 22e6 / 1e12 * 1e12);
        assertLt(router.usdcOf(1, depositor), 23);
        assertEq(router.retiredOf(1), 0.5e18 + agg.lastTonnes());
        assertEq(usdc.balanceOf(address(router)), router.usdcOf(1, depositor));
    }

    function test_aRemainderAloneCanBeRetiredWithTheNextSlice() public {
        agg.setCredit(creditA, 0.5e18);
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        _deposit(0.0099 ether); // 1% held back as bounty → 0.009801 ETH swapped = 24.5025 USDC
        router.process(1, depositor);
        assertEq(router.usdcOf(1, depositor), 24.5025e6 - 11e6);
        uint256 unpaid = router.balanceOf(1, depositor); // the pro-rata bounty's unpaid part
        agg.setCredit(creditB, 1000e18);
        _deposit(0.0001 ether); // a sliver of ETH is enough to carry the remainder into a retirement
        _later();
        router.process(1, depositor);
        assertLt(router.usdcOf(1, depositor), 23); // rounding only
        uint256 bought = (0.0001 ether + unpaid) * 2500e6 / 1e18; // under minBatch: no bounty held back
        assertEq(agg.lastTonnes(), (13.5025e6 + bought) * 1e18 / 22e6 / 1e12 * 1e12);
    }

    /// @dev Round-3 low: a depositor whose ETH is gone could never spend its dollar remainder (`NothingToProcess`
    ///      came before `usdcOf`). Now the remainder alone is a batch: no swap, no bounty, the interval still applies.
    function test_aRemainderIsRetiredWhenTheEthIsGone() public {
        agg.setCredit(creditA, 0.05e18);
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        _deposit(0.0009 ether); // under minBatch: no bounty, so nothing comes back to the ETH balance
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 0.05e18);
        assertEq(router.balanceOf(1, depositor), 0);
        assertEq(router.usdcOf(1, depositor), 2.25e6 - 1.1e6);
        agg.setCredit(creditB, 1000e18);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.TooSoon.selector, block.timestamp + INTERVAL));
        router.process(1, depositor);
        _later();
        uint256 venueBefore = address(venue).balance;
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RegenRouter.Processed(1, depositor, keeper, creditB, 0, 0, 0, 1.149984e6, 0.052272e18);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 0.052272e18); // 1.15 / 22, floored
        assertEq(address(venue).balance, venueBefore); // nothing swapped
        assertEq(keeper.balance, 0);
        assertLt(router.usdcOf(1, depositor), 23);
        assertEq(usdc.balanceOf(address(router)), router.usdcOf(1, depositor));
        // and with neither ETH nor dollars, there is nothing to process
        vm.expectRevert(RegenRouter.NothingToProcess.selector);
        router.process(1, makeAddr("nobody"));
    }

    /// @dev Round-3 medium: first-fit let a sliver of credit A in the vault capture a whole batch (a micro-tonne
    ///      retired, the full bounty paid, the slot spent, ~all the dollars parked). The best offer is taken instead.
    function test_aSliverOfTheFirstCreditDoesNotCaptureTheBatch() public {
        agg.setCredit(creditA, 1e12); // one step of a tonne
        _deposit(0.01 ether);
        vm.prank(keeper);
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(router.usdcOf(1, depositor), 0);
        assertEq(keeper.balance, 0.0001 ether);
        // the view agrees
        RegenRouter.Plan memory p = router.plan(24.75e6);
        assertEq(p.credit, creditB);
        // two partial offers: the one that spends more wins, whatever the order
        agg.setCredit(creditA, 0.3e18);
        agg.setCredit(creditB, 0.5e18);
        agg.setCredit(creditC, 0);
        p = router.plan(24.75e6);
        assertEq(p.credit, creditB);
        assertEq(p.spend, 11e6);
        agg.setCredit(creditA, 0.5e18);
        p = router.plan(24.75e6); // a tie goes to the fixed order
        assertEq(p.credit, creditA);
    }

    /// @dev Round-3 medium, second half: dollars parked over several intervals cannot all be priced in one batch.
    ///      At most one maxBatch's worth of the remainder (at the oracle) joins a batch.
    function test_atMostOneBatchOfCarryIsSpentPerBatch() public {
        agg.setCredit(creditB, 0);
        agg.setCredit(creditC, 0);
        _deposit(0.1 ether);
        for (uint256 i; i < 3; ++i) {
            agg.setCredit(creditA, 1e12); // a sliver per interval: every batch parks ~49.5 USDC
            if (i != 0) _later();
            router.process(1, depositor);
            assertEq(agg.lastTonnes(), 1e12);
        }
        uint256 carried = router.usdcOf(1, depositor);
        assertGt(carried, 148e6);
        uint256 ethLeft = router.balanceOf(1, depositor);
        assertGt(ethLeft, 0.04 ether); // 0.1 − 3 × 0.02, plus the unpaid bounties
        // the pool is now held at 44 USDC per tonne, under the ceiling, for the whole window
        pool.setSpot(0.5e18);
        pool.setTwap(0.5e18);
        agg.setCredit(creditB, 1000e18);
        _later();
        router.process(1, depositor);
        uint256 bought = agg.lastSpent() - (carried - router.usdcOf(1, depositor));
        uint256 cap = 0.02 ether * 2500e8 / 1e20; // one maxBatch's worth: 50 USDC
        assertLe(carried - router.usdcOf(1, depositor), cap, "more than one maxBatch of carry priced in one batch");
        assertLe(agg.lastSpent(), bought + cap);
        assertGt(router.usdcOf(1, depositor), 98e6); // the rest waits for later intervals
        // with the ETH gone, the remainder still drains one maxBatch's worth per interval
        while (router.balanceOf(1, depositor) != 0) {
            _later();
            router.process(1, depositor);
        }
        uint256 before = router.usdcOf(1, depositor);
        _later();
        router.process(1, depositor);
        assertLe(before - router.usdcOf(1, depositor), cap);
    }

    /// @dev Round-3 low: one credit whose `balanceOf` reverts halted every batch of every project. It counts as
    ///      empty for that credit now; the others are still tried.
    function test_aCreditWhoseBalanceReadRevertsIsPassedOver() public {
        _deposit(0.01 ether);
        vm.mockCallRevert(creditA, abi.encodeCall(IERC20.balanceOf, (vault)), "paused");
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        assertEq(agg.lastTonnes(), 1.125e18);
        vm.clearMockedCalls();
        // a malformed answer is the same as a revert
        _deposit(0.01 ether);
        _later();
        vm.mockCall(creditA, abi.encodeCall(IERC20.balanceOf, (vault)), abi.encode(uint256(1), uint256(2)));
        router.process(1, depositor);
        assertEq(agg.lastCredit(), creditB);
        vm.clearMockedCalls();
    }

    function test_donatedUsdcBelongsToNobody() public {
        usdc.mint(address(router), 1000e6);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(agg.lastTonnes(), 1.125e18);
        assertEq(usdc.balanceOf(address(router)), 1000e6);
        assertEq(router.usdcOf(1, depositor), 0);
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
        // the forfeited slice is under minBatch; anyone retires it, for no bounty, after the interval
        _later();
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
        c.maxUsdcPerTonne = 0;
        vm.expectRevert(RegenRouter.BadParameter.selector);
        new RegenRouter(c);
        c = _config(1, 2, 100, 9700);
        c.processInterval = 0;
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
            _later();
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

    // ── Mode E grammar v1 shared vectors (Christian, github.com/CShear/mode-e-grammar @ 6f5a5a0, generated 2026-10-08;
    //    copy in test/fixtures/mode-e-grammar-v1-vectors.json). The router is a BUILDER: every valid vector's project,
    //    name and regen address, fed through the registry's validators and router.message(), must reproduce the
    //    vector byte for byte. Two deliberate differences, stated here: (1) the router always writes src:8453 (the
    //    depositor on Base, the Ethereum forwarder included, since it arrives through the bridge); vectors with src:1
    //    are compared with the chain id swapped. (2) the router writes no tags; tagged vectors are compared on the
    //    six mandatory fields and the vector must start with what we build.
    function test_grammarV1ValidVectorsAreWhatTheRouterBuilds() public view {
        {
            // v01 minimal, Ethereum forwarder
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v01 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v01 regen");
            string memory m = router.message(1, p, 0x0000000000000000000000000000000000000001);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x0000000000000000000000000000000000000001",
                "v01"
            );
            assertEq(
                bytes(m).length,
                bytes(
                    "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:1:0x0000000000000000000000000000000000000001"
                )
                .length + 3,
                "v01 length"
            );
        }
        {
            // v02 Base direct depositor
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v02 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v02 regen");
            string memory m = router.message(1, p, 0x55bEb053c003F98c1059F2a497132CBA72104a03);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03",
                "v02"
            );
            assertTrue(
                _startsWith(
                    "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03",
                    m
                ),
                "v02 prefix"
            );
        }
        {
            // v03 one tag
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v03 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v03 regen");
            string memory m = router.message(1, p, 0x55bEb053c003F98c1059F2a497132CBA72104a03);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03",
                "v03"
            );
            assertTrue(
                _startsWith(
                    "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03 | tag:game=round-12",
                    m
                ),
                "v03 prefix"
            );
        }
        {
            // v04 two tags
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v04 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v04 regen");
            string memory m = router.message(1, p, 0x55bEb053c003F98c1059F2a497132CBA72104a03);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03",
                "v04"
            );
            assertTrue(
                _startsWith(
                    "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03 | tag:game=round-12 | tag:wallet=0x1234abcd",
                    m
                ),
                "v04 prefix"
            );
        }
        {
            // v05 project id 0
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v05 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v05 regen");
            string memory m = router.message(0, p, 0x0000000000000000000000000000000000000001);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:0 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x0000000000000000000000000000000000000001",
                "v05"
            );
            assertEq(
                bytes(m).length,
                bytes(
                    "regen-klima-retire | mode:hook | project:0 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:1:0x0000000000000000000000000000000000000001"
                )
                .length + 3,
                "v05 length"
            );
        }
        {
            // v06 name with spaces and punctuation
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "Swarm Made (MADE)", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v06 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v06 regen");
            string memory m = router.message(7, p, 0x0000000000000000000000000000000000000001);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:7 | name:Swarm Made (MADE) | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x0000000000000000000000000000000000000001",
                "v06"
            );
            assertEq(
                bytes(m).length,
                bytes(
                    "regen-klima-retire | mode:hook | project:7 | name:Swarm Made (MADE) | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:1:0x0000000000000000000000000000000000000001"
                )
                .length + 3,
                "v06 length"
            );
        }
        {
            // v07 64-byte name
            RegenRegistry.Project memory p = RegenRegistry.Project(
                address(1),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan"
            );
            assertTrue(reg.validName(bytes(p.name)), "v07 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v07 regen");
            string memory m = router.message(7, p, 0x0000000000000000000000000000000000000001);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:7 | name:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x0000000000000000000000000000000000000001",
                "v07"
            );
            assertEq(
                bytes(m).length,
                bytes(
                    "regen-klima-retire | mode:hook | project:7 | name:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:1:0x0000000000000000000000000000000000000001"
                )
                .length + 3,
                "v07 length"
            );
        }
        {
            // v08 tag value with spaces
            RegenRegistry.Project memory p =
                RegenRegistry.Project(address(1), "IMDO", "regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan");
            assertTrue(reg.validName(bytes(p.name)), "v08 name");
            assertTrue(reg.validRegenAddress(bytes(p.regenAddress)), "v08 regen");
            string memory m = router.message(1, p, 0x55bEb053c003F98c1059F2a497132CBA72104a03);
            assertEq(
                m,
                "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03",
                "v08"
            );
            assertTrue(
                _startsWith(
                    "regen-klima-retire | mode:hook | project:1 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03 | tag:note=hackathon week 2",
                    m
                ),
                "v08 prefix"
            );
        }
    }

    /// x05 (leading zero), x12 (checksummed address) and x20 (over 512 bytes) are things a builder could get wrong:
    /// the router cannot produce any of them.
    function test_grammarV1InvalidVectorsTheRouterCannotProduce() public view {
        RegenRegistry.Project memory p = reg.project(1);
        assertEq(
            router.message(10, p, 0x55bEb053c003F98c1059F2a497132CBA72104a03),
            "regen-klima-retire | mode:hook | project:10 | name:IMDO | regen:regen183ht37fsp2fhnq3gneyjycp08c3ju4xnvxnvan | src:8453:0x55beb053c003f98c1059f2a497132cba72104a03"
        );
        // the longest message the router can build: a 78-digit id, a 64-byte name
        p.name = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        string memory m = router.message(type(uint256).max, p, address(type(uint160).max));
        assertEq(bytes(m).length, 298);
        assertLe(bytes(m).length, 512);
        assertEq(bytes(m)[bytes(m).length - 1], bytes1("f")); // lowercase hex, never checksummed
    }

    function _startsWith(string memory whole, string memory prefix) private pure returns (bool) {
        bytes memory w = bytes(whole);
        bytes memory q = bytes(prefix);
        if (q.length > w.length) return false;
        for (uint256 i; i < q.length; ++i) {
            if (w[i] != q[i]) return false;
        }
        return true;
    }
}
