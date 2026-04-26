# Architecture — DeFi Hook Protocol

## Overview

The DeFi Hook Protocol is a Uniswap v4 hook system that attaches a dynamic fee layer to a concentrated-liquidity pool and automatically routes collected fees back to LPs and a treasury. An ERC-4626 vault manages the LP position, so depositors hold fungible shares that appreciate as collected asset-token yield accumulates.

Hook donations are not vault-exclusive: the distributor's 80% LP share is donated to pool fee growth, so whichever LP positions are in range at the donation tick earn it pro rata by active liquidity. The vault is a convenience wrapper around one such LP position; it does not receive a privileged fee stream.

The system is four Solidity contracts (`>=0.8.24 <0.9.0`) in a strict dependency chain:

```
Swapper ──► Uniswap v4 PoolManager
                   │ beforeSwap / afterSwap
                   ▼
           DynamicFeeHook           ← hook registered on PoolKey
                   │ transfer + distribute()
                   ▼
           FeeDistributor
            ├─ 20% ──► Treasury address (direct transfer)
            └─ 80% ──► poolManager.donate()  (LP fee growth)
                              │ collectYield / withdraw / rebalance
                              ▼
                       LiquidityVault  (ERC-4626)
                              │ modifyLiquidities() via Permit2
                              ▼
                    v4-periphery PositionManager
```

---

## Contracts

### `BaseHook` (`src/BaseHook.sol`)

Minimal abstract base implementing `IHooks`. Provides:

- `onlyPoolManager` modifier — all hook callbacks revert with `NotPoolManager()` if not called by the registered `PoolManager`.
- `Hooks.validateHookPermissions` called in the constructor — ensures the hook's deployment address encodes the correct permission bits (Uniswap v4 requirement).
- Default `revert HookNotImplemented()` for every callback; subclasses override only what they need.

### `DynamicFeeHook` (`src/DynamicFeeHook.sol`)

Extends `BaseHook` and `Ownable2Step`. Activates `beforeSwap`, `afterSwap`, and `afterSwapReturnDelta` callbacks.

**Fee computation (beforeSwap)**

1. Base fee: `amountIn × 25 BPS` (constant `HOOK_FEE_BPS = 25`).
2. Volatility multiplier: reads current `sqrtPriceX96` via `StateLibrary.getSlot0()`. If it moved ≥ 1 % from `lastSqrtPriceX96`, the fee is scaled by **1.5×** (`VOLATILITY_FEE_MULTIPLIER = 150`).
3. Cap: fee is clamped to `amountIn × maxFeeBps / 10_000` (owner-adjustable, default 50 BPS = 0.5%, hard max 1000 BPS via `setMaxFeeBps`).
4. Fee currency: `currency1` for `zeroForOne` swaps, `currency0` for `!zeroForOne` (fee taken from the output token side).
5. Fee amount and currency address are written to **EIP-1153 transient storage** (`TSTORE`) at fixed slots — no persistent state change crosses the callback boundary.
6. `totalSwaps` is incremented.

**Fee collection (afterSwap)**

1. Reads fee and currency from transient storage (`TLOAD`), then zeroes both slots.
2. If fee is 0, returns early.
3. Pulls the fee from the pool via `poolManager.take(feeCurrency, address(this), fee)`.
4. Transfers fee tokens directly to the `feeDistributor` address via `feeCurrency.transfer()`.
5. Calls `feeDistributor.distribute(feeCurrency, fee)`.
6. Accumulates `totalFeesRouted`.
7. Emits `FeeRouted(currency, amount, swapIndex)`.
8. Updates `lastSqrtPriceX96` only when `block.number > lastSwapBlock` (anti-sandwich).
9. Returns `int128(uint128(fee))` as the `afterSwapReturnDelta` — tells PoolManager this amount was taken.

**Key state**

