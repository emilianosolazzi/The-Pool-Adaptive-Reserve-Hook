// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Seeds a normal dual-sided v4 LP NFT into the hooked pool.
/// @dev This is for live swap/demo depth. It does not change the ERC-4626 vault's
///      single-sided out-of-range position or depositor accounting.
contract SeedActiveLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address posManagerAddr = vm.envAddress("POS_MANAGER");
        address permit2Addr = vm.envAddress("PERMIT2");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        address hookAddr = vm.envAddress("HOOK");

        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(500)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(60)));
        int24 tickLower = int24(vm.envOr("SEED_TICK_LOWER", int256(-199020)));
        int24 tickUpper = int24(vm.envOr("SEED_TICK_UPPER", int256(-198840)));
        uint256 amount0Max = vm.envUint("SEED_AMOUNT0_MAX");
        uint256 amount1Max = vm.envUint("SEED_AMOUNT1_MAX");
        address recipient = vm.envOr("SEED_RECIPIENT", msg.sender);
        uint256 deadlineSeconds = vm.envOr("SEED_DEADLINE_SECONDS", uint256(300));

        require(token0 < token1, "TOKEN_ORDER");
        require(tickLower < tickUpper, "TICK_ORDER");
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0, "TICK_SPACING");
        require(amount0Max <= type(uint128).max && amount1Max <= type(uint128).max, "AMOUNT_TOO_LARGE");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        IPositionManager positionManager = IPositionManager(posManagerAddr);
        IAllowanceTransfer permit2 = IAllowanceTransfer(permit2Addr);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        require(sqrtPriceX96 != 0, "POOL_NOT_INITIALIZED");

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        require(sqrtPriceX96 >= sqrtLower && sqrtPriceX96 < sqrtUpper, "RANGE_NOT_ACTIVE");

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            amount0Max,
            amount1Max
        );
        require(liquidity > 0, "ZERO_LIQUIDITY");

        (uint256 expectedAmount0, uint256 expectedAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            liquidity
        );

        console2.log("PoolManager      :", poolManagerAddr);
        console2.log("PositionManager  :", posManagerAddr);
        console2.log("Hook             :", hookAddr);
        console2.log("Recipient        :", recipient);
        console2.log("tickLower        :", tickLower);
        console2.log("tickUpper        :", tickUpper);
        console2.log("currentSqrtPrice :", sqrtPriceX96);
        console2.log("liquidity        :", uint256(liquidity));
        console2.log("max token0       :", amount0Max);
        console2.log("max token1       :", amount1Max);
        console2.log("expected token0  :", expectedAmount0);
        console2.log("expected token1  :", expectedAmount1);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity,
            uint128(amount0Max),
            uint128(amount1Max),
            recipient,
            ""
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        vm.startBroadcast();

        IERC20(token0).approve(permit2Addr, type(uint256).max);
        IERC20(token1).approve(permit2Addr, type(uint256).max);
        permit2.approve(token0, posManagerAddr, uint160(amount0Max), uint48(block.timestamp + deadlineSeconds));
        permit2.approve(token1, posManagerAddr, uint160(amount1Max), uint48(block.timestamp + deadlineSeconds));

        uint256 expectedTokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + deadlineSeconds);

        vm.stopBroadcast();

        console2.log("minted tokenId   :", expectedTokenId);
    }
}