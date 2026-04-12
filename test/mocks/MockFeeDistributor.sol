// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Records distribute() calls without routing funds anywhere.
contract MockFeeDistributor {
    Currency public lastCurrency;
    uint256 public lastAmount;
    uint256 public callCount;

    function distribute(Currency currency, uint256 amount) external {
        lastCurrency = currency;
        lastAmount = amount;
        callCount++;
    }
}
