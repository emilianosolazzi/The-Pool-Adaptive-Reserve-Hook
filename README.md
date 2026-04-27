# The Pool

**A Uniswap v4 hook protocol that turns every swap into yield for liquidity providers.**

The Pool attaches a programmable fee layer to any Uniswap v4 concentrated-liquidity pool. Swap fees are captured on-chain, split between the protocol treasury and LP fee growth, and credited to share price in an ERC-4626 vault — so liquidity providers earn more without changing their workflow.

> Fee-only LP yield on Uniswap v4. No token, no emissions, no lockups. 25 bps dynamic hook fee on every swap, scaled 1.5× in volatile blocks; by default 80% is donated directly back to the pool on the same transaction (treasury share is owner-adjustable, hard-capped at 50%). Share price appreciates as fees accrue — no claim flow, no staking. Anyone can call `compound()` to harvest fees and redeploy idle balance into the active range. Owner-adjustable tick range with zero accounting impact on depositors.

During the bootstrap program, `FeeDistributor.treasury` is set to the `BootstrapRewards` contract, which routes a portion of the treasury share back to early LPs as epoch bonuses — so effective LP share during the program window is higher than the steady-state 80%.

---

## Architecture

```
Swapper ──► Uniswap v4 PoolManager
                   │  beforeSwap / afterSwap
                   ▼
           DynamicFeeHook
                   │  distribute()
                   ▼
           FeeDistributor
            ├─ treasuryShare ──► Treasury        (default 20%, owner-adjustable, capped at 50%)
            └─ remainder ──► poolManager.donate()  (default 80%; accrues to all in-range LPs)
                              │  collectYield / withdraw / rebalance
                              ▼
                       LiquidityVault  (ERC-4626)
                              │  modifyLiquidities()
                              ▼
                    v4-periphery PositionManager
```

Each swap triggers a 25 BPS hook fee. During periods of elevated volatility — defined as a ≥ 1% price move since the last block — the fee scales to **1.5×**. The total fee is routed through `FeeDistributor`: by default 20% goes to the treasury and 80% is donated back to the pool via `poolManager.donate()`, flowing directly into LP fee growth. The treasury share is owner-adjustable via `setTreasuryShare`, hard-capped at 50% (LP share floor 50%). Fee yield collected by the vault accrues to share price; redeployment of the harvested asset back into the active tick range happens on `deposit`, `rebalance`, or any caller invoking the permissionless `compound()`.

---

## Contracts

| Contract | Description |
|---|---|
| `src/BaseHook.sol` | Abstract base — `onlyPoolManager` callback guard, permission-bit validation at deployment |
| `src/DynamicFeeHook.sol` | Fee computation, volatility multiplier, EIP-1153 transient storage, fee routing |
| `src/FeeDistributor.sol` | Default 20 / 80 treasury-to-LP fee split via `poolManager.donate()`; treasury share owner-adjustable, hard-capped at 50% |
| `src/LiquidityVault.sol` | ERC-4626 vault — deposits, withdrawals, rebalances, yield harvesting |

For a full description of state machines, data flows, and invariants, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

For detailed mathematical examples of yield generation and APY calculations, see [`docs/VALUE-EXAMPLES.md`](docs/VALUE-EXAMPLES.md).

For code examples and integration snippets, see [`docs/CODE-EXAMPLES.md`](docs/CODE-EXAMPLES.md).

---

## Features

**For liquidity providers**
- **Fee yield credited to share price** — swap fees accrue to `totalAssets()` on every `_collectYield()`; no manual claim required
- **Permissionless `compound()`** — any caller (keeper, depositor, frontend) can harvest fees and redeploy idle balance into the active range; out-of-range conditions early-return silently
- **Proportional accounting** — share price appreciates uniformly across all depositors; early depositors retain their yield advantage
- **Tick rebalancing** — the owner can shift the concentrated-liquidity range without disrupting depositor balances or share price

**For the protocol**
- **Dynamic fee capture** — 25 BPS base fee, scaling 1.5× in volatile conditions; revenue scales with market activity
- **Performance fee** — owner-configurable treasury cut on harvested yield (0 – 20%, deploy default 4%)
- **TVL cap** — optional ceiling on total deposits to manage controlled rollout

**Security**
- **Anti-sandwich protection** — the volatility reference price updates at most once per block, blocking same-block multiplier suppression attacks
- **Emergency pause** — owner can halt all deposits, withdrawals, and redeems instantly
- **Non-rug guarantee** — `rescueIdle` cannot be used to drain the vault's own asset token
- **Zero-address guards** — treasury, hook, and distributor setters all reject `address(0)`
- **`SafeERC20`** — all token transfers use OpenZeppelin `safeTransfer`, handling non-standard ERC20s

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`)
- Solidity `>=0.8.24 <0.9.0`

### Install

```bash
git clone https://github.com/emilianosolazzi/The-Pool
cd The-Pool
forge install
```

### Test

```bash
# Unit and integration tests
forge test --no-match-contract "Invariant"

# Full suite including stateful invariant fuzzing
forge test
```

**137 tests — 0 failures** (unit, integration, fork, fuzz 1 000 runs, stateful invariants 256 × depth 15).

### Deploy

Copy `.env.example` to `.env` and populate the required variables:

```bash
ARBITRUM_RPC_URL=
PRIVATE_KEY=

