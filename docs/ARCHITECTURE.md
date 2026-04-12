# Architecture — DeFi Hook Protocol

## Overview

The DeFi Hook Protocol is a Uniswap v4 hook system that attaches a dynamic fee layer to a concentrated-liquidity pool and automatically routes collected fees into an ERC-4626 yield vault. The system is composed of four Solidity contracts that interact in a strict dependency chain.

```
Swapper ──► Uniswap v4 PoolManager
                   │ beforeSwap / afterSwap
                   ▼
           DynamicFeeHook           ← hook registered on PoolKey
                   │ distribute()
                   ▼
           FeeDistributor
            ├─ 20% ──► Treasury address
            └─ 80% ──► poolManager.donate()  (LP fee growth)
                              │ collectYield / withdraw / rebalance
                              ▼
                       LiquidityVault  (ERC-4626)
                              │ modifyLiquidities()
                              ▼
                    v4-periphery PositionManager
```

---

## Contracts

### `BaseHook` (`src/BaseHook.sol`)

Minimal abstract base implementing `IHooks`. Provides:

- `onlyPoolManager` modifier — all hook callbacks revert if not called by the registered `PoolManager`.
- `Hooks.validateHookPermissions` called in the constructor — ensures the hook's deployment address encodes the correct permission bits (Uniswap v4 requirement).
- Default `revert HookNotImplemented()` for every callback; subclasses override only what they need.

### `DynamicFeeHook` (`src/DynamicFeeHook.sol`)

Extends `BaseHook` and `Ownable2Step`. Activates `beforeSwap` and `afterSwap` callbacks.

**Fee computation (beforeSwap)**

1. Base fee: `amountIn × 30 BPS`.
2. Volatility multiplier: if the pool's `sqrtPriceX96` moved ≥ 1 % since the previous swap, the fee is scaled by **1.5×**.
3. Cap: fee is clamped to `maxFeePerSwap` (configurable by the owner, default `0.02 ETH`).
4. The fee amount and currency are written to **EIP-1153 transient storage** (`TSTORE`) so no state change crosses the callback boundary.

**Fee collection (afterSwap)**

1. Reads fee and currency from transient storage (`TLOAD`), then zeroes both slots.
2. Pulls the fee from the pool via `poolManager.take()`.
3. Approves and calls `feeDistributor.distribute()`.
4. Emits `FeeRouted` and accumulates `totalSwaps` / `totalFeesRouted`.

**Key state**

| Variable | Type | Notes |
|---|---|---|
| `maxFeePerSwap` | `uint256` | Owner-adjustable cap |
| `lastSqrtPriceX96` | `uint160` | Inter-swap price tracker for volatility detection |
| `feeDistributor` | `IFeeDistributor` | Replaceable by owner |
| `totalSwaps` | `uint256` | Monotonically increasing counter |
| `totalFeesRouted` | `uint256` | Cumulative fees sent to distributor |

### `FeeDistributor` (`src/FeeDistributor.sol`)

Extends `Ownable2Step` and `ReentrancyGuard`. Single entry point: `distribute(currency, amount)`.

**Split logic**

```
Treasury  =  amount × 20 / 100
LPs       =  amount − Treasury
```

The LP portion is donated back to the pool's fee-growth via:

```
poolManager.sync(currency)
currency.transfer(poolManager, lpAmount)
poolManager.settle()
poolManager.donate(poolKey, amount0, amount1, "")
```

This feeds `feeGrowthGlobal` in the v4 `PoolManager`, which accrues to all in-range LP positions proportionally.

**Access control**

- `distribute()` is gated to `msg.sender == hook` — only the registered hook can trigger fee routing.
- `setHook()` / `setTreasury()` / `setPoolKey()` are owner-only (with `Ownable2Step` two-step transfer).

### `LiquidityVault` (`src/LiquidityVault.sol`)

Extends `ERC4626`, `Ownable2Step`, and `ReentrancyGuard`. Implements the yield-bearing side of the protocol.

**ERC-4626 accounting**

```
totalAssets() = balanceOf(vault) + totalLiquidityDeployed
```

`totalLiquidityDeployed` is the raw `uint128` liquidity units, stored as a `uint256`, representing the vault's active concentrated-liquidity position. When yield is collected, USDC balance of the vault increases → share price rises → existing shares appreciate.

**Deposit flow**

```
deposit(assets, receiver)
  └── super.deposit()          // mint shares at current share price
  └── _deployLiquidity(assets) // open or increase a v4 position
```

**Withdraw flow**

```
withdraw(assets, receiver, owner)
  └── _collectYield()          // harvest any accrued fees from the position
  └── _removeLiquidity(proportion) // remove the pro-rata slice of the position
  └── super.withdraw()         // burn shares, transfer USDC
```

