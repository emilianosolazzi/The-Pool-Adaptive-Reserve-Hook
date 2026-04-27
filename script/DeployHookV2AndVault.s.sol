// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";
import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {SwapRouter02ZapAdapter, ISwapRouter02ExactInputSingle} from "../src/SwapRouter02ZapAdapter.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @notice Canonical V2.1 deploy: HookV2 (with reserve-sale) + FeeDistributor +
///         LiquidityVaultV2 (fair zap) + pool initialisation + vault registration.
/// @dev    Required env: POOL_MANAGER, POS_MANAGER, TOKEN0, TOKEN1, ASSET_TOKEN,
///         POOL_FEE, TICK_SPACING, INIT_SQRT_PRICE_X96, V2_TICK_LOWER, V2_TICK_UPPER,
///         PERMIT2, TREASURY, SWAP_ROUTER_02 (or pass ZAP_ROUTER directly).
contract DeployHookV2AndVault is Script {
    address constant DETERMINISTIC_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Cfg {
        address poolManagerAddr;
        address posManagerAddr;
        address token0;
        address token1;
        address assetToken;
        address permit2;
        address treasury;
        address zapRouter;
        address swapRouter02;
        uint24  poolFee;
        int24   tickSpacing;
        uint160 sqrtPrice;
        int24   tickLower;
        int24   tickUpper;
        uint24  zapPoolFee;
        uint256 perfFeeBps;
        uint256 maxTVL;
        uint256 maxFeeBps;
    }

    function _loadCfg() internal view returns (Cfg memory c) {
        c.poolManagerAddr = vm.envAddress("POOL_MANAGER");
        c.posManagerAddr  = vm.envAddress("POS_MANAGER");
        c.token0          = vm.envAddress("TOKEN0");
        c.token1          = vm.envAddress("TOKEN1");
        c.assetToken      = vm.envAddress("ASSET_TOKEN");
        c.permit2         = vm.envAddress("PERMIT2");
        c.treasury        = vm.envOr("TREASURY", msg.sender);
        c.zapRouter       = vm.envOr("ZAP_ROUTER", address(0));
        c.swapRouter02    = vm.envOr("SWAP_ROUTER_02", address(0));
        c.poolFee         = uint24(vm.envUint("POOL_FEE"));
        c.tickSpacing     = int24(vm.envInt("TICK_SPACING"));
        c.sqrtPrice       = uint160(vm.envUint("INIT_SQRT_PRICE_X96"));
        c.tickLower       = int24(vm.envInt("V2_TICK_LOWER"));
        c.tickUpper       = int24(vm.envInt("V2_TICK_UPPER"));
        c.zapPoolFee      = uint24(vm.envOr("ZAP_POOL_FEE", uint256(uint24(c.poolFee))));
        c.perfFeeBps      = vm.envOr("PERFORMANCE_FEE_BPS", uint256(400));
        c.maxTVL          = vm.envOr("MAX_TVL", uint256(0));
        c.maxFeeBps       = vm.envOr("MAX_FEE_BPS", uint256(50));
    }

    function run() external {
        Cfg memory c = _loadCfg();

        require(c.token0 < c.token1, "TOKEN_ORDER");
        require(c.assetToken == c.token0 || c.assetToken == c.token1, "ASSET_NOT_IN_POOL");
        require(c.tickLower < c.tickUpper, "TICK_ORDER");
        require(c.tickLower % c.tickSpacing == 0 && c.tickUpper % c.tickSpacing == 0, "TICK_SPACING");

        IPoolManager     poolManager = IPoolManager(c.poolManagerAddr);
        IPositionManager posManager  = IPositionManager(c.posManagerAddr);

        // ── Mine HookV2 salt before broadcast ────────────────────────────────
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address deployerAddr = msg.sender;
        // FeeDistributor is the FIRST contract deployed in the broadcast, so
        // its address is deterministic from the deployer's current nonce.
        address expectedDistributor = vm.computeCreateAddress(deployerAddr, vm.getNonce(deployerAddr));
        (address hookAddr, bytes32 salt) = HookMiner.find(
            DETERMINISTIC_CREATE2_FACTORY,
            flags,
            type(DynamicFeeHookV2).creationCode,
            abi.encode(address(poolManager), expectedDistributor, deployerAddr)
        );

        vm.startBroadcast();

        // 1. FeeDistributor (hook address known but not yet deployed; we'll wire after).
        FeeDistributor distributor = new FeeDistributor(poolManager, c.treasury, address(0));
        require(address(distributor) == expectedDistributor, "DIST_ADDR_DRIFT");
        console2.log("FeeDistributor:", address(distributor));

        // 2. HookV2 via CREATE2.
        DynamicFeeHookV2 hook = new DynamicFeeHookV2{salt: salt}(
            poolManager, address(distributor), deployerAddr
        );
        require(address(hook) == hookAddr, "HOOK_ADDR_DRIFT");
        if (c.maxFeeBps != 50) hook.setMaxFeeBps(c.maxFeeBps);
        console2.log("DynamicFeeHookV2:", address(hook));

        // 3. Wire distributor -> hook.
        distributor.setHook(address(hook));

        // 4. Initialise pool with HookV2.
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(c.token0),
            currency1:   Currency.wrap(c.token1),
            fee:         c.poolFee,
            tickSpacing: c.tickSpacing,
            hooks:       IHooks(address(hook))
        });
        poolManager.initialize(key, c.sqrtPrice);
        distributor.setPoolKey(key);

        // 5. Optional zap-adapter (idempotent: caller may pre-supply ZAP_ROUTER).
        address zap = c.zapRouter;
        if (zap == address(0)) {
            require(c.swapRouter02 != address(0), "SWAP_ROUTER_02_REQUIRED");
            SwapRouter02ZapAdapter adapter = new SwapRouter02ZapAdapter(
                ISwapRouter02ExactInputSingle(c.swapRouter02),
                c.zapPoolFee
            );
            zap = address(adapter);
            console2.log("SwapRouter02ZapAdapter:", zap);
        }

        // 6. LiquidityVaultV2 + bind.
        LiquidityVaultV2 vault = new LiquidityVaultV2(
            IERC20(c.assetToken),
            poolManager,
            posManager,
            "The Pool Zap LP Vault V2.1",
            "pZAP-LPV21",
            c.permit2,
            zap
        );
        vault.setPoolKey(key);
        vault.rebalance(c.tickLower, c.tickUpper, 0);
        vault.setReserveHook(address(hook));
        vault.setTreasury(c.treasury);
        if (c.perfFeeBps > 0) vault.setPerformanceFeeBps(c.perfFeeBps);
        if (c.maxTVL > 0) vault.setMaxTVL(c.maxTVL);

        // 7. Hook ↔ vault binding (one-shot).
        hook.registerVault(key, address(vault));

        vm.stopBroadcast();

        console2.log("=== V2.1 Deployment ===");
        console2.log("FeeDistributor   :", address(distributor));
        console2.log("DynamicFeeHookV2 :", address(hook));
        console2.log("LiquidityVaultV2 :", address(vault));
        console2.log("ZapRouter        :", zap);
        console2.log("Treasury         :", c.treasury);
        console2.log("Pool sqrtPriceX96:", c.sqrtPrice);
        console2.log("Tick lower       :", int256(c.tickLower));
        console2.log("Tick upper       :", int256(c.tickUpper));
    }
}
