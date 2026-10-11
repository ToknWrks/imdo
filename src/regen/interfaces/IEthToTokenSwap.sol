// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A stateless venue adapter: swap native ETH into one token, delivering at least `minOut` to `to` or
///         reverting. The router computes `minOut` itself from an oracle; the adapter holds nothing.
interface IEthToTokenSwap {
    function swapEthToToken(address token, uint256 minOut, address to) external payable returns (uint256 tokenOut);
}

/// @notice Chainlink AggregatorV3 (ETH/USD on Base: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, 8 decimals).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