# Required
POOL_MANAGER=        # Uniswap v4 PoolManager address on target network
POS_MANAGER=         # Uniswap v4 PositionManager address
TOKEN0=              # Lower-address token of the pair
TOKEN1=              # Higher-address token of the pair
TREASURY=            # Address that receives the treasury share (default 20% of hook fees)

# Optional — pick the vault's deposit asset (defaults to TOKEN0)
ASSET_TOKEN=         # Must equal TOKEN0 or TOKEN1
```

#### Reference deployment — USDC / WETH on Arbitrum One

The vault is **single-sided out-of-range** by design: it holds one asset and earns fees while waiting to convert into the other across a configured tick band. For a USDC-deposit vault on the Arbitrum USDC / WETH pair, WETH (`0x82aF…`) sorts below USDC (`0xaf88…`), so `TOKEN0=WETH`, `TOKEN1=USDC`, and `ASSET_TOKEN=TOKEN1`. **Pool: 0.05% fee tier (`POOL_FEE=500`), `TICK_SPACING=10`.** Default ticks in [`LiquidityVault`](src/LiquidityVault.sol) (`tickLower = -201360`, `tickUpper = -193200`, both multiples of 10) target the ≈ \$1,800 – \$4,065 WETH/USDC corridor: the vault deploys 100% USDC while ETH is above the band and steadily converts to WETH as price falls into range. The owner can `rebalance(newTickLower, newTickUpper)` any time to a new pair of tick-spacing-aligned ticks. A ready-to-edit preset lives in [`.env.example`](.env.example).

Optional parameters with their script defaults (the live Arbitrum One deployment overrides `POOL_FEE` / `TICK_SPACING` via `.env.example` to match the 0.05% USDC/WETH pool):

```bash
PERFORMANCE_FEE_BPS=400    # Vault yield cut sent to treasury (0–2000 BPS)
MAX_TVL=0                  # Deposit ceiling in asset-token units; 0 = unlimited
MAX_FEE_BPS=50             # Hook fee ceiling in BPS (hard cap, max 1000)
POOL_FEE=500               # Uniswap v4 pool fee tier (0.05%; reference deployment)
TICK_SPACING=10            # Pool tick spacing (matches POOL_FEE=500)
SQRT_PRICE_X96=            # Initial pool price; omit to default to 1:1
```

Broadcast the deployment:

```bash
forge script script/Deploy.s.sol --broadcast --rpc-url $ARBITRUM_RPC_URL
```

The deploy script mines a valid hook address (CREATE2 with permission bits), deploys all four contracts in dependency order, wires the circular references, initialises the pool, and registers the pool key on both the hook and the vault.

**Target network: Arbitrum One.**

### Live Arbitrum One deployment

| Component | Address |
|---|---|
| FeeDistributor | `0x474F59AE4699743AcC8563e7833e2bE90e7426C3` |
| LiquidityVault | `0x87F2db1A41A9227CBfBBC00A5AdE5770C85b3d71` |
| DynamicFeeHook | `0x62076C1Cb0Ea57Acd2353fF45226a1FB1e6100c4` |
| BootstrapRewards | `0x2f9Ba00A0AA3533874294c55144a30Bf6a7b7a63` |

Bootstrap activation txs:
- Deploy BootstrapRewards: `0xc2eaece0e89b2489b6ca4836935be14efc6d40d3e44ec72fe23363ed24a7b2e3`
- Wire `FeeDistributor.treasury` to BootstrapRewards: `0xbcf1c27ecc1c63bef350e2d3eef98b0540d4495ea33254c6fd61eb07a2644722`

---

## Security

### Internal Audit: Complete

All critical paths have been reviewed with emphasis on correctness, arithmetic precision, and invariant preservation. Remediation is complete.

**Audit scope included:**

- Fee calculation correctness across swap size boundary conditions
- `FeeDistributor` 20 / 80 split with exact rounding validation
- `poolManager.donate()` accounting integrity end-to-end
- ERC-4626 share price invariance across deposit, withdraw, redeem, and yield cycles
- Reentrancy analysis on all state-mutating entry points
- EIP-1153 transient storage slot isolation
- Hook permission-flag validation at deployment
- `setPoolKey` pool membership enforcement (`ASSET_NOT_IN_POOL` guard)
- `rescueIdle` non-drainability of vault asset
- Same-block sandwich vector on the volatility multiplier (`lastSwapBlock`)
- Emergency pause coverage across all user-facing entry points
- Zero-address rejection on all privileged setters

**Test suite:**

| Category | Count | Configuration |
|---|---|---|
| Unit tests | 122 | — |
| Integration tests | 8 | Real v4 PoolManager |
| Fork tests | 3 | Arbitrum One pinned block |
| Stateful invariants | 4 | 256 runs × depth 15 |
| **Total** | **137** | **0 failures** |

### External Audit: Complete

Independent third-party audit by **TSI Audit Scanner** completed **2026-04-25** against commit `22894ce`. All findings (2 High, 1 Medium, 1 Medium defense-in-depth, 3 Low, plus informational items) were remediated before the report was finalized — the published verdict is **PASSED**.

Full report: [audits/the-pool_audit_2026-04-25.md](audits/the-pool_audit_2026-04-25.md).

A second external audit is scheduled at $100K TVL. The system is independently built and self-funded. Security spend is tied to capital at risk — not optics.

### Verification

- All source code is public
- Tests are fully reproducible with a single `forge test` command
- All arithmetic is explicit and auditable in minutes

No trust assumptions beyond what is directly verifiable in the code.

