// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

interface IZapRouter {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}