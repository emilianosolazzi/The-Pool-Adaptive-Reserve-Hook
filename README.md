# The Pool

A Uniswap v4 hook protocol that captures dynamic swap fees and routes them into an ERC-4626 yield vault for concentrated-liquidity LPs.

---

## How It Works

```
Swapper ──► Uniswap v4 PoolManager
                   │ beforeSwap / afterSwap
                   ▼
           DynamicFeeHook
                   │ distribute()
                   ▼
           FeeDistributor
            ├─ 20% ──► Treasury
            └─ 80% ──► poolManager.donate()  (LP fee growth)
                              │ collectYield / withdraw / rebalance
                              ▼
                       LiquidityVault  (ERC-4626)
                              │ modifyLiquidities()
                              ▼
                    v4-periphery PositionManager
```

Every swap triggers a dynamic fee (base 30 BPS, up to 1.5× during high volatility). The fee is split: 20% to the protocol treasury, 80% donated back to the pool as LP fee growth. LPs deposit into the ERC-4626 vault which manages the concentrated-liquidity position and auto-compounds accrued fees.

---

## Contracts

| Contract | Description |
|---|---|
| `src/BaseHook.sol` | Abstract base — `onlyPoolManager` guard, hook permission validation |
| `src/DynamicFeeHook.sol` | Fee computation + volatility multiplier + EIP-1153 transient storage |
| `src/FeeDistributor.sol` | 20/80 treasury/LP fee split via `poolManager.donate()` |
| `src/LiquidityVault.sol` | ERC-4626 vault — deposits, withdrawals, rebalances, yield collection |

Full design details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

---

## Features

- **Dynamic fees** — 30 BPS base, 1.5× volatility multiplier when price moves ≥ 1% between blocks
- **Anti-sandwich protection** — reference price updates only once per block; same-block multiplier suppression is blocked
- **Auto-compounding yield** — LP fees harvested on every withdraw/redeem and credited to share price
- **Performance fee** — configurable treasury cut (0–20%) on collected yield; default 0
- **TVL cap** — optional deposit ceiling; set to 0 for unlimited
- **Emergency pause** — owner can halt deposits, withdrawals, and redeems
- **Non-asset yield tracking** — other-token fees (e.g. WETH in a USDC/WETH pool) are tracked separately in `currency1YieldCollected`
- **Rebalance** — owner can shift the concentrated-liquidity tick range without disrupting depositor accounting

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
# Unit + integration tests (fast)
forge test --no-match-contract "Invariant"

# Full suite including invariant fuzzing
forge test
```

Current coverage: **68 tests — 0 failures**.

### Deploy

Copy `.env.example` to `.env` and fill in the required variables:

```
ARBITRUM_RPC_URL=
PRIVATE_KEY=
POOL_MANAGER=        # v4 PoolManager address
POS_MANAGER=         # v4 PositionManager address
TOKEN0=              # lower-address token
TOKEN1=              # higher-address token
TREASURY=            # address that receives the 20% protocol fee
```

Optional overrides (with defaults):

```
PERFORMANCE_FEE_BPS=500   # 5% of vault yield; 0–2000
MAX_TVL=0                 # deposit ceiling in asset units; 0 = unlimited
MAX_FEE_BPS=50            # hook fee cap in BPS
POOL_FEE=100              # Uniswap pool fee tier
TICK_SPACING=1
SQRT_PRICE_X96=           # initial price; defaults to 1:1
```

Then broadcast:

```bash
forge script script/Deploy.s.sol --broadcast --rpc-url $ARBITRUM_RPC_URL
```

Target network: **Arbitrum One**.

---

## Security

### Internal Audit Status: Complete

All critical paths have undergone full internal review with emphasis on deterministic correctness, precision, and invariant preservation.

**Scope:**

- Fee calculation across boundary conditions (min / median / max swap sizes)
- FeeDistributor split (20/80) with exact rounding behavior validation
- `donate()` accounting integrity via poolManager
- ERC-4626 share price invariance across deposit / withdraw / redeem / yield cycles
- Reentrancy analysis on all state-mutating entry points
- Transient storage slot collision analysis (EVM-level safety)
- Hook flag validation at deployment (static + runtime assumptions)
- `rescueIdle` cannot drain vault asset (`require(token != asset())`)
- Same-block sandwich attack on volatility multiplier (`lastSwapBlock` guard)
- Emergency pause coverage across all user-facing entry points

**Testing:**

- 68 passing tests — unit, integration, fuzz (1 000 runs), and stateful invariants
- Full integration path validated: `deposit → swap → fee → distribute → donate → yield → withdraw`
- All invariants hold under simulation

### External Audit

Scheduled at $100K TVL.

The system is independently built and self-funded. Capital is allocated to security when it becomes economically rational — not performative.

### Verification Model

- Code is public
- Tests are reproducible
- Math is inspectable in minutes

No trust assumptions are required beyond what can be verified directly.
