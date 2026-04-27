// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeDistributor} from "../src/FeeDistributor.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {BootstrapRewards} from "../src/BootstrapRewards.sol";

/// @notice One-shot redeploy of FeeDistributor + LiquidityVault + BootstrapRewards,
///         init a fresh pool at the correct ETH price, repoint the EXISTING hook.
///
/// @dev    The hook (0x62076...) is preserved — that is the audit-listed contract.
///         setPoolKey on the old vault/distributor is permanently locked, hence the
///         redeploy. setFeeDistributor on the hook is owner-mutable; that is what
///         lets us swap the distributor without redeploying the hook.
///
/// Required env vars (all already present in .env):
///   POOL_MANAGER, POS_MANAGER, TOKEN0, TOKEN1, ASSET_TOKEN, TREASURY, PERMIT2
///
/// Optional env vars (sane defaults):
///   POOL_FEE          (default 500    = 0.05% — must differ from the existing pool key)
///   TICK_SPACING      (default 60     — must differ from the existing pool key (10))
///   INIT_TICK         (default -198060 ≈ ETH at $2,500, multiple of 60)
///   HOOK_ADDR         (default 0x62076C1Cb0Ea57Acd2353fF45226a1FB1e6100c4 — current hook)
///   BOOTSTRAP_PROGRAM_START (default block.timestamp)
///
/// Run:
///   forge script script/RedeployNonHook.s.sol:RedeployNonHook \
///     --rpc-url $ARBITRUM_RPC_URL \
///     --ledger --sender $SENDER \
///     --broadcast \
///     --verify --etherscan-api-key $ETHERSCAN_API_KEY \
///     --verifier-url "https://api.etherscan.io/v2/api?chainid=42161"
contract RedeployNonHook is Script {
    // Bootstrap config — must match script/DeployBootstrap.s.sol so the program
    // continues with identical economics.
    uint64 internal constant EPOCH_LENGTH = 30 days;
    uint32 internal constant EPOCH_COUNT = 6;
    uint64 internal constant DWELL = 7 days;
    uint64 internal constant CLAIM_WINDOW = 90 days;
    uint64 internal constant FINALIZATION_DELAY = 7 days;
    uint16 internal constant BONUS_BPS = 5_000; // 50%
    uint256 internal constant PER_EPOCH_CAP_ASSET = 10_000e6;     // $10k USDC
    uint256 internal constant PER_WALLET_CAP_ASSET = 25_000e6;    // $25k USDC
    uint256 internal constant GLOBAL_CAP_ASSET = 100_000e6;       // $100k USDC

    function run() external {
        // ── Inputs ──────────────────────────────────────────────────────────
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address posManagerAddr  = vm.envAddress("POS_MANAGER");
        address token0Addr      = vm.envAddress("TOKEN0");
        address token1Addr      = vm.envAddress("TOKEN1");
        address assetTokenAddr  = vm.envAddress("ASSET_TOKEN");
        address treasury        = vm.envAddress("TREASURY");
        address permit2         = vm.envAddress("PERMIT2");

        require(token0Addr < token1Addr, "TOKEN0 must sort below TOKEN1");
        require(
            assetTokenAddr == token0Addr || assetTokenAddr == token1Addr,
            "ASSET_TOKEN must equal TOKEN0 or TOKEN1"
        );

        uint24  poolFee     = uint24(vm.envOr("POOL_FEE",     uint256(500)));
        int24   tickSpacing = int24(vm.envOr("TICK_SPACING",  int256(60)));
        int24   initTick    = int24(vm.envOr("INIT_TICK",     int256(-198060)));
        address hookAddr    = vm.envOr("HOOK_ADDR", address(0x62076C1Cb0Ea57Acd2353fF45226a1FB1e6100c4));

        // initTick must be a multiple of tickSpacing or PoolManager will revert.
        require(initTick % tickSpacing == 0, "INIT_TICK not multiple of TICK_SPACING");

        IPoolManager     poolManager = IPoolManager(poolManagerAddr);
        IPositionManager posManager  = IPositionManager(posManagerAddr);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initTick);
        uint64 programStart = uint64(vm.envOr("BOOTSTRAP_PROGRAM_START", uint256(block.timestamp)));

        // ── Sanity log before broadcasting ──────────────────────────────────
        console2.log("=== Inputs ===");
        console2.log("PoolManager   :", poolManagerAddr);
        console2.log("PosManager    :", posManagerAddr);
        console2.log("token0        :", token0Addr);
        console2.log("token1        :", token1Addr);
        console2.log("assetToken    :", assetTokenAddr);
        console2.log("treasury (EOA):", treasury);
        console2.log("hook (reused) :", hookAddr);
        console2.log("poolFee       :", uint256(poolFee));
        console2.log("tickSpacing   :", int256(tickSpacing));
        console2.log("initTick      :", int256(initTick));
        console2.log("sqrtPriceX96  :", uint256(sqrtPriceX96));
        console2.log("programStart  :", uint256(programStart));

        vm.startBroadcast();

        // ── 1. New FeeDistributor ───────────────────────────────────────────
        // Treasury starts as `treasury` (EOA) so we can call setTreasury() to
        // route to the bootstrap once it's deployed. Hook is set in constructor.
        FeeDistributor distributor = new FeeDistributor(poolManager, treasury, hookAddr);
        console2.log("FeeDistributor:", address(distributor));

        // ── 2. New LiquidityVault ───────────────────────────────────────────
        LiquidityVault vault = new LiquidityVault(
            IERC20(assetTokenAddr),
            poolManager,
            posManager,
            "DeFi Hook LP Vault",
            "dHOOK-LPV",
            permit2
        );
        console2.log("LiquidityVault:", address(vault));

        // ── 3. New BootstrapRewards ─────────────────────────────────────────
        // Wired to the new vault. perWalletShareCap / globalShareCap are
        // 1:1 with asset units while supply == 0 (vault hasn't taken deposits
        // yet), so use the asset-denominated caps directly.
        BootstrapRewards.Config memory cfg = BootstrapRewards.Config({
            vault: IERC20(address(vault)),
            payoutAsset: IERC20(assetTokenAddr),
            realTreasury: treasury,
            programStart: programStart,
            epochLength: EPOCH_LENGTH,
            epochCount: EPOCH_COUNT,
            dwellPeriod: DWELL,
            claimWindow: CLAIM_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            bonusShareBps: BONUS_BPS,
            perEpochCap: PER_EPOCH_CAP_ASSET,
            perWalletShareCap: PER_WALLET_CAP_ASSET,
            globalShareCap: GLOBAL_CAP_ASSET
        });
        BootstrapRewards bootstrap = new BootstrapRewards(cfg);
        console2.log("BootstrapRewards:", address(bootstrap));

        // ── 4. Wire bootstrap as the distributor's treasury ─────────────────
        distributor.setTreasury(address(bootstrap));

        // ── 5. Initialize the new pool ──────────────────────────────────────
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });
        poolManager.initialize(key, sqrtPriceX96);

        // ── 6. Pin pool key on new contracts (one-shot, never repointable) ──
        distributor.setPoolKey(key);
        vault.setPoolKey(key);

        // ── 7. Repoint the EXISTING hook at the new distributor ─────────────
        // Owner-only call — caller (deployer) must equal hook.owner().
        IDynamicFeeHookLike(hookAddr).setFeeDistributor(address(distributor));

        vm.stopBroadcast();

        console2.log("=== Done. Paste into web/lib/deployments.ts ===");
        console2.log("vault       =", address(vault));
        console2.log("distributor =", address(distributor));
        console2.log("bootstrap   =", address(bootstrap));
        console2.log("tickSpacing =", int256(tickSpacing));
        console2.log("poolFee     =", uint256(poolFee));
    }
}

interface IDynamicFeeHookLike {
    function setFeeDistributor(address newDistributor) external;
}
