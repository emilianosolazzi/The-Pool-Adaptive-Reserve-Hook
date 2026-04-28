// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ILiquidityVaultV2View {
    function paused() external view returns (bool);
    function poolManager() external view returns (IPoolManager);
    function poolKey()
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickSpacing,
            IHooks hooks
        );
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);

    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256 shares) external view returns (uint256);

    function totalDepositors() external view returns (uint256);
    function assetsDeployed() external view returns (uint256);
    function totalYieldCollected() external view returns (uint256);
}

contract VaultLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    enum VaultStatus {
        UNCONFIGURED,
        PAUSED,
        IN_RANGE,
        OUT_OF_RANGE
    }

    function vaultStatus(address vaultAddr) external view returns (VaultStatus) {
        ILiquidityVaultV2View vault = ILiquidityVaultV2View(vaultAddr);
        if (vault.paused()) return VaultStatus.PAUSED;

        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) = vault.poolKey();
        if (Currency.unwrap(c0) == address(0) || Currency.unwrap(c1) == address(0)) {
            return VaultStatus.UNCONFIGURED;
        }

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });

        (uint160 sqrtPriceX96,,,) = vault.poolManager().getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return VaultStatus.UNCONFIGURED;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(vault.tickLower());
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(vault.tickUpper());
        return (sqrtPriceX96 >= sqrtLower && sqrtPriceX96 < sqrtUpper)
            ? VaultStatus.IN_RANGE
            : VaultStatus.OUT_OF_RANGE;
    }

    function poolKeyView(address vaultAddr)
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickSpacing,
            IHooks hooks
        )
    {
        return ILiquidityVaultV2View(vaultAddr).poolKey();
    }

    function getVaultStats(address vaultAddr)
        external
        view
        returns (
            uint256 tvl,
            uint256 sharePrice,
            uint256 depositors,
            uint256 liqDeployed,
            uint256 yieldColl,
            string memory feeDesc
        )
    {
        ILiquidityVaultV2View vault = ILiquidityVaultV2View(vaultAddr);

        tvl = vault.totalAssets();
        if (vault.totalSupply() == 0) {
            sharePrice = 1e18;
        } else {
            uint8 shareDecimals = vault.decimals();
            uint256 oneShareUnit = 10 ** uint256(shareDecimals);
            // LiquidityVaultV2 hardcodes _decimalsOffset() = 6.
            uint256 oneAssetUnit = 10 ** (uint256(shareDecimals) - 6);
            sharePrice = Math.mulDiv(vault.convertToAssets(oneShareUnit), 1e18, oneAssetUnit);
        }

        depositors = vault.totalDepositors();
        liqDeployed = vault.assetsDeployed();
        yieldColl = vault.totalYieldCollected();
        feeDesc = "";
    }
}