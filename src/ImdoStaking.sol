// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IImdoStaking} from "./interfaces/IImdoStaking.sol";

/// @title ImdoStaking
/// @notice ADAM accumulator and gated backlog, reduced to IMD and lifetime REGEN ETH credits.
/// @dev No owner or upgrade. All principal stakes reset a 24-hour withdrawal lock.
contract ImdoStaking is IImdoStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Scaling factor for the per-share accumulator.
    uint256 private constant MAGNITUDE = 2 ** 128;
    uint256 public constant BACKLOG_DURATION = 7 days;
    /// @notice Backlog streams only while at least 1% of the fixed IMDO supply is staked.
    uint256 public constant MIN_BACKLOG_STAKE = 10_000_000e18;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable imdo;
    address public immutable imd;
    address public immutable poolManager;
    address public immutable claimContract;
    address public immutable regenSafe;
    uint256 public constant LOCK_DURATION = 24 hours;
    mapping(address => uint256) public unlockTime;
    uint256 public totalRegenNotified;
    uint256 public totalRegenWithdrawn;
    error OnlyClaim();
    error OnlyRegenSafe();
    error StakeLocked(uint256 availableAt);
    error InsufficientRegen();
    error RegenTransferFailed();
    event RegenNotified(address indexed from, uint256 amount, uint256 distributed);
    event RegenWithdrawn(uint256 amount);

    address[] internal _rewardTokens;
    mapping(address token => bool) public isRewardToken;
    /// @notice Addresses that may never stake (pool manager, token, this contract, zero, dead, ...).
    mapping(address account => bool) public isExcluded;

    uint256 public totalStaked;
    mapping(address account => uint256) public stakedBalance;

    /// @notice Accumulated reward per staked IMDO, scaled by MAGNITUDE.
    mapping(address token => uint256) public rewardPerShare;
    /// @notice Undistributed launch/empty-stake rewards, released through a gated seven-day stream.
    mapping(address token => uint256) public unallocated;

    struct BacklogStream {
        uint256 amount;
        uint256 released;
        uint64 start;
    }
    mapping(address token => BacklogStream) public backlogStream;
    /// @notice Lifetime amount of each token credited to stakers (excludes `unallocated`).
    mapping(address token => uint256) public totalDistributed;
    /// @notice Lifetime amount of each token paid out by `claim`.
    mapping(address token => uint256) public totalClaimed;

    mapping(address token => mapping(address account => uint256)) public rewardPerSharePaid;
    mapping(address token => mapping(address account => uint256)) public rewardsAccrued;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardNotified(address indexed token, address indexed from, uint256 amount, uint256 distributed);
    event RewardClaimed(address indexed account, address indexed token, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error Excluded(address account);
    error NotRewardToken(address token);
    error InsufficientStake();
    error DuplicateRewardToken();

    constructor(address imdo_, address imd_, address manager_, address claim_, address regenSafe_) {
        if (
            imdo_ == address(0) || imd_ == address(0) || manager_ == address(0) || claim_ == address(0)
                || regenSafe_ == address(0)
        ) revert ZeroAddress();
        if (imdo_ == imd_) revert DuplicateRewardToken();
        imdo = IERC20(imdo_);
        imd = imd_;
        poolManager = manager_;
        claimContract = claim_;
        regenSafe = regenSafe_;
        _rewardTokens.push(imd_);
        _rewardTokens.push(address(0));
        isRewardToken[imd_] = true;
        isExcluded[address(0)] = true;
        isExcluded[DEAD] = true;
        isExcluded[address(this)] = true;
        isExcluded[imdo_] = true;
        isExcluded[manager_] = true;
        isExcluded[imd_] = true;
        isExcluded[claim_] = true;
        isExcluded[regenSafe_] = true;
    }

    // ---------------------------------------------------------------------------------------------
    // Holder actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Stake IMDO to start earning. Requires prior approval.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (isExcluded[msg.sender]) revert Excluded(msg.sender);
        _settle(msg.sender);
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        unlockTime[msg.sender] = block.timestamp + LOCK_DURATION;
        _syncBacklogStreams();
        emit Staked(msg.sender, amount);
        imdo.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw staked IMDO. Accrued rewards stay claimable.
    function unstake(uint256 amount) external nonReentrant {
        _unstake(amount);
    }

    /// @notice Claim every accrued reward token.
    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Withdraw all staked IMDO and claim every reward in one call.
    function exit() external nonReentrant {
        uint256 balance = stakedBalance[msg.sender];
        if (balance != 0) _unstake(balance);
        _claim(msg.sender);
    }

    /// @notice ERC-7572 immutable contract metadata.
    function contractURI() external pure returns (string memory) {
        return 'data:application/json,{"name":"IMDO Staking"}';
    }

    // ---------------------------------------------------------------------------------------------
    // Reward intake
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IImdoStaking
    function notifyReward(address token, uint256 amount) external nonReentrant {
        if (!isRewardToken[token]) revert NotRewardToken(token);
        if (amount == 0) revert ZeroAmount();

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        uint256 distributed = _distribute(token, received);
        emit RewardNotified(token, msg.sender, received, distributed);
    }

    /// @notice Only the immutable claim contract may fund a beneficiary's stake.
    function stakeFor(address beneficiary, uint256 amount) external nonReentrant {
        if (msg.sender != claimContract) revert OnlyClaim();
        if (amount == 0) revert ZeroAmount();
        if (isExcluded[beneficiary]) revert Excluded(beneficiary);
        _settle(beneficiary);
        stakedBalance[beneficiary] += amount;
        totalStaked += amount;
        unlockTime[beneficiary] = block.timestamp + LOCK_DURATION;
        _syncBacklogStreams();
        imdo.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(beneficiary, amount);
    }

    function claimReward(address token) external nonReentrant {
        if (!isRewardToken[token]) revert NotRewardToken(token);
        _settle(msg.sender);
        uint256 amount = rewardsAccrued[token][msg.sender];
        if (amount == 0) revert ZeroAmount();
        rewardsAccrued[token][msg.sender] = 0;
        totalClaimed[token] += amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, token, amount);
    }

    /// @notice ETH funds off-chain REGEN purchases; it is never paid by a holder claim.
    function notifyRegen() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        totalRegenNotified += msg.value;
        uint256 distributed = _distribute(address(0), msg.value);
        emit RegenNotified(msg.sender, msg.value, distributed);
    }

    function regenCreditOf(address account) external view returns (uint256) {
        return earned(account, address(0));
    }

    function withdrawRegen(uint256 amount) external nonReentrant {
        if (msg.sender != regenSafe) revert OnlyRegenSafe();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalRegenNotified - totalRegenWithdrawn) revert InsufficientRegen();
        totalRegenWithdrawn += amount;
        (bool ok,) = regenSafe.call{value: amount}("");
        if (!ok) revert RegenTransferFailed();
        emit RegenWithdrawn(amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    /// @notice Claimable `token` for `account` right now.
    function earned(address account, address token) public view returns (uint256) {
        return rewardsAccrued[token][account] + _pending(account, token);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _distribute(address token, uint256 amount) internal returns (uint256 distributed) {
        _releaseBacklog(token);
        if (totalStaked == 0) {
            unallocated[token] += amount;
            return 0;
        }
        distributed = amount;
        rewardPerShare[token] += FullMath.mulDiv(distributed, MAGNITUDE, totalStaked);
        totalDistributed[token] += distributed;
    }

    function _unstake(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedBalance[msg.sender];
        if (amount > staked) revert InsufficientStake();
        if (block.timestamp < unlockTime[msg.sender]) revert StakeLocked(unlockTime[msg.sender]);
        _settle(msg.sender);
        stakedBalance[msg.sender] = staked - amount;
        totalStaked -= amount;
        _syncBacklogStreams();
        emit Unstaked(msg.sender, amount);
        imdo.safeTransfer(msg.sender, amount);
    }

    function _claim(address account) internal {
        _settle(account);
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 amount = rewardsAccrued[token][account];
            if (amount == 0 || token == address(0)) continue;
            rewardsAccrued[token][account] = 0;
            totalClaimed[token] += amount;
            emit RewardClaimed(account, token, amount);
            IERC20(token).safeTransfer(account, amount);
        }
    }

    /// @dev Credit everything owed so far at the current accumulator, then checkpoint.
    function _settle(address account) internal {
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            _releaseBacklog(token);
            uint256 owed = _pending(account, token);
            if (owed != 0) rewardsAccrued[token][account] += owed;
            rewardPerSharePaid[token][account] = rewardPerShare[token];
        }
    }

    function _pending(address account, address token) private view returns (uint256) {
        uint256 staked = stakedBalance[account];
        if (staked == 0) return 0;
        uint256 delta = rewardPerShare[token] - rewardPerSharePaid[token][account];
        if (totalStaked != 0) delta += FullMath.mulDiv(_backlogDue(token), MAGNITUDE, totalStaked);
        return FullMath.mulDiv(staked, delta, MAGNITUDE);
    }

    function _backlogDue(address token) private view returns (uint256) {
        BacklogStream storage stream = backlogStream[token];
        if (stream.amount == 0 || totalStaked < MIN_BACKLOG_STAKE) return 0;
        uint256 elapsed = block.timestamp - stream.start;
        if (elapsed > BACKLOG_DURATION) elapsed = BACKLOG_DURATION;
        return FullMath.mulDiv(stream.amount, elapsed, BACKLOG_DURATION) - stream.released;
    }

    /// @dev Always checkpoint before stake changes: newcomers cannot earn past stream time.
    function _releaseBacklog(address token) private {
        uint256 amount = _backlogDue(token);
        if (amount == 0) return;
        backlogStream[token].released += amount;
        unallocated[token] -= amount;
        rewardPerShare[token] += FullMath.mulDiv(amount, MAGNITUDE, totalStaked);
        totalDistributed[token] += amount;
    }

    /// @dev Losing the threshold pauses release. Regaining it restarts the remaining reserve over seven
    /// days; elapsed time below the threshold never vests. Called after settling both tokens.
    function _syncBacklogStreams() internal {
        for (uint256 i; i < _rewardTokens.length; ++i) {
            address token = _rewardTokens[i];
            if (totalStaked < MIN_BACKLOG_STAKE) {
                delete backlogStream[token];
            } else if (backlogStream[token].amount == 0 && unallocated[token] != 0) {
                backlogStream[token] = BacklogStream(unallocated[token], 0, uint64(block.timestamp));
            }
        }
    }
}