**Yield collection**

`_collectYield()` calls `modifyLiquidities(DECREASE_LIQUIDITY 0)` — a zero-liquidity decrease that triggers the position manager to flush accrued fee tokens to the vault. The vault measures `balanceAfter − balanceBefore` to account for the yield precisely.

**Concentrated liquidity position**

| Parameter | Default | Type |
|---|---|---|
| `tickLower` | −230 270 | `int24 public` (owner-adjustable via `rebalance`) |
| `tickUpper` | −69 082 | `int24 public` (owner-adjustable via `rebalance`) |

Liquidity is computed from `LiquidityAmounts.getLiquidityForAmount0(sqrtPrice, sqrtPriceUpper, amount)`. Slippage on removal is protected via `getAmountsForLiquidity` with a 0.5 % haircut (`× 995 / 1000`).

**Rebalance**

```
rebalance(newTickLower, newTickUpper)
  └── _collectYield()          // flush fees before closing
  └── _removeLiquidity(1e18)   // close 100% of current position
  └── positionTokenId = 0
  └── tickLower / tickUpper = new values
  └── _deployLiquidity(idle)   // reopen at new range
  └── emit Rebalanced
```

**Projected APY helper**

```
getProjectedAPY(recentYield, windowSeconds)
  → aprBPS = recentYield × 365d / windowSeconds × 10_000 / totalAssets()
```

Returns basis points. The caller supplies an externally observed `recentYield` window; the vault does not store a rolling average.

---

## Data Flow — Full Swap Cycle

```
1. Swapper calls PoolManager.swap()
2. PoolManager calls DynamicFeeHook.beforeSwap()
   → fee computed, stored in transient storage
3. Swap executes inside PoolManager
4. PoolManager calls DynamicFeeHook.afterSwap()
   → fee pulled from pool via poolManager.take()
   → feeDistributor.distribute(currency, fee) called
5. FeeDistributor splits fee:
   → 20% transferred to treasury
   → 80% donated back to pool (LP fee growth)
6. LP fee growth accumulates in pool state
7. LiquidityVault._collectYield() (on withdraw or explicit call)
   → harvests accumulated LP fees via PositionManager
   → totalYieldCollected incremented
   → share price appreciates for all depositors
```

---

## Security Properties

| Property | Mechanism |
|---|---|
| Hook-only fee distribution | `require(msg.sender == hook)` in `FeeDistributor.distribute()` |
| Two-step ownership | `Ownable2Step` on all three non-base contracts |
| Reentrancy | `ReentrancyGuard` on `FeeDistributor` and `LiquidityVault` |
| Callback caller verification | `onlyPoolManager` modifier in `BaseHook` |
| Slippage on liquidity removal | 0.5 % minimum amount floor via `LiquidityAmounts.getAmountsForLiquidity` |
| Transient fee storage | EIP-1153 `TSTORE/TLOAD` — fee data never persists across transactions |
| Configurable fee cap | `maxFeePerSwap` prevents single-swap fee griefing |
| Minimum deposit | `MIN_DEPOSIT = 1e6` (1 USDC) guards against dust-share inflation |

---

## Dependencies

| Library | Source | Purpose |
|---|---|---|
| `v4-core` | Uniswap | `PoolManager`, `PoolKey`, `TickMath`, `StateLibrary`, `BalanceDelta` |
| `v4-periphery` | Uniswap | `IPositionManager`, `Actions` |
| `v4-core/test/utils` | Uniswap (test lib) | `LiquidityAmounts` (superset — includes `getAmountsForLiquidity`) |
| OpenZeppelin v5.6.1 | OZ | `ERC4626`, `Ownable2Step`, `ReentrancyGuard`, `Math` |

---

## Test Architecture

| Suite | File | Coverage |
|---|---|---|
| Unit — Hook | `test/DynamicFeeHook.t.sol` | Fee calc, volatility multiplier, cap, transient storage, routing |
| Unit — Distributor | `test/FeeDistributor.t.sol` | 20/80 split, access control, stats accumulation |
| Unit — Vault | `test/LiquidityVault.t.sol` | ERC-4626 mechanics, share price, yield, rebalance, APY math, Ownable2Step |
| Integration | `test/integration/` | Real v4-core `PoolManager`, multi-swap fee accumulation, donate flow |

Mocks:

- `MockPoolManager` — stubs `take`, `donate`, `sync`, `settle`, `initialize`, `extsload` (returns `sqrtPriceX96 = 1`).
- `MockPositionManager` — stubs `nextTokenId` and `modifyLiquidities`; supports `queueYield()` to simulate fee collection without a live pool.
- `MockERC20` — mintable ERC-20 for test asset.
