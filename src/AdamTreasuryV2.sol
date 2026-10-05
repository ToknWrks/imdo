// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdamTreasury} from "./AdamTreasury.sol";
import {AdamDistributorV2} from "./AdamDistributorV2.sol";
import {AdamSplitOracle} from "./AdamSplitOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title AdamTreasuryV2
/// @notice Immutable three-leg treasury. Fees net of the keeper bounty retain the 90/10 split.
/// @custom:x https://x.com/IaMaDamIMD
contract AdamTreasuryV2 is AdamTreasury {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    uint256 public constant KEEPER_BPS = 50;
    uint8 public constant LEG_IMDSTR = 2;
    AdamSplitOracle public immutable splitOracle;
    AdamDistributorV2 public immutable distributorV2;
    mapping(address => uint256) public keeperOwed;
    uint256 public totalKeeperOwed;
    event KeeperPaid(address indexed keeper, uint256 amount);
    event KeeperPaymentDeferred(address indexed keeper, uint256 amount);

    struct Config {
        address distributor;
        address team;
        address manager;
        PoolKey[3] keys;
        uint16[3] taxes;
        uint256 maxEthPerBuy;
        uint16 slippageBps;
        uint32 cooldown;
        address oracle;
    }

    constructor(Config memory c)
        AdamTreasury(
            c.distributor,
            c.team,
            c.manager,
            Currency.unwrap(c.keys[0].currency1),
            c.keys[0].fee,
            uint24(c.keys[0].tickSpacing),
            address(c.keys[0].hooks),
            c.taxes[0],
            Currency.unwrap(c.keys[1].currency1),
            c.keys[1].fee,
            uint24(c.keys[1].tickSpacing),
            address(c.keys[1].hooks),
            c.taxes[1],
            c.maxEthPerBuy,
            c.slippageBps,
            c.cooldown
        )
    {
        if (
            c.oracle.code.length == 0 || c.distributor.code.length == 0 || c.manager.code.length == 0
                || c.maxEthPerBuy > uint256(uint128(type(int128).max)) || c.taxes[2] >= BPS
        ) revert InvalidParameter();
        distributorV2 = AdamDistributorV2(c.distributor);
        splitOracle = AdamSplitOracle(c.oracle);
        for (uint8 i; i < 3; ++i) {
            if (Currency.unwrap(c.keys[i].currency0) != address(0) || c.keys[i].tickSpacing <= 0) {
                revert InvalidParameter();
            }
        }
        (Currency a, Currency b, uint24 f, int24 s, address h) = _distributorKey(distributorV2);
        if (
            keccak256(abi.encode(a, b, f, s, h)) != keccak256(abi.encode(c.keys[2]))
                || address(distributorV2.poolManager()) != c.manager || distributorV2.maxEthPerClaim() != c.maxEthPerBuy
                || !distributorV2.isRewardToken(Currency.unwrap(c.keys[0].currency1))
                || !distributorV2.isRewardToken(Currency.unwrap(c.keys[1].currency1))
        ) revert InvalidParameter();
        _legs[2].key = c.keys[2];
        _legs[2].hookTaxBps = c.taxes[2];
        (_legs[2].checkpointSqrtPriceX96,,,) = poolManager.getSlot0(c.keys[2].toId());
    }

    function _distributorKey(AdamDistributorV2 d)
        private
        view
        returns (Currency a, Currency b, uint24 f, int24 s, address h)
    {
        // Solidity returns an IHooks type from the public PoolKey getter.
        PoolKey memory key;
        (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) = d.imdstrKey();
        return (key.currency0, key.currency1, key.fee, key.tickSpacing, address(key.hooks));
    }

    /// @notice Pull keeper bounty while splitting new ETH, then independently attempt all three legs.
    function process() external override nonReentrant {
        uint64 availableAt = lastProcessed + cooldown;
        if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        uint256 amount = unsplitEth();
        uint256 cap = (3 * maxEthPerBuy * BPS * BPS) / ((BPS - TEAM_BPS) * (BPS - KEEPER_BPS));
        if (amount > cap) amount = cap;
        if (amount == 0 && _legs[0].pending == 0 && _legs[1].pending == 0 && _legs[2].pending == 0) {
            revert NothingToProcess();
        }
        lastProcessed = uint64(block.timestamp);
        uint16[3] memory weights = splitOracle.checkpoint();
        uint256 bounty;
        if (amount != 0) {
            bounty = amount * KEEPER_BPS / BPS;
            uint256 net = amount - bounty;
            uint256 teamShare = net * TEAM_BPS / BPS;
            uint256 holders = net - teamShare;
            uint256 imdShare = holders * weights[0] / BPS;
            uint256 pnkShare = holders * weights[1] / BPS;
            teamOwed += teamShare;
            _legs[0].pending += imdShare;
            _legs[1].pending += pnkShare;
            _legs[2].pending += holders - imdShare - pnkShare;
            keeperOwed[msg.sender] += bounty;
            totalKeeperOwed += bounty;
            emit Split(amount, teamShare, holders);
        }
        _inProcess = true;
        for (uint8 i; i < 3; ++i) {
            _executeLeg(i);
        }
        _inProcess = false;
        // Failure to accept a bounty cannot block processing; the caller can pull it later.
        if (bounty != 0) {
            keeperOwed[msg.sender] -= bounty;
            totalKeeperOwed -= bounty;
            (bool ok,) = msg.sender.call{value: bounty, gas: 100_000}("");
            if (ok) {
                emit KeeperPaid(msg.sender, bounty);
            } else {
                keeperOwed[msg.sender] += bounty;
                totalKeeperOwed += bounty;
                emit KeeperPaymentDeferred(msg.sender, bounty);
            }
        }
    }

    /// @notice Team claims its own allocation; processing never pushes team funds.
    function payTeam() external override nonReentrant {
        if (msg.sender != teamWallet) revert InvalidParameter();
        uint256 amount = teamOwed;
        if (amount == 0) revert NothingOwed();
        teamOwed = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TeamTransferFailed();
        emit TeamPaid(amount);
    }

    function claimKeeper(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 amount = keeperOwed[msg.sender];
        if (amount == 0) revert NothingOwed();
        keeperOwed[msg.sender] = 0;
        totalKeeperOwed -= amount;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TeamTransferFailed();
        emit KeeperPaid(msg.sender, amount);
    }

    function unsplitEth() public view override returns (uint256) {
        return
            address(this).balance - teamOwed - totalKeeperOwed - _legs[0].pending - _legs[1].pending - _legs[2].pending;
    }

    /// @dev Atomic self-call includes both swap and reward credit so either failure is isolated to its leg.
    function executeV2(uint8 id, uint256 ethIn) external returns (uint256 out) {
        if (msg.sender != address(this) || !_inProcess) revert NotProcessing();
        if (id == LEG_IMDSTR) {
            uint256 floor = distributorV2.directDistribution() ? quoteMinOut(id, ethIn) : 0;
            out = distributorV2.notifyIMDSTR{value: ethIn}(floor);
        } else {
            if (quoteMinOut(id, ethIn) == 0) revert InvalidParameter();
            out = abi.decode(poolManager.unlock(abi.encode(id, ethIn)), (uint256));
            address token = Currency.unwrap(_legs[id].key.currency1);
            IERC20(token).forceApprove(address(distributor), out);
            distributor.notifyReward(token, out);
            IERC20(token).forceApprove(address(distributor), 0);
        }
    }

    function _executeLeg(uint8 id) internal override {
        Leg storage l = _legs[id];
        uint256 gap = cooldown > MAX_FAILURE_GAP ? cooldown : MAX_FAILURE_GAP;
        if (l.failures != 0 && block.timestamp > uint256(l.lastFailure) + gap) _resetFailures(l);
        uint256 cap = l.retryCap == 0 ? maxEthPerBuy : l.retryCap;
        uint256 ethIn = l.pending < cap ? l.pending : cap;
        if (ethIn < MIN_ETH_PER_BUY) {
            _resetFailures(l);
            return;
        }
        try this.executeV2(id, ethIn) returns (uint256 out) {
            l.pending -= ethIn;
            _resetFailures(l);
            // Accruing ETH is not a price observation. Keep the original checkpoint until a real buy.
            if (id != LEG_IMDSTR || distributorV2.directDistribution()) {
                (l.checkpointSqrtPriceX96,,,) = poolManager.getSlot0(l.key.toId());
            }
            emit LegBought(id, Currency.unwrap(l.key.currency1), ethIn, out);
        } catch (bytes memory reason) {
            emit LegFailed(id, ethIn, reason);
            if (l.failures == 0) l.failingSince = uint64(block.timestamp);
            l.lastFailure = uint64(block.timestamp);
            if (l.failures < MIN_FAILURES) ++l.failures;
            l.retryCap = ethIn / 2;
            if (l.retryCap < MIN_ETH_PER_BUY) l.retryCap = MIN_ETH_PER_BUY;
            if (l.failures >= MIN_FAILURES && block.timestamp >= uint256(l.failingSince) + LEG_FALLBACK_DELAY) {
                uint8 other = (id + 1) % 3;
                uint8 alternate = (id + 2) % 3;
                if (_legs[other].failures != 0 && _legs[alternate].failures == 0) other = alternate;
                uint256 moved = l.pending;
                l.pending = 0;
                _resetFailures(l);
                _legs[other].pending += moved;
                emit LegRerouted(id, other, moved);
            }
        }
    }
}
