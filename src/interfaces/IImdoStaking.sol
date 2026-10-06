// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IImdoStaking {
    function notifyReward(address token, uint256 amount) external;
    function notifyRegen() external payable;
}
