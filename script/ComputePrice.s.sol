// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract ComputePrice is Script {
    function run() external pure {
        int24 tickLower = -230270;
        int24 tickUpper = -69082;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // For single-sided token0 deposit: price must be BELOW tickLower
        // so the entire position is in token0 (out of range on the low side)
        int24 initTick = tickLower - 10;  // safely below tickLower
        uint160 sqrtPriceInit = TickMath.getSqrtPriceAtTick(initTick);

        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);
        console2.log("sqrtPriceLower:", uint256(sqrtPriceLower));
        console2.log("sqrtPriceUpper:", uint256(sqrtPriceUpper));
        console2.log("");
        console2.log("initTick (below range):", initTick);
        console2.log("sqrtPriceInit:         ", uint256(sqrtPriceInit));
        console2.log("");
        console2.log("Set in .env:");
        console2.log("SQRT_PRICE_X96=", uint256(sqrtPriceInit));
    }
}