| Variable | Type | Default | Notes |
|---|---|---|---|
| `LP_FEE` | `uint24` | 100 | Pool's base LP fee (0.01%) |
| `HOOK_FEE_BPS` | `uint256` | 25 | Hook's base fee rate (0.25%) |
| `maxFeeBps` | `uint256` | 50 | Owner-adjustable cap in BPS (max 1000 = 10%) |
| `lastSqrtPriceX96` | `uint160` | 0 | Inter-swap price tracker; 0 = first swap skips volatility check |
| `lastSwapBlock` | `uint256` | 0 | Block of last price-reference update |
| `feeDistributor` | `IFeeDistributor` | set at deploy | Replaceable via `setFeeDistributor()` |
| `totalSwaps` | `uint256` | 0 | Monotonically increasing counter |
| `totalFeesRouted` | `uint256` | 0 | Cumulative fee tokens sent to distributor |

**View helpers**

- `getSwapFeeInfo(amountIn)` — returns fee breakdown: amount, BPS, treasury/LP split in BPS, description string.
- `getVolatilityInfo()` — returns threshold BPS, multiplier %, reference price, reference block.
- `getStats()` — returns `(totalSwaps, totalFeesRouted, distributorAddress)`.

**Anti-sandwich protection**

`lastSqrtPriceX96` is updated in `afterSwap` only when `block.number > lastSwapBlock`. An attacker cannot reset the reference price with a cheap same-block swap to suppress the 1.5× volatility multiplier on a subsequent exploit swap. The reference price always lags at least one block behind the current price.

### `FeeDistributor` (`src/FeeDistributor.sol`)

Extends `Ownable2Step` and `ReentrancyGuard`. Single entry point: `distribute(currency, amount)`.

**Split logic**

```
Treasury  =  amount × 20 / 100      (TREASURY_SHARE = 20)
LPs       =  amount − Treasury      (LP_SHARE = 80)
```

The LP portion is donated back to the pool via Uniswap v4's sync-settle-donate pattern:

```solidity
poolManager.sync(currency);
currency.transfer(address(poolManager), lpAmount);
poolManager.settle();
poolManager.donate(poolKey, amount0, amount1, "");
```

This feeds `feeGrowthGlobal` in the v4 PoolManager, which accrues to all in-range LP positions proportionally.

More precisely, the donation accrues to whichever LP positions are in range at `slot0.tick`, pro rata by active liquidity. The vault only earns its share when its position is active; self-managed LPs with comparable in-range liquidity receive the same donated hook bonuses directly.

**Access control**

- `distribute()` requires `msg.sender == hook` — only the registered hook can trigger fee routing.
- `setHook()` / `setTreasury()` / `setPoolKey()` are owner-only with `Ownable2Step` two-step transfer.
- `setPoolKey()` can only be called once (`_poolKeySet` guard).

**Stats**

| Variable | Notes |
|---|---|
| `totalDistributed` | Cumulative total (treasury + LP) |
| `totalToTreasury` | Cumulative treasury share |
| `totalToLPs` | Cumulative LP share |
| `distributionCount` | Number of `distribute()` calls |

`getLPYieldSummary()` returns `(lpBonusRate=20, totalToLPs, totalToTreasury, distributionCount)`.

### `LiquidityVault` (`src/LiquidityVault.sol`)

Extends `ERC4626`, `Ownable2Step`, `ReentrancyGuard`, and `Pausable`. Manages the single concentrated-liquidity position and handles token approvals through **Permit2** (required by Uniswap v4 PositionManager).

The vault's value proposition is operational convenience: single-sided deposits, ERC-4626 shares, permissionless harvest triggers, and owner-managed range rebalancing. It does not have exclusive access to hook donations; sophisticated users managing their own in-range concentrated position can earn the same pool-level hook donations directly. The default deploy script configures a 5% performance fee on collected asset-token yield, which is a convenience fee rather than access to a privileged rebate stream.

**Permit2 integration**

