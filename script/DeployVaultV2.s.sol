// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {SwapRouter02ZapAdapter, ISwapRouter02ExactInputSingle} from "../src/SwapRouter02ZapAdapter.sol";

/// @notice Deploys a zap-enabled vault for an existing hooked v4 pool.
/// @dev This does not redeploy or mutate the hook/distributor/pool. It only
///      deploys a new ERC-4626 vault and pins it to the existing PoolKey.
contract DeployVaultV2 is Script {
    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address posManagerAddr = vm.envAddress("POS_MANAGER");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        address assetToken = vm.envAddress("ASSET_TOKEN");
        address hookAddr = vm.envAddress("HOOK");
        address permit2 = vm.envAddress("PERMIT2");
        address zapRouter = vm.envOr("ZAP_ROUTER", address(0));
        address swapRouter02 = vm.envOr("SWAP_ROUTER_02", address(0));
        address treasury = vm.envOr("TREASURY", msg.sender);

        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(500)));
        uint24 zapPoolFee = uint24(vm.envOr("ZAP_POOL_FEE", uint256(500)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(60)));
        int24 tickLower = int24(vm.envOr("V2_TICK_LOWER", int256(-199020)));
        int24 tickUpper = int24(vm.envOr("V2_TICK_UPPER", int256(-198840)));
        uint256 perfFeeBps = vm.envOr("PERFORMANCE_FEE_BPS", uint256(400));
        uint256 maxTVL = vm.envOr("MAX_TVL", uint256(0));

        require(token0 < token1, "TOKEN_ORDER");
        require(assetToken == token0 || assetToken == token1, "ASSET_NOT_IN_POOL");
        require(tickLower < tickUpper, "TICK_ORDER");
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0, "TICK_SPACING");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast();

        if (zapRouter == address(0)) {
            require(swapRouter02 != address(0), "SWAP_ROUTER_02_REQUIRED");
            SwapRouter02ZapAdapter adapter = new SwapRouter02ZapAdapter(
                ISwapRouter02ExactInputSingle(swapRouter02),
                zapPoolFee
            );
            zapRouter = address(adapter);
        }

        LiquidityVaultV2 vault = new LiquidityVaultV2(
            IERC20(assetToken),
            IPoolManager(poolManagerAddr),
            IPositionManager(posManagerAddr),
            "The Pool Zap LP Vault",
            "pZAP-LPV",
            permit2,
            zapRouter
        );
        vault.setPoolKey(key);
        vault.rebalance(tickLower, tickUpper, 0);
        vault.setTreasury(treasury);
        if (perfFeeBps > 0) vault.setPerformanceFeeBps(perfFeeBps);
        if (maxTVL > 0) vault.setMaxTVL(maxTVL);

        vm.stopBroadcast();

        console2.log("LiquidityVaultV2:", address(vault));
        console2.log("asset          :", assetToken);
        console2.log("zapAdapter     :", zapRouter);
        console2.log("treasury       :", treasury);
        console2.log("tickLower      :", int256(tickLower));
        console2.log("tickUpper      :", int256(tickUpper));
        console2.log("poolFee        :", uint256(poolFee));
        console2.log("zapPoolFee     :", uint256(zapPoolFee));
        console2.log("tickSpacing    :", int256(tickSpacing));
    }
}