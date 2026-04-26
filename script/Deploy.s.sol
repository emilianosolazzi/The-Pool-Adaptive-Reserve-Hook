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
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

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
///      ASSET_TOKEN         Which side of the pool is the vault underlying
///                          [default: TOKEN0]. Must equal TOKEN0 or TOKEN1.
///                          e.g. on Arbitrum WETH/USDC, WETH sorts below USDC,
///                          so set ASSET_TOKEN=TOKEN1 (USDC) for a USDC-deposit vault.
///      PERFORMANCE_FEE_BPS Vault performance fee in basis points  [default: 400 = 4%]
///      MAX_TVL             Vault deposit ceiling in asset-token units [default: 0 = unlimited]
///      MAX_FEE_BPS         Hook swap fee ceiling in basis points   [default: 50 = 0.5%]
///      POOL_FEE            Uniswap v4 pool fee tier (uint24)       [default: 100 = 0.01%]
///      TICK_SPACING        Pool tick spacing (int24)               [default: 1]
///      SQRT_PRICE_X96      Initial pool price as Q64.96            [default: 1:1]
///      OWNER               Multisig address to set as timelock proposer [default: no timelock, deployer keeps ownership]
///      TIMELOCK_DELAY      Seconds before queued owner actions execute  [default: 172800 = 48 h]
///                          When OWNER is set a TimelockController is deployed and ownership of all
///                          three contracts is transferred to it. The multisig (OWNER) must then
///                          call acceptOwnership() on each contract via the timelock.
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
        uint256 perfFeeBps  = vm.envOr("PERFORMANCE_FEE_BPS", uint256(400));   // 4%
        uint256 maxTVL      = vm.envOr("MAX_TVL",             uint256(0));      // unlimited
        uint256 maxFeeBps   = vm.envOr("MAX_FEE_BPS",         uint256(50));     // 0.5%
        uint24  poolFee     = uint24(vm.envOr("POOL_FEE",     uint256(100)));   // 0.01%
        int24   tickSpacing = int24(vm.envOr("TICK_SPACING",  int256(1)));
        uint160 sqrtPrice   = uint160(vm.envOr("SQRT_PRICE_X96", uint256(DEFAULT_SQRT_PRICE)));
        // Choose which side of the pool is the vault underlying asset. Defaults to
        // currency0. Set to TOKEN1 when the desired deposit token sorts higher
        // (e.g. USDC on a WETH/USDC Arbitrum pool).
        address assetTokenAddr = vm.envOr("ASSET_TOKEN", token0Addr);
        require(
            assetTokenAddr == token0Addr || assetTokenAddr == token1Addr,
            "ASSET_TOKEN must equal TOKEN0 or TOKEN1"
        );
        // If set, a TimelockController is deployed with OWNER as proposer and ownership
        // of all three contracts is transferred to it. Set to address(0) to skip (deployer keeps ownership).
        address owner          = vm.envOr("OWNER", address(0));
        uint256 timelockDelay  = vm.envOr("TIMELOCK_DELAY", uint256(2 days)); // default 48 h

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

        // Foundry routes `new Contract{salt: salt}()` through the deterministic
        // CREATE2 factory (0x4e59b44847b379578588920cA78FbF26c0B4956C), NOT the
        // EOA directly. HookMiner must use the factory address so the computed
        // hook address matches what actually gets deployed on-chain.
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            create2Factory,
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

        // ── 2. LiquidityVault (ERC-4626, single-sided on ASSET_TOKEN) ────────
        // The vault accepts deposits of ASSET_TOKEN only. It deploys liquidity
        // as a single-sided out-of-range position on whichever side of the pool
        // ASSET_TOKEN sits on (token0 or token1). Owner calls rebalance() to
        // reposition ticks when market conditions change.
        LiquidityVault vault = new LiquidityVault(
            IERC20(assetTokenAddr),
            poolManager,
            posManager,
            "DeFi Hook LP Vault",
            "dHOOK-LPV",
            0x000000000022D473030F116dDEE9F6B43aC78BA3  // canonical Permit2
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

        // ── 7. Deploy timelock + transfer ownership (optional) ───────────────
        // When OWNER is provided: deploy a TimelockController (proposer = OWNER,
        // open executor, admin = OWNER) and initiate Ownable2Step transfer to it.
        // The multisig must complete each handoff by calling acceptOwnership() on
        // each contract via the timelock after the delay expires.
        // Skip entirely if OWNER is not set — deployer retains ownership.
        address timelockAddr = address(0);
        if (owner != address(0)) {
            address[] memory proposers = new address[](1);
            proposers[0] = owner;
            address[] memory executors = new address[](1);
            executors[0] = address(0); // open execution: anyone can execute after delay

            TimelockController timelock = new TimelockController(
                timelockDelay, proposers, executors, owner
            );
            timelockAddr = address(timelock);

            distributor.transferOwnership(timelockAddr);
            vault.transferOwnership(timelockAddr);
            hook.transferOwnership(timelockAddr);
            console2.log("TimelockController deployed:", timelockAddr);
            console2.log("Ownership transfer initiated to timelock:", timelockAddr);
            console2.log("Timelock proposer (multisig):", owner);
            console2.log("Timelock delay (seconds):", timelockDelay);
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
        console2.log("Timelock        :", timelockAddr == address(0) ? address(0) : timelockAddr);
        console2.log("Timelock Delay  :", timelockDelay);
        console2.log("Effective Owner :", timelockAddr != address(0) ? timelockAddr : deployerAddr);
    }
}