The v4 PositionManager pulls tokens via the canonical Permit2 contract (`0x000000000022D473030F116dDEE9F6B43aC78BA3`), not standard ERC20 allowances. The vault handles this:

- Constructor: `IERC20(asset).approve(permit2, type(uint256).max)` — one-time ERC20 approval so Permit2 can pull.
- `setPoolKey()`: `IERC20(otherCurrency).approve(permit2, type(uint256).max)` — approves the non-asset token.
- `_approveForPositionManager(amount)`: before each `modifyLiquidities` call, sets Permit2 `IAllowanceTransfer.approve()` for both currencies with 60-second expiry. The non-asset currency gets a 0-amount allowance with valid expiry to prevent `AllowanceExpired(0)` from `SETTLE_PAIR`.
- When `permit2 == address(0)` (test environments with mock PositionManager), falls back to direct ERC20 approve.

**ERC-4626 accounting**

```solidity
if (totalLiquidityDeployed == 0 || assetsDeployed == 0 || !_poolKeySet) {
  totalAssets() = idleAssetBalance;
} else {
  totalAssets() = idleAssetBalance + liveAssetSideValueOfLiquidityAtCurrentPrice;
}
```

`assetsDeployed` is still updated from actual balance deltas on deploy and removal, but it is no longer the sole source of NAV once liquidity is live. `totalAssets()` recomputes the position's current asset-side value with `LiquidityAmounts.getAmountsForLiquidity(...)` at the latest `sqrtPriceX96`, which prevents stale accounting when price moves into range and part of the single-sided position converts into the other token. Only asset-token yield is reflected in `totalAssets()` and ERC-4626 share price under the current implementation.

**ERC-4626 overrides**

- `maxDeposit()` — returns 0 when paused or pool key not set; respects `maxTVL`.
- `maxMint()` — converts `maxDeposit` to shares.
- `maxWithdraw()` / `maxRedeem()` — return 0 when paused.

**Deposit flow**

```
deposit(assets, receiver)          [nonReentrant, whenNotPaused]
  ├── require(assets >= MIN_DEPOSIT)     // MIN_DEPOSIT = 1e6
  ├── require(_poolKeySet)
  ├── TVL cap check (if maxTVL > 0)
  ├── totalDepositors++ (if first deposit for receiver)
  ├── super.deposit()              // mint shares at current share price
  └── _deployLiquidity(assets)     // open/increase a v4 position, or leave assets idle if current price would require both tokens
```

**Withdraw flow**

```
withdraw(assets, receiver, owner)  [nonReentrant, whenNotPaused]
  ├── _collectYield()              // harvest any accrued fees from the position
  ├── proportion = assets / totalAssets
  ├── _removeLiquidity(proportion) // DECREASE_LIQUIDITY + TAKE_PAIR + SWEEP
  ├── super.withdraw()             // burn shares, transfer asset token
  └── totalDepositors-- (if owner balance now 0)
```

**Redeem flow**

```
redeem(shares, receiver, owner)    [nonReentrant, whenNotPaused]
  ├── _collectYield()
  ├── assets = convertToAssets(shares)
  ├── proportion = assets / totalAssets
  ├── _removeLiquidity(proportion) // proportional removal
  ├── super.redeem()               // burn shares, transfer asset token
  └── totalDepositors-- (if owner balance now 0)
```

**Yield collection**

`_collectYield()` calls `modifyLiquidities(DECREASE_LIQUIDITY 0, TAKE_PAIR)` — a zero-liquidity decrease that triggers the position manager to flush accrued fee tokens to the vault. The vault:

1. Measures `balanceAfter − balanceBefore` of the asset token.
2. Checks the other currency's balance delta (guarded by `.code.length > 0` to skip sentinels) and records it in `currency1YieldCollected`, emitting `Currency1YieldCollected`.
3. Leaves non-asset-token yield outside ERC-4626 NAV; it is tracked for accounting but not swapped into the vault asset or reflected in share price.
4. Deducts `performanceFeeBps` from the asset-token yield and transfers the fee to `treasury` via `SafeERC20.safeTransfer()`, emitting `PerformanceFeePaid`.
5. Credits the net asset-token yield to `totalYieldCollected`, emitting `YieldCollected`.
6. Updates `lastYieldUpdate = block.timestamp`.

