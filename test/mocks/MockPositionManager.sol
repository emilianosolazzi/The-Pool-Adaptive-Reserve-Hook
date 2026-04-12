// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal PositionManager stub.
///      nextTokenId() returns a monotonic counter.
///      modifyLiquidities() is a no-op (tokens stay in caller for mock accounting).
contract MockPositionManager {
    uint256 private _nextId = 1;
    uint256 public callCount;

    function nextTokenId() external view returns (uint256) {
        return _nextId;
    }

    function modifyLiquidities(bytes calldata, uint256) external payable {
        _nextId++;
        callCount++;
    }
}
