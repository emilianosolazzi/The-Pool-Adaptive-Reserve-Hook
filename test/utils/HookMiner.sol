// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Mines a CREATE2 salt so that the deployed hook address has the required flag bits.
library HookMiner {
    uint256 internal constant MAX_LOOP = 200_000;

    /// @param deployer  The address that will call `new Hook{salt: s}(...)` (usually address(this) in tests)
    /// @param flags     The exact lower-14-bit mask required (e.g. BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG)
    /// @param creationCode  `type(MyHook).creationCode`
    /// @param constructorArgs  `abi.encode(arg0, arg1, ...)`
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        uint160 mask = Hooks.ALL_HOOK_MASK;

        for (uint256 i = 0; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = _compute(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & mask == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no valid salt found");
    }

    function _compute(address deployer, bytes32 salt, bytes32 initCodeHash)
        private
        pure
        returns (address addr)
    {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 0x01), shl(96, deployer))
            mstore(add(ptr, 0x15), salt)
            mstore(add(ptr, 0x35), initCodeHash)
            addr := and(keccak256(ptr, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
