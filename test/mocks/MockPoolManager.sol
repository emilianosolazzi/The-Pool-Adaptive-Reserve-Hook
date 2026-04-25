// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Minimal pool-manager stub for unit tests.
///      Only implements take() and donate() — the two calls made by our contracts.
contract MockPoolManager {
    event DonateRecorded(uint256 amount0, uint256 amount1);

    function take(Currency currency, address to, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function donate(PoolKey calldata, uint256 amount0, uint256 amount1, bytes calldata)
        external
        returns (BalanceDelta)
    {
        emit DonateRecorded(amount0, amount1);
        return toBalanceDelta(0, 0);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function initialize(PoolKey calldata, uint160) external pure returns (int24) {
        return 0;
    }

    // sqrtPriceX96 = 1 in lowest 160 bits; yields 0 liquidity in LiquidityAmounts which keeps vault accounting clean
    bytes32 private _slot0 = bytes32(uint256(1));

    /// @dev Test helper: configure the bytes32 returned by extsload (and thus
    ///      StateLibrary.getSlot0). Lowest 160 bits = sqrtPriceX96, next 24
    ///      bits = current tick.
    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        _slot0 = bytes32(packed);
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }
}