Callable externally via `collectYield()` (nonReentrant, permissionless).

Under the current implementation, non-asset-token fees are a tracked side balance rather than an auto-compounded vault return. They can later be removed by the owner through `rescueIdle(otherToken)`.

**Liquidity deployment**

`_deployLiquidity(amount)` only deploys when the current price is fully out of range on the asset side. If price is in range or on the opposite side, the position would require both tokens, so the vault returns early and keeps assets idle until the owner rebalances or price moves back to a single-sided region.

When deployment is possible, liquidity is computed from the asset amount:

- If `assetIsToken0`: `LiquidityAmounts.getLiquidityForAmount0(sqrtPrice, sqrtPriceUpper, amount)`
- If `!assetIsToken0`: `LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPrice, amount)`

First call uses `MINT_POSITION + SETTLE_PAIR`. Subsequent calls use `INCREASE_LIQUIDITY + SETTLE_PAIR`. Actual `assetsDeployed` is measured from balance delta, not the theoretical amount.

**Liquidity removal**

`_removeLiquidity(proportion)` uses `DECREASE_LIQUIDITY + TAKE_PAIR + SWEEP`. Slippage is protected via `LiquidityAmounts.getAmountsForLiquidity` with a 0.5% haircut (`× 995 / 1000`).

**Key state**

| Variable | Default | Notes |
|---|---|---|
| `tickLower` | −230 270 | Owner-adjustable via `rebalance()` |
| `tickUpper` | −69 082 | Owner-adjustable via `rebalance()` |
| `treasury` | deployer | Receives performance fees; updatable via `setTreasury()` |
| `performanceFeeBps` | 0 | Fee on yield; max 2 000 (20%) via `setPerformanceFeeBps()` |
| `maxTVL` | 0 | Deposit ceiling in asset units; 0 = unlimited; via `setMaxTVL()` |
| `permit2` | immutable | Canonical Permit2 address or `address(0)` for tests |
| `positionTokenId` | 0 | ERC-721 token ID of the active v4 position; 0 = no position |
| `assetIsToken0` | false | Set once in `setPoolKey()`; true when `asset() == poolKey.currency0` |
| `assetsDeployed` | 0 | Token-denominated value in the active position (for NAV) |
| `totalLiquidityDeployed` | 0 | Raw Uniswap L units (for display/removal calc) |
| `totalYieldCollected` | 0 | Cumulative net asset-token yield credited to depositors |
| `currency1YieldCollected` | 0 | Cumulative non-asset-token yield; tracked separately, excluded from ERC-4626 NAV, and extractable via `rescueIdle` |

**Rebalance**

```
rebalance(newTickLower, newTickUpper) [onlyOwner, nonReentrant]
  ├── require(_poolKeySet, newTickLower < newTickUpper)
  ├── _collectYield()           // flush fees before closing
  ├── _removeLiquidity(1e18)    // close 100% of current position
  ├── positionTokenId = 0       // reset NFT tracking
  ├── tickLower / tickUpper = new values
  ├── _deployLiquidity(idle)    // reopen at new range (if idle >= MIN_DEPOSIT)
  └── emit Rebalanced
```

**Other owner functions**

- `rescueIdle(token)` — transfers idle tokens to owner; reverts if `token == asset()`. This is how non-asset-token fee balances can be extracted under the current implementation.
- `pause()` / `unpause()` — emergency circuit breaker.
- `setTreasury()`, `setPerformanceFeeBps()`, `setMaxTVL()`.

**View helpers**

- `getVaultStats()` — returns TVL, share price (1e18 = 1:1), depositors, deployed assets, yield collected, fee description.
- `getProjectedAPY(recentYield, windowSeconds)` — returns annualized yield in BPS. Caller supplies the observed window; vault does not store a rolling average.

