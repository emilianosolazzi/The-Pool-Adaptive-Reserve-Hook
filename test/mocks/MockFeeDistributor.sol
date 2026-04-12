// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Minimal stub. Records distribute() calls.
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
