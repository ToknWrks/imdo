// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A stateless venue adapter: swap native ETH into one token, delivering at least `minOut` to `to` or
///         reverting. The router computes `minOut` itself from an oracle; the adapter holds nothing.
interface IEthToTokenSwap {
    function swapEthToToken(address token, uint256 minOut, address to) external payable returns (uint256 tokenOut);
}

/// @notice The aggregator behind a Chainlink proxy; its answers are clamped to [minAnswer, maxAnswer].
interface IPriceFeedAggregator {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @notice Chainlink AggregatorV3 (ETH/USD on Base: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, 8 decimals). The same
///         shape serves the L2 sequencer uptime feed (answer 0 = up, 1 = down; startedAt = when that began).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    /// @dev Only Chainlink proxies have this; callers must tolerate a revert.
    function aggregator() external view returns (IPriceFeedAggregator);
}
