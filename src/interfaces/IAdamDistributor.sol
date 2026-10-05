// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Custody/reward-accounting intake; holders pull their own rewards.
/// @custom:x https://x.com/IaMaDamIMD
interface IAdamDistributor {
    /// @notice Pull `amount` of `token` from the caller (allowance required) and credit it to stakers pro-rata.
    function notifyReward(address token, uint256 amount) external;
}
