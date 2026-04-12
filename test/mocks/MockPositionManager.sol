// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal stub. nextTokenId() auto-increments; modifyLiquidities() is a no-op
///      unless yield has been queued via queueYield(), in which case it transfers
///      the queued amount to the vault to simulate fee collection.
contract MockPositionManager {
    uint256 private _nextId = 1;
    uint256 public callCount;

    address private _yieldVault;
    address private _yieldToken;
    uint256 private _yieldAmount;

    function nextTokenId() external view returns (uint256) {
        return _nextId;
    }

    /// @dev Pre-load the mock with yield tokens (mint token to address(this) first),
    ///      then call this so the next modifyLiquidities() transfer them to `vault`.
    function queueYield(address vault, address token, uint256 amount) external {
        _yieldVault = vault;
        _yieldToken = token;
        _yieldAmount = amount;
    }

    function modifyLiquidities(bytes calldata, uint256) external payable {
        _nextId++;
        callCount++;
        if (_yieldAmount > 0) {
            IERC20(_yieldToken).transfer(_yieldVault, _yieldAmount);
            _yieldAmount = 0;
        }
    }
}
