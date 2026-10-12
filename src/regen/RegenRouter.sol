// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegenRegistry} from "./RegenRegistry.sol";
import {
    IKlimaRetirementAggregator,
    RetireDetails,
    DiscountedForwardBalanceContext,
    UpdateLiquidSupplyRateLimiterParams
} from "./interfaces/IKlimaRetirementAggregator.sol";
import {IEthToTokenSwap, IPriceFeed, IPriceFeedAggregator} from "./interfaces/IEthToTokenSwap.sol";
import {IAerodromePool, IAerodromeFactory} from "./interfaces/IAerodromePool.sol";
import {IRegenRouterDeposit} from "./RegenReceiver.sol";

/// @title RegenRouter
/// @notice Holds ETH per registered project and depositor and, when anyone asks, turns a batch of it into retired Regen
///         City Forest credits on Klima's Retirement Aggregator with the project as beneficiary. No owner, no parameter
///         can change, nothing leaves except as a retirement, the caller's bounty, or the depositor's own dollar
///         remainder held for its next batch.
/// @dev Balances and dollar remainders are kept per (project, depositor) so the retirement message can name where the
///      money came from (`src:8453:<depositor>`): the project's bridge receiver for a leg forwarded from Ethereum, a
///      Safe for a direct deposit. One `process(projectId, depositor)`:
///        1. refuse (TooSoon) within `processInterval` of that depositor's last retirement; take min(balance,
///           maxBatch). A batch of at least `minBatch` pays the caller `bountyBps`; a smaller remainder (what is left
///           after the last full batch, or a forfeited bounty) is processed with no bounty, so nothing is stranded;
///        2. read Chainlink ETH/USD; stale, dated in the future, on the aggregator's min/max clamp, or the L2 sequencer
///           down or back for under an hour → emit `Skipped("feedStale")`, keep the ETH;
///        3. plan the retirement before spending anything: for each credit token in fixed order, ask the aggregator
///           what the batch's dollars (at least `minOutBps` of the oracle value, plus the depositor's remainder) would
///           retire, capped at what the class vault holds of that credit, and hold the offer to the two bars in step 5.
///           No credit plans → `Skipped("classEmpty")` or `Skipped("priceOff")`, ETH kept;
///        4. swap the batch minus the bounty ETH → USDC. The caller supplies NO minimum: the router requires at least
///           `minOutBps` of what Chainlink says the batch is worth. The reference is an oracle, not a pool, so a
///           sandwich on the ETH/USDC pool cannot lower the bar and can take at most (10000 − minOutBps) of a batch;
///        5. plan again with the dollars actually in hand and retire from the first credit that plans and retires; a
///           credit whose retirement reverts is passed over. Paying USDC, the aggregator buys kVCM at the SPOT reserves
///           of one small Aerodrome pool, which the caller of this very function could move in the same transaction.
///           Two bars, both on the dollars the aggregator will take for the tonnes it offers:
///             (a) a RELATIVE bar: at least `minTonnesBps` of what those dollars buy at the pool's time-weighted price
///                 (`twapGranularity` completed observation intervals, each at least 30 minutes, the pool fee taken
///                 off) converted at the aggregator's own kVCM-per-tonne rate. A price set inside a transaction never
///                 reaches it. A price HELD for the whole window does: the pool writes an observation on any state
///                 change and `sync()` is public, so after `twapGranularity` intervals the average IS the held price.
///                 That is why the window is long (a day at the intended 48) and why `processInterval` exists: a hold
///                 ties the mover's capital in a token whose only venue is this pool, in front of every holder who
///                 sells into it, for one batch per depositor per interval;
///             (b) an ABSOLUTE bar: never more than `maxUsdcPerTonne`. The ceiling is what bounds a batch's loss
///                 whatever the pool says; it is immutable, so it is set well above the market and the rail halts
///                 (ETH waits, nothing is lost) if credits ever cost more than that.
///           The aggregator is paid at most the planned spend plus a sliver, so an execution that prices unlike the
///           quote reverts and is passed over instead of being paid up to the batch;
///        6. the USDC the aggregator did not take (sub-step rounding, or a credit whose vault could only absorb part
///           of the batch) stays here as THAT DEPOSITOR'S remainder (`usdcOf`) and is spent on its next batch, so a
///           retirement message never names someone else's dollars;
///        7. pay the caller the bounty, last. A caller that cannot take ETH forfeits it to the depositor.
///      What remains open, in numbers: a mover who holds the pool off its average for the whole window and keeps the
///      price under the ceiling can take, per depositor, (24h / processInterval) batches a day at the held price; at
///      the intended values that is at most 12 × maxBatch × (1 − market / maxUsdcPerTonne) a day against a day of
///      capital in this pool. Trust that remains: the aggregator is an upgradeable diamond run by Klima; if it, the
///      class vault, the credit tokens or its pool are retired or reconfigured, every batch skips and the ETH waits
///      here with no other exit. The aggregator's views are trusted to return well-formed data (a malformed answer
///      reverts the call rather than skipping), and a retirement that burns all the gas it is handed ends the call
///      without trying the next credit. The retirement message is grammar v1, assembled from registry fields
///      validated at registration. Tags are not written by this version (the grammar reserves them).
contract RegenRouter is IRegenRouterDeposit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @dev Retirements are floored to six decimals of a tonne (what the Regen side mirrors).
    uint256 public constant TONNE_STEP = 1e12;
    string public constant RETIRING_ENTITY = "Regen Retirement Router";
    /// @dev After the sequencer comes back, this long must pass before a price is trusted again (Chainlink's guidance).
    uint256 public constant SEQUENCER_GRACE = 1 hours;
    /// @dev The aggregator may pull this much over the planned spend (its round-up is a few micro-USDC): 0.1% + 100.
    uint256 public constant PULL_SLACK_BPS = 10;
    uint256 public constant PULL_SLACK_ABS = 100;

    RegenRegistry public immutable registry;
    IKlimaRetirementAggregator public immutable aggregator;
    /// @dev The dollar token the aggregator is paid in (USDC, 6 decimals); the aggregator pulls it from here.
    IERC20 public immutable usdc;
    /// @dev Klima's carbon token (18 decimals), what the aggregator turns the dollars into before retiring.
    IERC20 public immutable kvcm;
    /// @dev The pool the aggregator buys kVCM in; its time-weighted quote is the reference for the second leg.
    IAerodromePool public immutable kvcmPool;
    address public immutable classVault;
    address public immutable creditA;
    address public immutable creditB;
    address public immutable creditC;
    IEthToTokenSwap public immutable venue;
    IPriceFeed public immutable ethUsd;
    /// @dev Chainlink's L2 sequencer uptime feed (Base 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433); zero = none.
    IPriceFeed public immutable sequencerUptime;
    uint256 public immutable maxFeedAge;
    uint256 public immutable minBatch;
    uint256 public immutable maxBatch;
    uint256 public immutable bountyBps;
    uint256 public immutable minOutBps;
    /// @dev Completed observation intervals the kVCM reference averages (each at least 30 minutes).
    uint256 public immutable twapGranularity;
    /// @dev Least share of the time-weighted tonnes a batch must retire.
    uint256 public immutable minTonnesBps;
    /// @dev Most USDC (6 decimals) the aggregator may be paid per tonne (1e18), whatever the pool says.
    uint256 public immutable maxUsdcPerTonne;
    /// @dev Least time between two retirements for the same (project, depositor).
    uint256 public immutable processInterval;

    mapping(uint256 projectId => mapping(address depositor => uint256)) public balanceOf;
    /// @notice Dollars bought for a depositor's batches and not yet retired (rounding, or a vault that absorbed only part).
    mapping(uint256 projectId => mapping(address depositor => uint256)) public usdcOf;
    mapping(uint256 projectId => mapping(address depositor => uint256)) public lastRetiredAt;
    mapping(uint256 projectId => uint256) public retiredOf;
    uint256 public totalRetired;

    error ZeroAddress();
    error UnknownProject(uint256 projectId);
    error ZeroDeposit();
    error BadParameter();
    error NothingToProcess();
    error TooSoon(uint256 nextAt);
    error SwapShort(uint256 got, uint256 required);
    error NothingRetired();
    error DirectEthRefused();

    event Deposited(uint256 indexed projectId, address indexed depositor, uint256 amount);
    event Skipped(uint256 indexed projectId, address indexed depositor, bytes32 reason);
    event Processed(
        uint256 indexed projectId,
        address indexed depositor,
        address indexed caller,
        address creditToken,
        uint256 ethIn,
        uint256 bounty,
        uint256 usdcBought,
        uint256 usdcSpent,
        uint256 tonnes
    );
    event BountyForfeited(uint256 indexed projectId, address indexed caller, uint256 amount);

    struct Config {
        RegenRegistry registry;
        IKlimaRetirementAggregator aggregator;
        IERC20 usdc;
        IERC20 kvcm;
        IAerodromePool kvcmPool;
        address classVault;
        address creditA;
        address creditB;
        address creditC;
        IEthToTokenSwap venue;
        IPriceFeed ethUsd;
        IPriceFeed sequencerUptime;
        uint256 maxFeedAge;
        uint256 minBatch;
        uint256 maxBatch;
        uint256 bountyBps;
        uint256 minOutBps;
        uint256 twapGranularity;
        uint256 minTonnesBps;
        uint256 maxUsdcPerTonne;
        uint256 processInterval;
    }

    /// @dev One credit's offer for an amount of dollars, after every check; `credit` is zero when there is none and
    ///      `reason` says why.
    struct Plan {
        address credit;
        uint256 tonnes;
        uint256 spend;
        bytes32 reason;
    }

    constructor(Config memory c) {
        if (
            address(c.registry) == address(0) || address(c.aggregator) == address(0) || address(c.usdc) == address(0)
                || address(c.kvcm) == address(0) || address(c.kvcmPool) == address(0) || c.classVault == address(0)
                || c.creditA == address(0) || c.creditB == address(0) || c.creditC == address(0)
                || address(c.venue) == address(0) || address(c.ethUsd) == address(0)
        ) revert ZeroAddress();
        if (
            c.minBatch == 0 || c.maxBatch < c.minBatch || c.bountyBps >= BPS || c.minOutBps == 0 || c.minOutBps > BPS
                || c.maxFeedAge == 0 || c.ethUsd.decimals() != 8 || c.twapGranularity == 0 || c.minTonnesBps == 0
                || c.minTonnesBps > BPS || c.maxUsdcPerTonne == 0 || c.processInterval == 0
        ) revert BadParameter();
        address t0 = c.kvcmPool.token0();
        address t1 = c.kvcmPool.token1();
        if (!((t0 == address(c.usdc) && t1 == address(c.kvcm)) || (t0 == address(c.kvcm) && t1 == address(c.usdc)))) {
            revert BadParameter();
        }
        registry = c.registry;
        aggregator = c.aggregator;
        usdc = c.usdc;
        kvcm = c.kvcm;
        kvcmPool = c.kvcmPool;
        classVault = c.classVault;
        creditA = c.creditA;
        creditB = c.creditB;
        creditC = c.creditC;
        venue = c.venue;
        ethUsd = c.ethUsd;
        sequencerUptime = c.sequencerUptime;
        maxFeedAge = c.maxFeedAge;
        minBatch = c.minBatch;
        maxBatch = c.maxBatch;
        bountyBps = c.bountyBps;
        minOutBps = c.minOutBps;
        twapGranularity = c.twapGranularity;
        minTonnesBps = c.minTonnesBps;
        maxUsdcPerTonne = c.maxUsdcPerTonne;
        processInterval = c.processInterval;
    }

    /// @dev ETH must name a project. A plain transfer would belong to nobody.
    receive() external payable {
        revert DirectEthRefused();
    }

    function projectExists(uint256 projectId) external view returns (bool) {
        return registry.exists(projectId);
    }

    function deposit(uint256 projectId) external payable {
        if (msg.value == 0) revert ZeroDeposit();
        if (!registry.exists(projectId)) revert UnknownProject(projectId);
        balanceOf[projectId][msg.sender] += msg.value;
        emit Deposited(projectId, msg.sender, msg.value);
    }

    /// @notice Retire one batch of what `depositor` paid in for `projectId`. Anyone may call; the caller earns
    ///         `bountyBps` of a batch of at least `minBatch`, nothing for a smaller remainder.
    function process(uint256 projectId, address depositor) external nonReentrant {
        RegenRegistry.Project memory p = registry.project(projectId);
        uint256 balance = balanceOf[projectId][depositor];
        if (balance == 0) revert NothingToProcess();
        uint256 nextAt = lastRetiredAt[projectId][depositor] + processInterval;
        if (block.timestamp < nextAt) revert TooSoon(nextAt);
        uint256 ethIn = balance > maxBatch ? maxBatch : balance;
        uint256 bounty = ethIn >= minBatch ? ethIn * bountyBps / BPS : 0;

        uint256 price = _ethUsd();
        if (price == 0) {
            emit Skipped(projectId, depositor, "feedStale");
            return;
        }
        uint256 carried = usdcOf[projectId][depositor];
        Plan memory ahead = _plan(minUsdcOut(ethIn - bounty, price) + carried);
        if (ahead.credit == address(0)) {
            emit Skipped(projectId, depositor, ahead.reason);
            return;
        }

        balanceOf[projectId][depositor] = balance - ethIn;
        uint256 bought = _swap(ethIn - bounty, price);
        uint256 held = carried + bought;

        (address credit, uint256 tonnes, uint256 spent) = _retire(projectId, p, depositor, held);
        usdcOf[projectId][depositor] = held - spent;
        lastRetiredAt[projectId][depositor] = block.timestamp;
        retiredOf[projectId] += tonnes;
        totalRetired += tonnes;
        emit Processed(projectId, depositor, msg.sender, credit, ethIn, bounty, bought, spent, tonnes);

        if (bounty != 0) {
            (bool ok,) = msg.sender.call{value: bounty}("");
            if (!ok) {
                balanceOf[projectId][depositor] += bounty;
                emit BountyForfeited(projectId, msg.sender, bounty);
            }
        }
    }

    /// @notice Grammar v1 (frozen 2026-10-07). `src` names the depositor on Base.
    function message(uint256 projectId, RegenRegistry.Project memory p, address depositor)
        public
        pure
        returns (string memory)
    {
        return string.concat(
            "regen-klima-retire | mode:hook | project:",
            _uint(projectId),
            " | name:",
            p.name,
            " | regen:",
            p.regenAddress,
            " | src:8453:",
            _hex(depositor)
        );
    }

    /// @notice The least USDC (6 decimals) the router accepts for `ethIn` at Chainlink's `price` (8 decimals).
    function minUsdcOut(uint256 ethIn, uint256 price) public view returns (uint256) {
        // ethIn (1e18) × price (1e8) → dollars × 1e26; USDC has 1e6 → divide by 1e20.
        return ethIn * price / 1e20 * minOutBps / BPS;
    }

    /// @notice What `amount` USDC should retire from `credit` at the kVCM pool's time-weighted price: the pool's
    ///         average quote for that many dollars, less the pool's fee, converted at the aggregator's own
    ///         kVCM-per-tonne rate.
    function referenceTonnes(address credit, uint256 amount) public view returns (uint256) {
        uint256 kvcmRef = kvcmPool.quote(address(usdc), amount, twapGranularity);
        uint256 fee = IAerodromeFactory(kvcmPool.factory()).getFee(address(kvcmPool), kvcmPool.stable());
        if (fee >= BPS) revert BadParameter(); // a nonsense fee is a refusal, never a free pass
        kvcmRef = kvcmRef * (BPS - fee) / BPS;
        (uint256 tonnes,,,,) =
            aggregator.quoteRetireCreditForInputTokenInViaKlima(credit, 0, kvcmRef, address(kvcm), classVault, 0);
        return tonnes;
    }

    /// @notice The offer of the first credit token (fixed order) that would retire for `amount` USDC right now, or
    ///         an empty plan whose reason is "classEmpty" (no credit quotes a step of a tonne, or its vault is empty)
    ///         or "priceOff" (a credit quotes, but over the ceiling or under the time-weighted bar).
    function plan(uint256 amount) external view returns (Plan memory) {
        return _plan(amount);
    }

    /// @dev Chainlink ETH/USD; 0 when stale or nonsense, which skips the batch rather than trusting a pool. Nonsense
    ///      includes: the sequencer down or back for under `SEQUENCER_GRACE` (the feed could not have updated), an
    ///      answer dated in the future, and an answer sitting on the aggregator's min/max clamp (the market has left
    ///      the feed's range; the clamp is read through the proxy when it exposes one).
    function _ethUsd() private view returns (uint256) {
        if (address(sequencerUptime) != address(0)) {
            (, int256 up, uint256 since,,) = sequencerUptime.latestRoundData();
            if (up != 0 || since == 0 || since > block.timestamp || block.timestamp - since < SEQUENCER_GRACE) {
                return 0;
            }
        }
        (, int256 answer,, uint256 updatedAt,) = ethUsd.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxFeedAge) {
            return 0;
        }
        if (_onClamp(answer)) return 0;
        return uint256(answer);
    }

    /// @dev Reads the proxy's aggregator and its clamp with raw static calls, so a proxy without one, an aggregator
    ///      without code, or a malformed answer all mean "no clamp to check" instead of a revert.
    function _onClamp(int256 answer) private view returns (bool) {
        (bool ok, bytes memory ret) = address(ethUsd).staticcall(abi.encodeCall(IPriceFeed.aggregator, ()));
        if (!ok || ret.length != 32) return false;
        address agg = abi.decode(ret, (address));
        if (agg.code.length == 0) return false;
        (ok, ret) = agg.staticcall(abi.encodeCall(IPriceFeedAggregator.minAnswer, ()));
        if (ok && ret.length == 32 && answer <= abi.decode(ret, (int256))) return true;
        (ok, ret) = agg.staticcall(abi.encodeCall(IPriceFeedAggregator.maxAnswer, ()));
        if (ok && ret.length == 32 && answer >= abi.decode(ret, (int256))) return true;
        return false;
    }

    /// @dev ETH → USDC through the venue, held to the oracle.
    function _swap(uint256 ethIn, uint256 price) private returns (uint256 bought) {
        uint256 required = minUsdcOut(ethIn, price);
        uint256 before = usdc.balanceOf(address(this));
        venue.swapEthToToken{value: ethIn}(address(usdc), required, address(this));
        bought = usdc.balanceOf(address(this)) - before;
        if (bought < required) revert SwapShort(bought, required);
    }

    function _plan(uint256 amount) private view returns (Plan memory none) {
        address[3] memory order = [creditA, creditB, creditC];
        none.reason = "classEmpty";
        for (uint256 i; i < 3; ++i) {
            Plan memory offer = _offer(order[i], amount);
            if (offer.credit != address(0)) return offer;
            if (offer.reason == "priceOff") none.reason = offer.reason;
        }
    }

    /// @dev What `credit` would retire for `amount` USDC: the aggregator's quote, capped at what the class vault holds
    ///      of the credit (the aggregator quotes its curve regardless, and retires only what the vault has), floored to
    ///      a step of a tonne; the dollars the aggregator will take for those tonnes (it rounds up: one step less if
    ///      that overshoots); then the ceiling and the time-weighted bar. Any revert in the aggregator's or the pool's
    ///      views counts against the credit.
    function _offer(address credit, uint256 amount) private view returns (Plan memory p) {
        p.reason = "classEmpty";
        uint256 tonnes = _tonnesFor(credit, amount);
        uint256 inVault = IERC20(credit).balanceOf(classVault);
        if (inVault < tonnes) tonnes = inVault;
        tonnes = tonnes / TONNE_STEP * TONNE_STEP;
        if (tonnes == 0) return p;
        uint256 spend = _usdcFor(credit, tonnes);
        if (spend == 0 || spend > amount) {
            tonnes -= TONNE_STEP;
            if (tonnes == 0) return p;
            spend = _usdcFor(credit, tonnes);
            if (spend == 0 || spend > amount) return p;
        }
        p.reason = "priceOff";
        if (spend * 1e18 > maxUsdcPerTonne * tonnes) return p;
        try this.referenceTonnes(credit, spend) returns (uint256 bar) {
            if (tonnes < bar * minTonnesBps / BPS) return p;
        } catch {
            return p;
        }
        return Plan({credit: credit, tonnes: tonnes, spend: spend, reason: ""});
    }

    function _tonnesFor(address credit, uint256 amount) private view returns (uint256) {
        try aggregator.quoteRetireCreditForInputTokenInViaKlima(
            credit, 0, amount, address(usdc), classVault, 0
        ) returns (
            uint256 tonnes,
            uint256,
            uint256,
            DiscountedForwardBalanceContext memory,
            UpdateLiquidSupplyRateLimiterParams memory
        ) {
            return tonnes;
        } catch {
            return 0;
        }
    }

    /// @dev The USDC the aggregator asks for `tonnes` of `credit` (its `retirementPrice`); 0 when it cannot say.
    function _usdcFor(address credit, uint256 tonnes) private view returns (uint256) {
        try aggregator.quoteRetireCreditViaKlima(credit, 0, tonnes, address(usdc), classVault, 0) returns (
            uint256,
            uint256 retirementPrice,
            DiscountedForwardBalanceContext memory,
            UpdateLiquidSupplyRateLimiterParams memory
        ) {
            return retirementPrice;
        } catch {
            return 0;
        }
    }

    /// @dev Retire from the first credit that plans for `held` and whose retirement goes through at the planned
    ///      spend (plus a sliver for the aggregator's round-up); a credit that reverts, or would pull more, is passed
    ///      over. None → revert, which also undoes the swap: the ETH stays credited.
    function _retire(uint256 projectId, RegenRegistry.Project memory p, address depositor, uint256 held)
        private
        returns (address credit, uint256 tonnes, uint256 spent)
    {
        address[3] memory order = [creditA, creditB, creditC];
        RetireDetails memory details = RetireDetails({
            retiringAddress: address(this),
            retiringEntityString: RETIRING_ENTITY,
            beneficiaryAddress: p.beneficiary,
            beneficiaryString: p.name,
            retirementMessage: message(projectId, p, depositor),
            beneficiaryLocation: "",
            consumptionCountryCode: "",
            consumptionPeriodStart: 0,
            consumptionPeriodEnd: 0
        });
        for (uint256 i; i < 3; ++i) {
            Plan memory offer = _offer(order[i], held);
            if (offer.credit == address(0)) continue;
            uint256 maxIn = offer.spend + offer.spend * PULL_SLACK_BPS / BPS + PULL_SLACK_ABS;
            if (maxIn > held) maxIn = held;
            uint256 before = usdc.balanceOf(address(this));
            usdc.forceApprove(address(aggregator), maxIn);
            try aggregator.retireCreditViaKlima(
                offer.credit, 0, 0, offer.tonnes, address(usdc), classVault, maxIn, 0, details
            ) {
                usdc.forceApprove(address(aggregator), 0);
                return (offer.credit, offer.tonnes, before - usdc.balanceOf(address(this)));
            } catch {
                usdc.forceApprove(address(aggregator), 0);
            }
        }
        revert NothingRetired();
    }

    function _uint(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n;
        for (uint256 t = v; t != 0; t /= 10) {
            ++n;
        }
        bytes memory b = new bytes(n);
        while (v != 0) {
            b[--n] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }

    function _hex(address a) private pure returns (string memory) {
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
