// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEthToTokenSwap} from "./interfaces/IEthToTokenSwap.sol";

/// @dev Uniswap SwapRouter02 (Base: 0x2626664c2603336E57B271c5C0b26F421741e481). `exactInputSingle` with native ETH
///      as msg.value wraps it for the pool; no deadline field in this router's struct.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3Venue
/// @notice Native ETH → one token through one Uniswap V3 pool (WETH/token at a fixed fee tier). Stateless; the router
///         is the only intended caller but nothing stops anyone, since it holds nothing and delivers to `to`.
contract UniswapV3Venue is IEthToTokenSwap {
    ISwapRouter02 public immutable router;
    address public immutable weth;
    uint24 public immutable fee;

    error ZeroAddress();
    error WrongToken();

    constructor(ISwapRouter02 router_, address weth_, uint24 fee_) {
        if (address(router_) == address(0) || weth_ == address(0)) revert ZeroAddress();
        router = router_;
        weth = weth_;
        fee = fee_;
    }

    function swapEthToToken(address token, uint256 minOut, address to) external payable returns (uint256 tokenOut) {
        if (token == weth) revert WrongToken();
        tokenOut = router.exactInputSingle{value: msg.value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                fee: fee,
                recipient: to,
                amountIn: msg.value,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
