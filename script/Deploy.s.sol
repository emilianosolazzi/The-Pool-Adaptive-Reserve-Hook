// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title Deploy
/// @notice Deploys the full DeFi Hook Protocol stack in dependency order:
///         FeeDistributor → LiquidityVault → DynamicFeeHook → configure → init pool
///
/// @dev Required env vars (copy .env.example → .env and fill in):
///
///      POOL_MANAGER        Uniswap v4 PoolManager address
///      POS_MANAGER         Uniswap v4 PositionManager address
///      TOKEN0              Pool currency0 (must be lower address than TOKEN1)
///      TOKEN1              Pool currency1
///      TREASURY            Receives treasury split + protocol performance fees
///
/// @dev Optional env vars (have safe defaults):
///
///      PERFORMANCE_FEE_BPS Vault performance fee in basis points  [default: 500 = 5%]
///      MAX_TVL             Vault deposit ceiling in asset-token units [default: 0 = unlimited]
///      MAX_FEE_BPS         Hook swap fee ceiling in basis points   [default: 50 = 0.5%]
///      POOL_FEE            Uniswap v4 pool fee tier (uint24)       [default: 100 = 0.01%]
///      TICK_SPACING        Pool tick spacing (int24)               [default: 1]
///      SQRT_PRICE_X96      Initial pool price as Q64.96            [default: 1:1]
///      OWNER               Multisig/timelock to receive ownership  [default: deployer keeps ownership]
///                          Recipient must call acceptOwnership() on each contract to finalise.
///
/// @dev Run on Arbitrum One:
///      forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract Deploy is Script {
    // 1:1 price expressed as sqrt(1) * 2^96
    uint160 constant DEFAULT_SQRT_PRICE = 79228162514264337593543950336;

    function run() external {
        // ── Required env vars ────────────────────────────────────────────────
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address posManagerAddr  = vm.envAddress("POS_MANAGER");
        address token0Addr      = vm.envAddress("TOKEN0");
        address token1Addr      = vm.envAddress("TOKEN1");
        address treasury        = vm.envAddress("TREASURY");

        require(token0Addr < token1Addr, "TOKEN0 must sort below TOKEN1 (Uniswap v4 requirement)");

        // ── Optional env vars ────────────────────────────────────────────────
        uint256 perfFeeBps  = vm.envOr("PERFORMANCE_FEE_BPS", uint256(500));   // 5%
        uint256 maxTVL      = vm.envOr("MAX_TVL",             uint256(0));      // unlimited
        uint256 maxFeeBps   = vm.envOr("MAX_FEE_BPS",         uint256(50));     // 0.5%
        uint24  poolFee     = uint24(vm.envOr("POOL_FEE",     uint256(100)));   // 0.01%
        int24   tickSpacing = int24(vm.envOr("TICK_SPACING",  int256(1)));
        uint160 sqrtPrice   = uint160(vm.envOr("SQRT_PRICE_X96", uint256(DEFAULT_SQRT_PRICE)));
        // If set, ownership of all three contracts is transferred to this address after deploy.
        // The recipient must call acceptOwnership() to complete the Ownable2Step handoff.
        // Defaults to address(0) = no transfer (deployer retains ownership).
        address owner       = vm.envOr("OWNER", address(0));

        IPoolManager     poolManager = IPoolManager(poolManagerAddr);
        IPositionManager posManager  = IPositionManager(posManagerAddr);

        // ── Pre-compute hook salt before broadcast ────────────────────────────
        // HookMiner performs off-chain brute-force iteration — must run outside
        // vm.startBroadcast() so the loop does not pollute the broadcast trace.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        // distributor address is deterministic (nonce 0 of deployer), compute it
        // so the hook constructor arg is known before any contract is deployed.
        address deployerAddr = msg.sender;
        address expectedDistributor = vm.computeCreateAddress(deployerAddr, vm.getNonce(deployerAddr));
        (address hookAddr, bytes32 salt) = HookMiner.find(
            deployerAddr,
            flags,
            type(DynamicFeeHook).creationCode,
            abi.encode(address(poolManager), expectedDistributor)
        );

        vm.startBroadcast();

        // ── 1. FeeDistributor ─────────────────────────────────────────────────
        // Hook address is unknown yet; we resolve the circular dependency in step 4.
        FeeDistributor distributor = new FeeDistributor(poolManager, treasury, address(0));
        require(address(distributor) == expectedDistributor, "Distributor address mismatch -- nonce drift");
        console2.log("FeeDistributor deployed:", address(distributor));

        // ── 2. LiquidityVault (ERC-4626, token0 as underlying asset) ─────────
        LiquidityVault vault = new LiquidityVault(
            IERC20(token0Addr),
            poolManager,
            posManager,
            "DeFi Hook LP Vault",
            "dHOOK-LPV"
        );
        vault.setTreasury(treasury);
        if (perfFeeBps > 0) vault.setPerformanceFeeBps(perfFeeBps);
        if (maxTVL    > 0) vault.setMaxTVL(maxTVL);
        console2.log("LiquidityVault deployed:", address(vault));

        // ── 3. DynamicFeeHook (CREATE2 — address encodes hook permission flags) ─
        DynamicFeeHook hook = new DynamicFeeHook{salt: salt}(poolManager, address(distributor));
        require(address(hook) == hookAddr, "Hook address mismatch -- salt stale");

        if (maxFeeBps != 50) hook.setMaxFeeBps(maxFeeBps); // only emit event if non-default
        console2.log("DynamicFeeHook deployed:", address(hook));

        // ── 4. Wire circular dependency ───────────────────────────────────────
        distributor.setHook(address(hook));

        // ── 5. Initialise pool ────────────────────────────────────────────────
        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(token0Addr),
            currency1:   Currency.wrap(token1Addr),
            fee:         poolFee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(address(hook))
        });

        poolManager.initialize(poolKey, sqrtPrice);
        console2.log("Pool initialised at sqrtPriceX96:", sqrtPrice);

        // ── 6. Register pool key on distributor and vault ─────────────────────
        distributor.setPoolKey(poolKey);
        vault.setPoolKey(poolKey);

        // ── 7. Transfer ownership to multisig / timelock (optional) ──────────
        // Ownable2Step: the new owner must call acceptOwnership() to finalise.
        // Skip if OWNER env var was not set (deployer retains ownership).
        if (owner != address(0)) {
            distributor.transferOwnership(owner);
            vault.transferOwnership(owner);
            hook.transferOwnership(owner);
            console2.log("Ownership transfer initiated to:", owner);
        }

        vm.stopBroadcast();

        // ── Deployment summary ────────────────────────────────────────────────
        console2.log("\n=== Deployment Summary ===");
        console2.log("Network         :", block.chainid);
        console2.log("FeeDistributor  :", address(distributor));
        console2.log("LiquidityVault  :", address(vault));
        console2.log("DynamicFeeHook  :", address(hook));
        console2.log("Treasury        :", treasury);
        console2.log("Perf Fee BPS    :", perfFeeBps);
        console2.log("Max TVL         :", maxTVL);
        console2.log("Max Fee BPS     :", maxFeeBps);
        console2.log("Pending Owner   :", owner == address(0) ? deployerAddr : owner);
    }
}
