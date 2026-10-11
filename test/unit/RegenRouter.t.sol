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

contract MockUsdc is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
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

/// @dev Honest venue: USDC per ETH `fillRate` (6 dec), enforces minOut like a real pool.
contract MockVenue is IEthToTokenSwap {
    MockUsdc public token;
    uint256 public fillRate;
    RegenRouter public reenter;

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

    function swapEthToToken(address, uint256 minOut, address to) external payable returns (uint256 out) {
        if (address(reenter) != address(0)) reenter.process(1, address(0xD0));
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

/// @dev Klima stand-in: `price` USDC (6 dec) per tonne; supply per credit token; pulls USDC from the caller.
contract MockAggregator is IKlimaRetirementAggregator {
    MockUsdc public usdc;
    uint256 public price;
    mapping(address => uint256) public supply;
    mapping(address => bool) public supported;
    RetireDetails public last;
    address public lastCredit;
    uint256 public lastTonnes;
    uint256 public retirements;

    error TokenNotSupported();
    error SlippageExceeded(uint256 required, uint256 maxAllowed);

    constructor(MockUsdc u, uint256 p) {
        usdc = u;
        price = p;
    }

    function setCredit(address c, uint256 tonnes) external {
        supported[c] = true;
        supply[c] = tonnes;
    }

    function quoteRetireCreditForInputTokenInViaKlima(
        address creditToken,
        uint256,
        uint256 amount,
        address,
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
        tonnes = amount * 1e18 / price;
        if (tonnes > supply[creditToken]) tonnes = supply[creditToken];
        return (tonnes, amount, price, d, u);
    }

    function quoteRetireCreditViaKlima(address, uint256, uint256, address, address, uint256)
        external
        pure
        returns (
            uint256,
            uint256,
            DiscountedForwardBalanceContext memory d,
            UpdateLiquidSupplyRateLimiterParams memory u
        )
    {
        return (0, 0, d, u);
    }

    function retireCreditViaKlima(
        address creditToken,
        uint256,
        uint256,
        uint256 tonnes,
        address,
        address,
        uint256 maxIn,
        uint256,
        RetireDetails memory details
    ) external {
        if (!supported[creditToken] || tonnes > supply[creditToken]) revert TokenNotSupported();
        uint256 cost = tonnes * price / 1e18;
        if (cost > maxIn) revert SlippageExceeded(cost, maxIn);
        require(usdc.transferFrom(msg.sender, address(this), cost), "pull");
        supply[creditToken] -= tonnes;
        last = details;
        lastCredit = creditToken;
        lastTonnes = tonnes;
        ++retirements;
    }
}

contract RegenRouterTest is Test {
    RegenRegistry internal reg;
    MockUsdc internal usdc;
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
    uint256 internal constant PRICE = 22e6; // USDC per tonne

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new RegenRegistry();
        usdc = new MockUsdc();
        feed = new MockFeed();
        feed.set(2500e8, block.timestamp);
        agg = new MockAggregator(usdc, PRICE);
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
            minOutBps: minOut
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

    function test_belowMinBatchRefused() public {
        _deposit(0.0009 ether);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.BelowMinBatch.selector, 0.0009 ether, 0.001 ether));
        router.process(1, depositor);
        vm.expectRevert(abi.encodeWithSelector(RegenRouter.BelowMinBatch.selector, 0, 0.001 ether));
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
        MockAggregator a2 = new MockAggregator(usdc, PRICE);
        a2.setCredit(creditC, 10e18); // A and B never registered: the quote reverts TokenNotSupported
        agg = a2;
        router = new RegenRouter(_config(0.001 ether, 0.02 ether, 100, 9700));
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(a2.lastCredit(), creditC);
    }

    function test_dustCarriesToTheNextBatch() public {
        // 24.75 USDC at 23/t = 1.076086956… t, floored to 1.076086 t → spends 24.749978, 22 micro-USDC dust
        agg = new MockAggregator(usdc, 23e6);
        agg.setCredit(creditA, 1000e18);
        router = new RegenRouter(_config(0.001 ether, 0.02 ether, 100, 9700));
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertEq(usdc.balanceOf(address(router)), 22);
        assertEq(agg.lastTonnes(), 1.076086e18);
        _deposit(0.01 ether);
        router.process(1, depositor);
        assertLt(usdc.balanceOf(address(router)), 24); // under one six-decimal step's worth of USDC
    }

    // ---- the slippage ceiling --------------------------------------------------------------------------------------

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
        assertEq(agg.retirements(), 0);
        feed.set(2500e8, block.timestamp);
        router.process(1, depositor);
        assertEq(agg.retirements(), 1);
    }

    function test_minOutFollowsTheOracle() public {
        assertEq(router.minUsdcOut(1 ether, 2500e8), 2425e6); // 97% of $2,500
        assertEq(router.minUsdcOut(0.0099 ether, 3000e8), 28.809e6);
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
        c.creditB = address(0);
        vm.expectRevert(RegenRouter.ZeroAddress.selector);
        new RegenRouter(c);
    }

    // ---- fuzz: ETH is conserved -----------------------------------------------------------------------------------

    function testFuzz_ethConservation(uint96 amount, uint8 rounds) public {
        amount = uint96(bound(amount, 0.001 ether, 1 ether));
        rounds = uint8(bound(rounds, 1, 10));
        vm.deal(depositor, amount);
        _deposit(amount);
        uint256 swapped;
        uint256 bounties;
        for (uint256 i; i < rounds; ++i) {
            uint256 bal = router.balanceOf(1, depositor);
            if (bal < 0.001 ether) break;
            uint256 ethIn = bal > 0.02 ether ? 0.02 ether : bal;
            uint256 before = keeper.balance;
            vm.prank(keeper);
            router.process(1, depositor);
            bounties += keeper.balance - before;
            swapped += ethIn - ethIn * 100 / 10_000;
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
