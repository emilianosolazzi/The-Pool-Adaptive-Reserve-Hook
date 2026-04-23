# The Pool

**A Uniswap v4 hook protocol that turns every swap into yield for liquidity providers.**

The Pool attaches a programmable fee layer to any Uniswap v4 concentrated-liquidity pool. Swap fees are captured on-chain, split between the protocol treasury and LP fee growth, and auto-compounded into an ERC-4626 vault position — so liquidity providers earn more without changing their workflow.

> Fee-only, auto-compounding LP yield on Uniswap v4. No token, no emissions, no lockups. 25 bps dynamic fee on every swap, scaled 1.5× in volatile blocks, 80% donated directly back to the pool on the same transaction. Share price appreciates automatically — no claim flow, no staking. Owner-adjustable range with zero accounting impact on depositors.

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
            ├─ 20% ──► Treasury
            └─ 80% ──► poolManager.donate()   ← accrues to all in-range LPs
                              │  collectYield / withdraw / rebalance
                              ▼
                       LiquidityVault  (ERC-4626)
                              │  modifyLiquidities()
                              ▼
                    v4-periphery PositionManager
```

Each swap triggers a 25 BPS hook fee. During periods of elevated volatility — defined as a ≥ 1% price move since the last block — the fee scales to **1.5×**. The total fee is routed through `FeeDistributor`: 20% goes to the treasury, 80% is donated back to the pool via `poolManager.donate()`, flowing directly into LP fee growth. LPs who deposit into the vault have their position auto-compounded on every withdrawal and rebalance.

---

## Contracts

| Contract | Description |
|---|---|
| `src/BaseHook.sol` | Abstract base — `onlyPoolManager` callback guard, permission-bit validation at deployment |
| `src/DynamicFeeHook.sol` | Fee computation, volatility multiplier, EIP-1153 transient storage, fee routing |
| `src/FeeDistributor.sol` | 20 / 80 treasury-to-LP fee split via `poolManager.donate()` |
| `src/LiquidityVault.sol` | ERC-4626 vault — deposits, withdrawals, rebalances, yield harvesting |

For a full description of state machines, data flows, and invariants, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Features

**For liquidity providers**
- **Auto-compounding yield** — accrued fees are harvested and credited to share price on every withdrawal; no manual claim required
- **Proportional accounting** — share price appreciates uniformly across all depositors; early depositors retain their yield advantage
- **Tick rebalancing** — the owner can shift the concentrated-liquidity range without disrupting depositor balances or share price

**For the protocol**
- **Dynamic fee capture** — 25 BPS base fee, scaling 1.5× in volatile conditions; revenue scales with market activity
- **Performance fee** — owner-configurable treasury cut on harvested yield (0 – 20%, default 0)
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

**76 tests — 0 failures** (unit, integration, fuzz 1 000 runs, stateful invariants 256 × depth 15).

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
TREASURY=            # Address that receives the 20% protocol fee

# Optional — pick the vault's deposit asset (defaults to TOKEN0)
ASSET_TOKEN=         # Must equal TOKEN0 or TOKEN1
```

#### Reference deployment — USDC / WETH on Arbitrum One

The vault is **single-sided out-of-range** by design: it holds one asset and earns fees while waiting to convert into the other across a configured tick band. For a USDC-deposit vault on the Arbitrum USDC / WETH pair, WETH (`0x82aF…`) sorts below USDC (`0xaf88…`), so `TOKEN0=WETH`, `TOKEN1=USDC`, and `ASSET_TOKEN=TOKEN1`. Default ticks in [`LiquidityVault`](src/LiquidityVault.sol) target the ≈ \$700 – \$1,800 WETH/USDC corridor so the vault activates on real drawdowns; the owner can `rebalance()` any time. A ready-to-edit preset lives in [`.env.example`](.env.example).

Optional parameters with their defaults:

```bash
PERFORMANCE_FEE_BPS=0      # Vault yield cut sent to treasury (0–2000 BPS)
MAX_TVL=0                  # Deposit ceiling in asset-token units; 0 = unlimited
MAX_FEE_BPS=50             # Hook fee ceiling in BPS (hard cap, max 1000)
POOL_FEE=100               # Uniswap pool fee tier
TICK_SPACING=1             # Pool tick spacing
SQRT_PRICE_X96=            # Initial pool price; omit to default to 1:1
```

Broadcast the deployment:

```bash
forge script script/Deploy.s.sol --broadcast --rpc-url $ARBITRUM_RPC_URL
```

The deploy script mines a valid hook address (CREATE2 with permission bits), deploys all four contracts in dependency order, wires the circular references, initialises the pool, and registers the pool key on both the hook and the vault.

**Target network: Arbitrum One.**

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
| Unit tests | 61 | — |
| Integration tests | 8 | Real v4 PoolManager |
| Stateful invariants | 4 | 256 runs × depth 15 |
| **Total** | **73** | **0 failures** |

### External Audit

Scheduled at $100K TVL. The system is independently built and self-funded. Security spend is tied to capital at risk — not optics.

### Verification

- All source code is public
- Tests are fully reproducible with a single `forge test` command
- All arithmetic is explicit and auditable in minutes

No trust assumptions beyond what is directly verifiable in the code.

