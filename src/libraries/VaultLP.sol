// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";

/// @notice Position-manager interaction helpers extracted from
///         LiquidityVaultV2 to keep the vault under EIP-170. Library
///         functions are external -> linked via DELEGATECALL, so storage
///         and address(this) stay the vault's.
///
///         Errors declared here intentionally share selectors with the
///         identically-named errors in LiquidityVaultV2.
library VaultLP {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error RangeNotActive();
    error MinLiquidity();
    error AmountTooLarge();

    struct DeployArgs {
        IPoolManager poolMgr;
        IPositionManager pm;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 positionTokenId;
        uint256 minLiquidity;
        uint256 deadline;
        address permit2;
    }

    /// @notice Mint or increase the vault's v4 position from current idle balances.
    /// @return liquidity liquidity actually added (0 if OOR / insufficient)
    /// @return spent0 token0 balance delta after the call
    /// @return spent1 token1 balance delta after the call
    /// @return newPositionTokenId updated tokenId (assigned on first mint)
    function deployLiquidity(DeployArgs memory a)
        external
        returns (uint128 liquidity, uint256 spent0, uint256 spent1, uint256 newPositionTokenId)
    {
        newPositionTokenId = a.positionTokenId;

        (uint160 sqrtPriceX96,,,) = a.poolMgr.getSlot0(a.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(a.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(a.tickUpper);
        if (sqrtPriceX96 < sqrtLower || sqrtPriceX96 >= sqrtUpper) {
            if (a.minLiquidity != 0) revert RangeNotActive();
            return (0, 0, 0, newPositionTokenId);
        }

        address t0 = Currency.unwrap(a.key.currency0);
        address t1 = Currency.unwrap(a.key.currency1);
        uint256 amt0Max = IERC20(t0).balanceOf(address(this));
        uint256 amt1Max = IERC20(t1).balanceOf(address(this));

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, amt0Max, amt1Max
        );
        if (liquidity == 0) {
            if (a.minLiquidity != 0) revert MinLiquidity();
            return (0, 0, 0, newPositionTokenId);
        }
        if (liquidity < a.minLiquidity) revert MinLiquidity();
        if (amt0Max > type(uint128).max || amt1Max > type(uint128).max) revert AmountTooLarge();

        uint256 b0 = amt0Max;
        uint256 b1 = amt1Max;

        bytes memory actions;
        bytes[] memory params = new bytes[](2);
        if (newPositionTokenId == 0) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params[0] = abi.encode(
                a.key, a.tickLower, a.tickUpper, liquidity,
                uint128(amt0Max), uint128(amt1Max), address(this), ""
            );
            newPositionTokenId = a.pm.nextTokenId();
        } else {
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            params[0] = abi.encode(newPositionTokenId, liquidity, uint128(amt0Max), uint128(amt1Max), "");
        }
        params[1] = abi.encode(a.key.currency0, a.key.currency1);

        _approveForPM(a, amt0Max, amt1Max);
        a.pm.modifyLiquidities(abi.encode(actions, params), a.deadline);

        spent0 = b0 - IERC20(t0).balanceOf(address(this));
        spent1 = b1 - IERC20(t1).balanceOf(address(this));
    }

    function _approveForPM(DeployArgs memory a, uint256 amt0, uint256 amt1) private {
        if (a.permit2 != address(0)) {
            IAllowanceTransfer(a.permit2).approve(
                Currency.unwrap(a.key.currency0), address(a.pm),
                uint160(amt0), uint48(a.deadline)
            );
            IAllowanceTransfer(a.permit2).approve(
                Currency.unwrap(a.key.currency1), address(a.pm),
                uint160(amt1), uint48(a.deadline)
            );
        } else {
            IERC20(Currency.unwrap(a.key.currency0)).forceApprove(address(a.pm), amt0);
            IERC20(Currency.unwrap(a.key.currency1)).forceApprove(address(a.pm), amt1);
        }
    }

    struct RemoveArgs {
        IPoolManager poolMgr;
        IPositionManager pm;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 positionTokenId;
        uint128 liquidityToRemove;
        uint256 slippageBps;
        uint256 deadline;
    }

    /// @notice Decrease the vault's position by `liquidityToRemove` and
    ///         take both currencies into the vault.
    function removeLiquidity(RemoveArgs memory a)
        external
        returns (uint256 exp0, uint256 exp1)
    {
        (uint160 sqrtPriceX96,,,) = a.poolMgr.getSlot0(a.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(a.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(a.tickUpper);
        (exp0, exp1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtLower, sqrtUpper, a.liquidityToRemove
        );
        uint256 amt0Min = exp0 * (10_000 - a.slippageBps) / 10_000;
        uint256 amt1Min = exp1 * (10_000 - a.slippageBps) / 10_000;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(a.positionTokenId, a.liquidityToRemove, amt0Min, amt1Min, "");
        params[1] = abi.encode(a.key.currency0, a.key.currency1, address(this));

        a.pm.modifyLiquidities(abi.encode(actions, params), a.deadline);
    }

    /// @notice Collect accrued fees by issuing a zero-liquidity decrease + take.
    ///         Returns the per-currency balance deltas observed by the vault.
    function collectFees(
        IPositionManager pm,
        PoolKey memory key,
        uint256 positionTokenId,
        uint256 deadline,
        address asset_,
        address other
    ) external returns (uint256 assetGain, uint256 otherGain) {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionTokenId, uint128(0), uint256(0), uint256(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        uint256 assetBefore = IERC20(asset_).balanceOf(address(this));
        uint256 otherBefore = IERC20(other).balanceOf(address(this));

        pm.modifyLiquidities(abi.encode(actions, params), deadline);

        assetGain = IERC20(asset_).balanceOf(address(this)) - assetBefore;
        otherGain = IERC20(other).balanceOf(address(this)) - otherBefore;
    }
}
