// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal stub. nextTokenId() auto-increments; modifyLiquidities() is a no-op.
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
