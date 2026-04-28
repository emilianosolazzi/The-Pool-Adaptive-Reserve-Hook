// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Pure math helpers extracted from LiquidityVaultV2 so the vault
///         links them via DELEGATECALL stubs instead of inlining the bodies.
///         Behaviour is identical to the original internal helpers.
library VaultMath {
    uint256 internal constant Q96 = 1 << 96;

    /// @notice True when |price(spot) - price(ref)| / price(ref) <= bps / 10000,
    ///         where price = sqrt^2. See LiquidityVaultV2 for overflow notes.
    function priceWithinTolerance(uint160 spot, uint160 ref, uint256 bps)
        external
        pure
        returns (bool)
    {
        uint256 step1 = FullMath.mulDiv(uint256(spot), uint256(spot), uint256(ref));
        uint256 ratio = FullMath.mulDiv(step1, 1e18, uint256(ref));
        uint256 ONE = 1e18;
        uint256 tol = (ONE * bps) / 10_000;
        return ratio >= ONE ? (ratio - ONE) <= tol : (ONE - ratio) <= tol;
    }

    /// @notice Clamp `sqrtP` into [sqrtAtTick(tickLower), sqrtAtTick(tickUpper)].
    function clampQuotePrice(uint160 sqrtP, int24 tickLower, int24 tickUpper)
        external
        pure
        returns (uint256)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP < sqrtA) return uint256(sqrtA);
        if (sqrtP > sqrtB) return uint256(sqrtB);
        return uint256(sqrtP);
    }

    function quoteToken0ToToken1(uint256 amount0, uint256 sqrtPriceX96)
        external
        pure
        returns (uint256)
    {
        if (amount0 == 0) return 0;
        uint256 token1Partial = FullMath.mulDiv(amount0, sqrtPriceX96, Q96);
        return FullMath.mulDiv(token1Partial, sqrtPriceX96, Q96);
    }

    function quoteToken1ToToken0(uint256 amount1, uint256 sqrtPriceX96)
        external
        pure
        returns (uint256)
    {
        if (amount1 == 0) return 0;
        uint256 token0Partial = FullMath.mulDiv(amount1, Q96, sqrtPriceX96);
        return FullMath.mulDiv(token0Partial, Q96, sqrtPriceX96);
    }
}
