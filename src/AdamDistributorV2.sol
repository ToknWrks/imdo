// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdamDistributor} from "./AdamDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IStrategyToken {
    function isDistributor(address account) external view returns (bool);
}

/// @title AdamDistributorV2
/// @notice Three-asset staking; IMDSTR ETH credits buy directly to the claiming wallet.
/// @custom:x https://x.com/IaMaDamIMD
contract AdamDistributorV2 is AdamDistributor, IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable poolManager;
    address public immutable imdstr;
    uint256 public immutable maxEthPerClaim;
    PoolKey public imdstrKey;
    bool public directDistribution;
    bool private _swapping;
    event DirectDistributionEnabled();
    event IMDSTRClaimed(address indexed account, uint256 ethIn, uint256 amountOut);
    error InvalidConfiguration();
    error InvalidSwap();
    error Slippage();
    error NotWhitelisted();

    constructor(
        address adam_,
        address imd_,
        address pnkstr_,
        address manager_,
        address nftClaim_,
        PoolKey memory key_,
        uint256 maxEth_
    ) AdamDistributor(adam_, imd_, pnkstr_, manager_, nftClaim_) {
        address token = Currency.unwrap(key_.currency1);
        if (
            token == address(0) || token == adam_ || token == imd_ || token == pnkstr_
                || Currency.unwrap(key_.currency0) != address(0) || key_.tickSpacing <= 0 || maxEth_ == 0
                || maxEth_ > uint256(uint128(type(int128).max))
        ) revert InvalidConfiguration();
        poolManager = IPoolManager(manager_);
        imdstr = token;
        imdstrKey = key_;
        maxEthPerClaim = maxEth_;
        _rewardTokens.push(address(0)); // ETH obligations, never paid as ETH by claim().
        _rewardTokens.push(token);
        isRewardToken[token] = true;
        isExcluded[token] = true;
    }

    /// @notice Pull ADAM from the caller, credit only beneficiary. NFTClaim itself is excluded.
    function stakeFor(address beneficiary, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (isExcluded[beneficiary]) revert Excluded(beneficiary);
        _settle(beneficiary);
        stakedBalance[beneficiary] += amount;
        totalStaked += amount;
        _syncBacklogStreams();
        adam.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(beneficiary, amount);
    }

    /// @notice Claim one transferable reward independently if another asset is temporarily locked.
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

    /// @notice Accrue ETH, or buy/credit direct IMDSTR after the one-time whitelist switch.
    /// @dev Anyone may fund rewards; direct-mode swaps require explicit output protection.
    function notifyIMDSTR(uint256 minOut) external payable nonReentrant returns (uint256 amountOut) {
        if (msg.value == 0 || msg.value > maxEthPerClaim) revert InvalidSwap();
        if (directDistribution) {
            if (!IStrategyToken(imdstr).isDistributor(address(this))) revert NotWhitelisted();
            if (minOut == 0) revert Slippage();
            amountOut = _buy(address(this), msg.value, minOut);
            uint256 distributed = _distribute(imdstr, amountOut);
            emit RewardNotified(imdstr, msg.sender, amountOut, distributed);
        } else {
            uint256 distributed = _distribute(address(0), msg.value);
            emit RewardNotified(address(0), msg.sender, msg.value, distributed);
        }
    }

    /// @notice Pull up to `ethAmount` of your IMDSTR budget; minOut and deadline protect your swap.
    /// @dev Still available after direct mode: pre-switch ETH entitlements never change denomination.
    function claimIMDSTR(uint256 ethAmount, uint256 minOut, uint256 deadline_)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (block.timestamp > deadline_ || minOut == 0 || ethAmount == 0 || ethAmount > maxEthPerClaim) {
            revert InvalidSwap();
        }
        _settle(msg.sender);
        if (ethAmount > rewardsAccrued[address(0)][msg.sender]) revert InvalidSwap();
        rewardsAccrued[address(0)][msg.sender] -= ethAmount;
        totalClaimed[address(0)] += ethAmount;
        out = _buy(msg.sender, ethAmount, minOut);
        emit IMDSTRClaimed(msg.sender, ethAmount, out);
    }

    /// @notice Permissionless once the IMDSTR owner has actually whitelisted this Distributor.
    function enableDirectDistribution() external nonReentrant {
        if (directDistribution || !IStrategyToken(imdstr).isDistributor(address(this))) revert NotWhitelisted();
        directDistribution = true;
        emit DirectDistributionEnabled();
    }

    function _buy(address recipient, uint256 ethIn, uint256 minOut) private returns (uint256) {
        _swapping = true;
        bytes memory result = poolManager.unlock(abi.encode(recipient, ethIn, minOut));
        _swapping = false;
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_swapping) revert InvalidSwap();
        (address recipient, uint256 ethIn, uint256 minOut) = abi.decode(data, (address, uint256, uint256));
        BalanceDelta delta =
            poolManager.swap(imdstrKey, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), "");
        if (delta.amount0() >= 0 || uint256(-int256(delta.amount0())) != ethIn || delta.amount1() <= 0) {
            revert InvalidSwap();
        }
        uint256 out = uint256(uint128(delta.amount1()));
        uint256 beforeBalance = IERC20(imdstr).balanceOf(recipient);
        poolManager.settle{value: ethIn}();
        poolManager.take(imdstrKey.currency1, recipient, out);
        uint256 received = IERC20(imdstr).balanceOf(recipient) - beforeBalance;
        if (received < minOut) revert Slippage();
        return abi.encode(received);
    }
}
