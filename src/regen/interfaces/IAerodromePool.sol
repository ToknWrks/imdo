// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Aerodrome (Velodrome v2) pool the Klima aggregator buys kVCM in (Base USDC/kVCM volatile pool
///         0x5C0D76fab1822bDeb47308eD6028231761ED723E). Only the time-weighted quote is used here: the pool records a
///         reserve observation at most every 30 minutes (`periodSize`), and `quote(tokenIn, amountIn, granularity)`
///         prices `amountIn` at the reserves averaged over the last `granularity` observations, so a price set inside
///         one transaction never reaches it. The quote leaves the pool's own fee out.
interface IAerodromePool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256 amountOut);
}
