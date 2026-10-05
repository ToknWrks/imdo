// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The surface the Treasury uses to push bought reward tokens to holders.
interface IAdamDistributor {
    /// @notice Pull `amount` of `token` from the caller (allowance required) and credit it to stakers pro-rata.
    function notifyReward(address token, uint256 amount) external;
}
