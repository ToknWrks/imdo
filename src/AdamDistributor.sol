// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IAdamDistributor} from "./interfaces/IAdamDistributor.sol";

/// @title AdamDistributor
/// @notice Pull-based, multi-token dividend-per-share distributor for ADAM holders.
///
/// Holders stake ADAM here (1:1, withdrawable at any time, no lock, no fee) and earn every reward token
/// (IMD and PNKSTR) pro-rata to their staked balance from the moment they stake. Rewards are credited
/// with the classic "reward per share" accumulator and claimed by the holder (pull), never pushed.
///
/// @dev Why staking instead of hooking every ADAM transfer: the launch token is required to be a plain
/// ERC-20 with no transfer hooks and no constructor arguments, so it cannot call back into this contract
/// on transfer. Staking gives exact accounting with no stale-balance window, which an unsynchronised
/// "shadow balance" scheme cannot. See README "What differs from the brief".
///
/// Trust model: no owner, no upgrade, no sweep. Anyone may call `notifyReward` for a configured reward
/// token (it only ever adds rewards). The excluded set is fixed at construction.
contract AdamDistributor is IAdamDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Scaling factor for the per-share accumulator.
    uint256 private constant MAGNITUDE = 2 ** 128;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable adam;

    address[] private _rewardTokens;
    mapping(address token => bool) public isRewardToken;
    /// @notice Addresses that may never stake (pool manager, token, this contract, zero, dead, ...).
    mapping(address account => bool) public isExcluded;

    uint256 public totalStaked;
    mapping(address account => uint256) public stakedBalance;

    /// @notice Accumulated reward per staked ADAM, scaled by MAGNITUDE.
    mapping(address token => uint256) public rewardPerShare;
    /// @notice Rewards received while nobody was staked; folded into the next distribution.
    mapping(address token => uint256) public unallocated;
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

    /// @param adam_ The ADAM token.
    /// @param rewardToken0 First reward token (IMD).
    /// @param rewardToken1 Second reward token (PNKSTR).
    /// @param poolManager The Uniswap v4 PoolManager (excluded from staking).
    /// @param excludedExtra An additional address to exclude (pass address(0) if none).
    constructor(address adam_, address rewardToken0, address rewardToken1, address poolManager, address excludedExtra) {
        if (
            adam_ == address(0) || rewardToken0 == address(0) || rewardToken1 == address(0) || poolManager == address(0)
        ) {
            revert ZeroAddress();
        }
        if (rewardToken0 == rewardToken1) revert DuplicateRewardToken();
        adam = IERC20(adam_);

        _rewardTokens.push(rewardToken0);
        _rewardTokens.push(rewardToken1);
        isRewardToken[rewardToken0] = true;
        isRewardToken[rewardToken1] = true;

        isExcluded[address(0)] = true;
        isExcluded[DEAD] = true;
        isExcluded[address(this)] = true;
        isExcluded[adam_] = true;
        isExcluded[poolManager] = true;
        isExcluded[rewardToken0] = true;
        isExcluded[rewardToken1] = true;
        if (excludedExtra != address(0)) isExcluded[excludedExtra] = true;
    }

    // ---------------------------------------------------------------------------------------------
    // Holder actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Stake ADAM to start earning. Requires prior approval.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (isExcluded[msg.sender]) revert Excluded(msg.sender);
        _settle(msg.sender);
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
        adam.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw staked ADAM. Accrued rewards stay claimable.
    function unstake(uint256 amount) external nonReentrant {
        _unstake(amount);
    }

    /// @notice Claim every accrued reward token.
    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Withdraw all staked ADAM and claim every reward in one call.
    function exit() external nonReentrant {
        _unstake(stakedBalance[msg.sender]);
        _claim(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Reward intake
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IAdamDistributor
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

    function _distribute(address token, uint256 amount) private returns (uint256 distributed) {
        if (totalStaked == 0) {
            unallocated[token] += amount;
            return 0;
        }
        distributed = amount + unallocated[token];
        unallocated[token] = 0;
        rewardPerShare[token] += FullMath.mulDiv(distributed, MAGNITUDE, totalStaked);
        totalDistributed[token] += distributed;
    }

    function _unstake(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedBalance[msg.sender];
        if (amount > staked) revert InsufficientStake();
        _settle(msg.sender);
        stakedBalance[msg.sender] = staked - amount;
        totalStaked -= amount;
        emit Unstaked(msg.sender, amount);
        adam.safeTransfer(msg.sender, amount);
    }

    function _claim(address account) private {
        _settle(account);
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 amount = rewardsAccrued[token][account];
            if (amount == 0) continue;
            rewardsAccrued[token][account] = 0;
            totalClaimed[token] += amount;
            emit RewardClaimed(account, token, amount);
            IERC20(token).safeTransfer(account, amount);
        }
    }

    /// @dev Credit everything owed so far at the current accumulator, then checkpoint.
    function _settle(address account) private {
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 owed = _pending(account, token);
            if (owed != 0) rewardsAccrued[token][account] += owed;
            rewardPerSharePaid[token][account] = rewardPerShare[token];
        }
    }

    function _pending(address account, address token) private view returns (uint256) {
        uint256 staked = stakedBalance[account];
        if (staked == 0) return 0;
        uint256 delta = rewardPerShare[token] - rewardPerSharePaid[token][account];
        return FullMath.mulDiv(staked, delta, MAGNITUDE);
    }
}