---

## Data Flow — Full Swap Cycle

```
1. Swapper calls PoolManager.swap() (via unlock callback pattern)
2. PoolManager calls DynamicFeeHook.beforeSwap()
   → fee = amountIn × 25 BPS (×1.5 if volatile), capped at maxFeeBps
   → fee amount + currency stored in transient storage (TSTORE)
   → totalSwaps incremented
3. Swap executes inside PoolManager (modifies pool state)
4. PoolManager calls DynamicFeeHook.afterSwap()
   → fee + currency read from transient storage (TLOAD), slots zeroed
   → poolManager.take(feeCurrency, hook, fee) — pulls fee tokens from pool
   → feeCurrency.transfer(distributor, fee) — sends to distributor
   → feeDistributor.distribute(feeCurrency, fee) called
   → returns afterSwapReturnDelta = fee (tells PM this was consumed)
5. FeeDistributor.distribute() splits fee:
   → treasuryAmount = fee × 20 / 100 → transferred to treasury
   → lpAmount = fee − treasuryAmount
   → poolManager.sync(currency) → transfer to PM → settle() → donate()
  → LP fee growth accrues in pool state for whichever LP positions are in range at the donation tick
6. LiquidityVault._collectYield() (on withdraw, redeem, or explicit call)
   → DECREASE_LIQUIDITY(0) + TAKE_PAIR via PositionManager
  → harvests the vault position's pro-rata share of accumulated LP fees to vault balance
  → only the asset-token portion increases ERC-4626 NAV and share price
  → non-asset-token fees are tracked separately and can be removed via `rescueIdle(otherToken)`
   → performance fee deducted and sent to treasury
   → net yield credited → share price appreciates for all depositors
```

---

## Security Properties

| Property | Mechanism |
|---|---|
| Hook-only fee distribution | `require(msg.sender == hook)` in `FeeDistributor.distribute()` |
| Two-step ownership | `Ownable2Step` on DynamicFeeHook, FeeDistributor, and LiquidityVault |
| Reentrancy | `ReentrancyGuard` on `FeeDistributor.distribute()` and all vault entry points |
| Emergency pause | `Pausable` on LiquidityVault; `pause()`/`unpause()` owner-only; blocks deposit, withdraw, redeem |
| Callback caller verification | `onlyPoolManager` modifier in `BaseHook` (custom `NotPoolManager()` error) |
| Slippage on liquidity removal | 0.5% minimum amount floor via `LiquidityAmounts.getAmountsForLiquidity` |
| Transient fee storage | EIP-1153 `TSTORE/TLOAD` — fee data never persists across transactions |
| Configurable fee cap | `maxFeeBps` (default 50 BPS, hard max 1000 BPS) prevents excessive single-swap fees |
| Minimum deposit | `MIN_DEPOSIT = 1e6` guards against dust-share inflation |
| TVL cap | `maxTVL` (owner-set) — deposits revert with `TVL_CAP` when exceeded |
| Single-sided deployment guard | `_deployLiquidity()` leaves assets idle when the current price would require both tokens, avoiding failed in-range deployments |
| Rescue guard | `rescueIdle(token)` reverts if `token == asset()` — owner cannot drain the vault's own asset |
| Anti-sandwich (volatility) | `lastSwapBlock` — reference price updates only once per block |
| Other-token sentinel guard | `currency1YieldCollected` tracking skips zero-code addresses to prevent precompile calls |
| Permit2 expiry | `_approveForPositionManager` sets 60-second expiry on Permit2 allowances |
| One-shot pool key | `setPoolKey()` can only be called once on both FeeDistributor and LiquidityVault |
| Performance fee cap | `performanceFeeBps` max 2000 (20%), enforced in `setPerformanceFeeBps()` |
| Optional TimelockController | Deploy script supports `OWNER` env var to deploy a timelock with configurable delay |

