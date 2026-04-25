# The Pool — Early Depositor Bootstrap Program

One-page spec. Status: implemented at [src/BootstrapRewards.sol](../src/BootstrapRewards.sol). Tests at [test/BootstrapRewards.t.sol](../test/BootstrapRewards.t.sol) (26 unit tests).

---

## 1. Offer (what users see)

> **Early Depositor Bonus — first $100K TVL, 6 months.**
> For the first 6 months after the vault opens, eligible depositors share **50% of treasury swap fees**, proportional to how long and how much they hold.
> Paid monthly in USDC. Capped. Non-transferable. Not a token.

This is a yield kicker on top of the normal LP fee share, not a change to the base economics.

---

## 2. Parameters

| Parameter | Value | Rationale |
|---|---|---|
| Eligible TVL cap | **$100,000** in vault asset (USDC) | Matches the external-audit trigger in [README.md](../README.md#L174). Above this, the program stops adding new eligible shares. |
| Program duration | **180 days** from `programStart` | Short enough to be a bootstrap, long enough to cover a full market cycle. |
| Treasury rebate share | **50% of treasury fees accrued during the program window** | Treasury share is currently `20%` of the 25 bps hook fee → rebate is ~2.5 bps of gross swap volume. The split is owner-tunable but hard-capped at 50% treasury / 50% LPs in [src/FeeDistributor.sol](../src/FeeDistributor.sol#L18-L21). |
| Epoch length | **30 days** (6 epochs total) | Monthly payout; bounds gas and accounting windows. |
| Per-epoch hard cap | **$10,000 USDC** | Protects the treasury if volume spikes. If `rebate > cap`, the excess stays in treasury. |
| Accounting unit | **share-seconds** | Time-weighted; first-block snipers cannot farm a month's payout with a 1-block deposit. |
| Minimum dwell | **7 days continuous position** before a user accrues share-seconds | Anti-flash-deposit. |
| Eligible shares | `min(userShares, shares_equivalent_to_25k_USDC_per_wallet)` | Per-wallet cap prevents one whale from absorbing the bootstrap. |
| Non-transferable | Eligibility tracked per **EOA that called `deposit`**, not per share token | Transferring ERC-4626 shares does **not** transfer bootstrap eligibility. |
| Payout asset | **USDC** (the vault asset) | No new token. No vesting. |
| Claim window | Rolling 90 days per epoch | Unclaimed amounts return to treasury. |

---

## 3. Math (what the contract actually computes)

Per epoch `e`:

$$
\text{bonusPool}_e = \min\!\Big(0.50 \times \text{treasuryFees}_e,\ \text{cap}_e\Big)
$$

Per user `u` in epoch `e`:

$$
\text{userPayout}_{u,e} = \text{bonusPool}_e \times \frac{\text{shareSeconds}_{u,e}^{\text{eligible}}}{\sum_v \text{shareSeconds}_{v,e}^{\text{eligible}}}
$$

Where `shareSeconds_eligible` only accrues when:
- the position has existed ≥ 7 days, **and**
- `userShares ≤ perWalletCap`, **and**
- total vault TVL at each sampled moment ≤ $100k.

Expected magnitude (gross, before IL/gas):

| Daily volume / TVL | Base LP APY (20 bps of 25 bps) | Bonus APY while program active (2.5 bps) | Total while active |
|---|---:|---:|---:|
| 0.10× | 7.30% | 0.91% | 8.21% |
| 0.25× | 18.25% | 2.28% | 20.53% |
| 0.50× | 36.50% | 4.56% | 41.06% |
| 1.00× | 73.00% | 9.13% | 82.13% |

Bonus row is annualized; realized over a 6-month program, roughly halve the bonus column.

Worst-case treasury spend (before per-epoch caps):

| Sustained daily volume | 6-month rebate before cap | With $10k/epoch cap |
|---|---:|---:|
| $100k | $4,550 | $4,550 |
| $300k | $13,650 | $13,650 |
| $1.0M | $45,500 | $60,000 |

---

## 4. Anti-gaming rules

| Vector | Control |
|---|---|
| Flash-deposit / same-block farming | 7-day minimum dwell before share-seconds start accruing. |
| Whale dominating the bonus | Per-wallet eligibility cap of $25k. |
| Sybil splitting | Not fully solvable on-chain; acceptable at this size. At $100k TVL cap, Sybil returns are bounded by the per-epoch cap. |
| Share-token transfer to farm multiple wallets | Eligibility is tracked per original depositor address, not per share balance. Transferring shares forfeits bonus. |
| Sandwich / wash-trading to inflate treasury fees | Already mitigated by the 1.5× volatility multiplier + per-block reference-price update: [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L34-L35), [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L153-L155). Volatile wash trades pay 1.5× to the same treasury pool that funds the rebate. |
| Treasury drain by spike | `cap_e = $10k` per epoch; excess stays in treasury. |

---

## 5. Implementation sketch

Public summary:

- A fixed share of treasury fees is routed to the early-depositor bonus program for 180 days.
- Rewards are time-weighted by deposit size and time in the vault, with clear per-wallet and per-epoch caps.
- Bonus payouts are made in USDC on monthly epochs during a defined claim window.
- Any unclaimed monthly bonus is returned to treasury after the claim window closes.
- This program is additive to normal LP fee earnings and does not change base hook/vault economics.

Technical implementation details are intentionally omitted from this public document.

---

## 6. Honest caveats 

- The bonus is a **temporary promotional rebate**, not protocol yield. It ends at the earlier of 180 days or program cap exhaustion.
- Share-seconds accrual **starts after 7 days of continuous deposit**.
- Transferring your vault shares **forfeits unclaimed bonus**.
- Impermanent loss and smart-contract risk are unchanged by the program. The vault is single-sided OOR; if the price moves into range, part of your USDC converts to the other asset. See [src/LiquidityVault.sol](../src/LiquidityVault.sol#L238-L246).
- External audit (TSI Audit Scanner) was run on 2026-04-25 against commit `22894ce`; **all findings (2 High, 1 Medium, 1 Medium-defense, 3 Low, info) were remediated** before publication. Full report: [audits/the-pool_audit_2026-04-25.md](../audits/the-pool_audit_2026-04-25.md). The internal-audit summary remains in [README.md](../README.md#L142-L172).
- Owner controls (pause, performance fee up to 20%, hook fee cap up to 10%, treasury share up to 50%) exist; see [src/LiquidityVault.sol](../src/LiquidityVault.sol#L458) (`pause`), [src/LiquidityVault.sol](../src/LiquidityVault.sol#L467) (`setPerformanceFeeBps`), [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L204) (`setMaxFeeBps`), [src/FeeDistributor.sol](../src/FeeDistributor.sol#L102) (`setTreasuryShare`).

---


