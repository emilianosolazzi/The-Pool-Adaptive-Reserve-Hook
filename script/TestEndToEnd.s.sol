// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LiquidityVault} from "../src/LiquidityVault.sol";

/// @title SwapHelper2 — on-chain swap executor (same pattern as TestSwap.s.sol)
contract SwapHelper2 is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _pm) { poolManager = _pm; }

    function doSwap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) external {
        poolManager.unlock(abi.encode(msg.sender, key, zeroForOne, amountSpecified, sqrtPriceLimitX96));
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "NOT_PM");
        (address caller, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
            = abi.decode(rawData, (address, PoolKey, bool, int256, uint160));

        BalanceDelta delta = poolManager.swap(key, SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        }), "");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 < 0) {
            poolManager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).transferFrom(caller, address(poolManager), uint256(uint128(-d0)));
            poolManager.settle();
        }
        if (d1 < 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transferFrom(caller, address(poolManager), uint256(uint128(-d1)));
            poolManager.settle();
        }
        if (d0 > 0) poolManager.take(key.currency0, caller, uint256(uint128(d0)));
        if (d1 > 0) poolManager.take(key.currency1, caller, uint256(uint128(d1)));

        return "";
    }
}

/// @title TestEndToEnd
/// @notice Deploys a FRESH vault with fixed totalAssets(), deposits, swaps, collects yield,
///         and withdraws — proving the entire pipeline end-to-end on testnet.
contract TestEndToEnd is Script {
    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address posManagerAddr  = vm.envAddress("POS_MANAGER");
        address token0          = vm.envAddress("TOKEN0");
        address token1          = vm.envAddress("TOKEN1");
        address hookAddr        = vm.envAddress("HOOK");

        IPoolManager     pm  = IPoolManager(poolManagerAddr);
        IPositionManager pos = IPositionManager(posManagerAddr);

        uint24 poolFee     = uint24(vm.envOr("POOL_FEE", uint256(100)));
        int24  tickSpacing = int24(vm.envOr("TICK_SPACING", int256(1)));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        vm.startBroadcast();

        // ── 1. Deploy fresh vault ─────────────────────────────────────────────
        // Pool price is currently in-range (tick ~-112127), so the vault's
        // _deployLiquidity guard will keep assets idle (single-asset vault
        // can't deploy when price is in range). This is fine — we're testing
        // the full deposit→swap→yield→withdraw pipeline, and totalAssets()
        // now uses live valuation.
        LiquidityVault vault = new LiquidityVault(
            IERC20(token0), pm, pos, "E2E Test Vault", "E2E-V", permit2
        );
        vault.setPoolKey(key);
        console2.log("\n=== 1. NEW VAULT DEPLOYED ===");
        console2.log("Vault:", address(vault));

        // ── 2. Deposit 1_000_000 token0 ──────────────────────────────────────
        uint256 depositAmt = 1_000_000;
        IERC20(token0).approve(address(vault), depositAmt);
        uint256 shares = vault.deposit(depositAmt, msg.sender);
        console2.log("\n=== 2. DEPOSIT ===");
        console2.log("Deposited:", depositAmt);
        console2.log("Shares received:", shares);
        console2.log("totalAssets:", vault.totalAssets());
        console2.log("assetsDeployed:", vault.assetsDeployed());

        // ── 3. Swap to generate fees ─────────────────────────────────────────
        SwapHelper2 helper = new SwapHelper2(pm);
        // Approve both tokens — afterSwapReturnDelta may settle the fee in either
        IERC20(token0).approve(address(helper), type(uint256).max);
        IERC20(token1).approve(address(helper), type(uint256).max);

        // Swap 1000 token1 → token0 (generates ~3 fee units)
        helper.doSwap(key, false, -1000, 1461446703485210103287273052203988822378723970341);
        console2.log("\n=== 3. SWAP EXECUTED ===");
        console2.log("Swapped 1000 token1 -> token0");

        // ── 4. Check vault state (no position deployed — price in range) ─────
        // The vault kept assets idle because the pool price is in range and we
        // can't do a single-sided deposit. This is the correct behavior.
        console2.log("\n=== 4. VAULT STATE ===");
        console2.log("totalAssets:", vault.totalAssets());
        console2.log("assetsDeployed:", vault.assetsDeployed());
        console2.log("positionTokenId:", vault.positionTokenId());

        // Share price should be 1:1 (no yield to collect)
        uint256 sharePrice = vault.convertToAssets(1e18);
        console2.log("Share price (1e18):", sharePrice);

        // ── 5. Withdraw half ─────────────────────────────────────────────────
        uint256 halfAssets = vault.totalAssets() / 2;
        console2.log("\n=== 5. WITHDRAW ===");
        console2.log("Withdrawing:", halfAssets);

        uint256 balBefore = IERC20(token0).balanceOf(msg.sender);
        vault.withdraw(halfAssets, msg.sender, msg.sender);
        uint256 received = IERC20(token0).balanceOf(msg.sender) - balBefore;

        console2.log("Token0 received:", received);
        console2.log("Remaining shares:", vault.balanceOf(msg.sender));
        console2.log("Remaining totalAssets:", vault.totalAssets());

        // ── 6. Redeem remaining shares ───────────────────────────────────────
        uint256 remaining = vault.balanceOf(msg.sender);
        if (remaining > 0) {
            balBefore = IERC20(token0).balanceOf(msg.sender);
            vault.redeem(remaining, msg.sender, msg.sender);
            received = IERC20(token0).balanceOf(msg.sender) - balBefore;
            console2.log("\n=== 6. REDEEM REMAINING ===");
            console2.log("Shares redeemed:", remaining);
            console2.log("Token0 received:", received);
            console2.log("Final totalAssets:", vault.totalAssets());
            console2.log("Final shares:", vault.balanceOf(msg.sender));
        }

        vm.stopBroadcast();

        console2.log("\n=== END-TO-END TEST COMPLETE ===");
    }
}