---

## Dependencies

| Library | Source | Purpose |
|---|---|---|
| `v4-core` | Uniswap | `PoolManager`, `PoolKey`, `PoolId`, `TickMath`, `StateLibrary`, `BalanceDelta`, `BeforeSwapDelta`, `Currency`, `Hooks`, `SwapParams` |
| `v4-periphery` | Uniswap | `IPositionManager`, `Actions` |
| `v4-core/test/utils` | Uniswap (test lib) | `LiquidityAmounts` (includes `getAmountsForLiquidity`) |
| `permit2` | Uniswap (via v4-periphery) | `IAllowanceTransfer` — required for PositionManager token approvals |
| OpenZeppelin v5 | OZ | `ERC4626`, `ERC20`, `Ownable2Step`, `ReentrancyGuard`, `Pausable`, `SafeERC20`, `Math`, `TimelockController` |

---

## Deployment

`script/Deploy.s.sol` is a Foundry broadcast script that:

1. Reads required env vars: `POOL_MANAGER`, `POS_MANAGER`, `TOKEN0`, `TOKEN1`, `TREASURY`.
2. Reads optional env vars: `PERFORMANCE_FEE_BPS` (default 400 = 4%), `MAX_TVL` (default 0), `MAX_FEE_BPS` (default 50), `POOL_FEE` (default 100 = 0.01%), `TICK_SPACING` (default 1), `SQRT_PRICE_X96` (default 1:1), `OWNER` (default none), `TIMELOCK_DELAY` (default 2 days).
3. Pre-computes the `FeeDistributor` address (deployer nonce 0) so the hook constructor arg is known before deployment.
4. Mines a CREATE2 salt for `DynamicFeeHook` via `HookMiner.find()` using the Foundry CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) so the hook address encodes the required permission bits (`BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA`).
5. Deploys `FeeDistributor` → `LiquidityVault` (with canonical Permit2) → `DynamicFeeHook{salt}`.
6. Wires the circular dependency: `distributor.setHook(hook)`.
7. Initialises the pool: `poolManager.initialize(poolKey, sqrtPrice)`.
8. Registers the `PoolKey` on both the distributor and vault.
9. If `OWNER` is set: deploys a `TimelockController` (proposer = OWNER, open executor, admin = OWNER) and initiates `Ownable2Step.transferOwnership()` on all three contracts. The multisig must call `acceptOwnership()` via the timelock after the delay expires.

Run with:
```bash
forge script script/Deploy.s.sol --tc Deploy --rpc-url $RPC_URL --private-key $PK --broadcast
```

---

## Test Architecture

| Suite | File | Coverage |
|---|---|---|
| Unit — Hook | `test/DynamicFeeHook.t.sol` | Fee calc, volatility multiplier, cap, transient storage, routing |
| Unit — Distributor | `test/FeeDistributor.t.sol` | 20/80 split, access control, stats accumulation |
| Unit — Vault | `test/LiquidityVault.t.sol` | ERC-4626 mechanics, share price, yield, rebalance, APY math, Ownable2Step |
| Integration | `test/Integration.t.sol` | Real v4-core `PoolManager`, multi-swap fee accumulation, donate flow |
| Invariants | `test/invariants/VaultInvariant.t.sol` | Vault accounting invariants |

Mocks (in `test/mocks/`):

- `MockPoolManager` — stubs `take`, `donate`, `sync`, `settle`, `initialize`, `extsload` (returns `sqrtPriceX96 = 1`).
- `MockPositionManager` — stubs `nextTokenId` and `modifyLiquidities`; supports `queueYield()` to simulate fee collection without a live pool.
- `MockFeeDistributor` — stub for isolated hook testing.
- `MockERC20` — mintable ERC-20 for test asset.

Test utilities (in `test/utils/`):

- `HookMiner` — brute-force CREATE2 salt search to find hook addresses with required permission bits.
