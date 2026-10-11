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
import {IEthToTokenSwap, IPriceFeed} from "./interfaces/IEthToTokenSwap.sol";
import {IRegenRouterDeposit} from "./RegenReceiver.sol";

/// @title RegenRouter
/// @notice Holds ETH per registered project and depositor and, when anyone asks, turns a batch of it into retired Regen
///         City Forest credits on Klima's Retirement Aggregator with the project as beneficiary. No owner, no parameter
///         can change, nothing leaves except as a retirement, the caller's bounty, or dollar dust held for the next
///         batch.
/// @dev Balances are kept per (project, depositor) so the retirement message can name where the ETH came from
///      (`src:8453:<depositor>`): the project's bridge receiver for a leg forwarded from Ethereum, a Safe for a direct
///      deposit. One `process(projectId, depositor)`:
///        1. take min(balance, maxBatch); refuse under minBatch (dust is not worth the gas, and tiny batches are the
///           cheapest way to grief the bounty);
///        2. ask the aggregator what one dollar buys from each credit token, in fixed order; if none answers, emit
///           `Skipped` and keep the ETH: the class is empty, nothing has moved. Same if the price feed is stale;
///        3. swap the batch minus the bounty ETH → USDC. The caller supplies NO minimum: the router requires at least
///           `minOutBps` of what Chainlink's ETH/USD answer says the batch is worth. The reference is an oracle, not a
///           pool, so a sandwich cannot lower the bar, and it can never take more than (10000 − minOutBps) of a batch
///           that is at most `maxBatch`. That ceiling, not a trusted keeper, is the protection;
///        4. quote tonnes for all the USDC in hand, floor to six decimals of a tonne, retire paying USDC with
///           `maxInputTokenIn` = what is held (the aggregator swaps USDC → kVCM itself and reverts if it would need
///           more); the USDC left over stays here for the next batch;
///        5. pay the caller the bounty, last. A caller that cannot take ETH forfeits it to the project.
///      The retirement message is grammar v1, assembled from registry fields validated at registration. Tags are not
///      written by this version (the grammar reserves them).
contract RegenRouter is IRegenRouterDeposit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @dev Retirements are floored to six decimals of a tonne (what the Regen side mirrors).
    uint256 public constant TONNE_STEP = 1e12;
    string public constant RETIRING_ENTITY = "Regen Retirement Router";

    RegenRegistry public immutable registry;
    IKlimaRetirementAggregator public immutable aggregator;
    /// @dev The dollar token the aggregator is paid in (USDC, 6 decimals); the aggregator pulls it from here.
    IERC20 public immutable usdc;
    address public immutable classVault;
    address public immutable creditA;
    address public immutable creditB;
    address public immutable creditC;
    IEthToTokenSwap public immutable venue;
    IPriceFeed public immutable ethUsd;
    uint256 public immutable maxFeedAge;
    uint256 public immutable minBatch;
    uint256 public immutable maxBatch;
    uint256 public immutable bountyBps;
    uint256 public immutable minOutBps;

    mapping(uint256 projectId => mapping(address depositor => uint256)) public balanceOf;
    mapping(uint256 projectId => uint256) public retiredOf;
    uint256 public totalRetired;

    error ZeroAddress();
    error UnknownProject(uint256 projectId);
    error ZeroDeposit();
    error BadParameter();
    error BelowMinBatch(uint256 balance, uint256 minBatch);
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
        address classVault;
        address creditA;
        address creditB;
        address creditC;
        IEthToTokenSwap venue;
        IPriceFeed ethUsd;
        uint256 maxFeedAge;
        uint256 minBatch;
        uint256 maxBatch;
        uint256 bountyBps;
        uint256 minOutBps;
    }

    constructor(Config memory c) {
        if (
            address(c.registry) == address(0) || address(c.aggregator) == address(0) || address(c.usdc) == address(0)
                || c.classVault == address(0) || c.creditA == address(0) || c.creditB == address(0)
                || c.creditC == address(0) || address(c.venue) == address(0) || address(c.ethUsd) == address(0)
        ) revert ZeroAddress();
        if (
            c.minBatch == 0 || c.maxBatch < c.minBatch || c.bountyBps >= BPS || c.minOutBps == 0 || c.minOutBps > BPS
                || c.maxFeedAge == 0 || c.ethUsd.decimals() != 8
        ) revert BadParameter();
        registry = c.registry;
        aggregator = c.aggregator;
        usdc = c.usdc;
        classVault = c.classVault;
        creditA = c.creditA;
        creditB = c.creditB;
        creditC = c.creditC;
        venue = c.venue;
        ethUsd = c.ethUsd;
        maxFeedAge = c.maxFeedAge;
        minBatch = c.minBatch;
        maxBatch = c.maxBatch;
        bountyBps = c.bountyBps;
        minOutBps = c.minOutBps;
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
    ///         `bountyBps` of the batch.
    function process(uint256 projectId, address depositor) external nonReentrant {
        RegenRegistry.Project memory p = registry.project(projectId);
        uint256 balance = balanceOf[projectId][depositor];
        if (balance < minBatch) revert BelowMinBatch(balance, minBatch);
        uint256 ethIn = balance > maxBatch ? maxBatch : balance;

        uint256 price = _ethUsd();
        if (price == 0) {
            emit Skipped(projectId, depositor, "feedStale");
            return;
        }
        address credit = _firstLiveCredit();
        if (credit == address(0)) {
            emit Skipped(projectId, depositor, "classEmpty");
            return;
        }

        balanceOf[projectId][depositor] = balance - ethIn;
        uint256 bounty = ethIn * bountyBps / BPS;
        uint256 bought = _swap(ethIn - bounty, price);

        uint256 held = usdc.balanceOf(address(this));
        (uint256 tonnes,,,,) =
            aggregator.quoteRetireCreditForInputTokenInViaKlima(credit, 0, held, address(usdc), classVault, 0);
        tonnes = tonnes / TONNE_STEP * TONNE_STEP;
        if (tonnes == 0) revert NothingRetired();
        usdc.forceApprove(address(aggregator), held);
        aggregator.retireCreditViaKlima(
            credit,
            0,
            0,
            tonnes,
            address(usdc),
            classVault,
            held,
            0,
            RetireDetails({
                retiringAddress: address(this),
                retiringEntityString: RETIRING_ENTITY,
                beneficiaryAddress: p.beneficiary,
                beneficiaryString: p.name,
                retirementMessage: message(projectId, p, depositor),
                beneficiaryLocation: "",
                consumptionCountryCode: "",
                consumptionPeriodStart: 0,
                consumptionPeriodEnd: 0
            })
        );
        usdc.forceApprove(address(aggregator), 0);
        uint256 spent = held - usdc.balanceOf(address(this));

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

    /// @dev Chainlink ETH/USD; 0 when stale or nonsense, which skips the batch rather than trusting a pool.
    function _ethUsd() private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsd.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || block.timestamp - updatedAt > maxFeedAge) return 0;
        return uint256(answer);
    }

    /// @dev ETH → USDC through the venue, held to the oracle.
    function _swap(uint256 ethIn, uint256 price) private returns (uint256 bought) {
        uint256 required = minUsdcOut(ethIn, price);
        uint256 before = usdc.balanceOf(address(this));
        venue.swapEthToToken{value: ethIn}(address(usdc), required, address(this));
        bought = usdc.balanceOf(address(this)) - before;
        if (bought < required) revert SwapShort(bought, required);
    }

    /// @dev Fixed order; the first credit token the aggregator quotes a non-zero tonne for at one dollar.
    function _firstLiveCredit() private view returns (address) {
        address[3] memory order = [creditA, creditB, creditC];
        for (uint256 i; i < 3; ++i) {
            try aggregator.quoteRetireCreditForInputTokenInViaKlima(
                order[i], 0, 1e6, address(usdc), classVault, 0
            ) returns (
                uint256 tonnes,
                uint256,
                uint256,
                DiscountedForwardBalanceContext memory,
                UpdateLiquidSupplyRateLimiterParams memory
            ) {
                if (tonnes != 0) return order[i];
            } catch {}
        }
        return address(0);
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
