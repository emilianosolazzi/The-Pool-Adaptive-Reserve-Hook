// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IZapRouter} from "./interfaces/IZapRouter.sol";

interface ISwapRouter02ExactInputSingle {
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

/// @notice Narrow adapter from LiquidityVaultV2 to Uniswap SwapRouter02 exactInputSingle.
/// @dev Keeps the vault from accepting arbitrary router calldata while still
///      using deep external Uniswap v3 liquidity for WETH/USDC conversions.
contract SwapRouter02ZapAdapter is IZapRouter {
    using SafeERC20 for IERC20;

    ISwapRouter02ExactInputSingle public immutable swapRouter;
    uint24 public immutable poolFee;

    constructor(ISwapRouter02ExactInputSingle _swapRouter, uint24 _poolFee) {
        require(address(_swapRouter).code.length > 0, "ROUTER_NOT_CONTRACT");
        swapRouter = _swapRouter;
        poolFee = _poolFee;
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "DEADLINE");
        require(amountIn > 0, "ZERO_AMOUNT");
        require(recipient != address(0), "ZERO_RECIPIENT");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(swapRouter), 0);
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        amountOut = swapRouter.exactInputSingle(
            ISwapRouter02ExactInputSingle.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(tokenIn).forceApprove(address(swapRouter), 0);
    }
}