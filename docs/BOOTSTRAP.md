# The Pool — Early Depositor Bootstrap Program

One-page spec. Status: implemented at [src/BootstrapRewards.sol](../src/BootstrapRewards.sol). Tests at [test/BootstrapRewards.t.sol](../test/BootstrapRewards.t.sol) (26 unit tests).

---

## 1. Offer (what users see)

> **Early Depositor Bonus — first $100K TVL, 180 days (six 30-day epochs).**
> For the first 180 days after the vault opens, eligible depositors share **50% of treasury swap fees**, proportional to how long and how much they hold.
> Paid monthly in USDC. Capped. Non-transferable. Not a token.

This is a yield kicker on top of the normal LP fee share, not a change to the base economics.

---

## 2. Parameters

| Parameter | Value | Rationale |
|---|---|---|
| Eligible TVL cap | **$100,000** in vault asset (USDC) | Matches the external-audit trigger in [README.md](../README.md). Above this, the program stops adding new eligible shares. |
| Program duration | **180 days** from `programStart` | Short enough to be a bootstrap, long enough to cover a full market cycle. |
| Treasury rebate share | **50% of treasury fees accrued during the program window** | Treasury share is currently `20%` of the 25 bps hook fee → rebate is ~2.5 bps of gross swap volume. The split is owner-tunable but hard-capped at 50% treasury / 50% LPs in [src/FeeDistributor.sol](../src/FeeDistributor.sol#L24) and [src/FeeDistributor.sol](../src/FeeDistributor.sol#L156-L157). |
| Epoch length | **30 days** (6 epochs total) | Monthly payout; bounds gas and accounting windows. |
| Per-epoch hard cap | **$10,000 USDC** | Protects the treasury if volume spikes. If `rebate > cap`, the excess stays in treasury. |
| Accounting unit | **share-seconds** | Time-weighted; first-block snipers cannot farm a month's payout with a 1-block deposit. |
| Minimum dwell | **7 days continuous position** before a user accrues share-seconds | Anti-flash-deposit. |
| Eligible shares | `min(userShares, shares_equivalent_to_25k_USDC_per_wallet)` | Per-wallet cap prevents one whale from absorbing the bootstrap. |
| Transfer behavior | Eligibility is address-based and depends on vault-share balance plus dwell state | Transferring shares can reset/disrupt accrual and may forfeit bonus; rewards are not tokenized or portable. |
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
- global eligible share accrual has not exceeded the configured cap.

Expected magnitude (gross, before IL/gas):

| Daily volume / TVL | Hook LP rebate APY (20 bps of volume) | Bootstrap bonus APY while active (2.5 bps of volume) | Combined hook-funded APY while active |
|---|---:|---:|---:|
| 0.10× | 7.30% | 0.91% | 8.21% |
| 0.25× | 18.25% | 2.28% | 20.53% |
| 0.50× | 36.50% | 4.56% | 41.06% |
| 1.00× | 73.00% | 9.13% | 82.13% |

Bonus rows are annualized; realized over a 180-day program, roughly halve the bonus column.

Worst-case treasury spend (before per-epoch caps):

| Sustained daily volume | 6-month rebate before cap | With $10k/epoch cap |
|---|---:|---:|
| $100k | $4,550 | $4,550 |
| $300k | $13,650 | $13,650 |
| $1.0M | $45,500 | $45,500 |
| $1.32M+ | $60,000+ | $60,000 |

---

## 4. Anti-gaming rules

| Vector | Control |
|---|---|
| Flash-deposit / same-block farming | 7-day minimum dwell before share-seconds start accruing. |
| Whale dominating the bonus | Per-wallet eligibility cap of $25k. |
| Sybil splitting | Not fully solvable on-chain; acceptable at this size. At $100k TVL cap, Sybil returns are bounded by the per-epoch cap. |
| Share-token transfer to farm multiple wallets | Eligibility is address-based and tied to balance+dwell accrual. Transfers can reset/disrupt accrual windows and are not a reliable way to transfer bonus eligibility. |
| Sandwich / wash-trading to inflate treasury fees | Already mitigated by the 1.5× volatility multiplier + per-block reference-price update: [src/DynamicFeeHookV2.sol](../src/DynamicFeeHookV2.sol#L61-L62), [src/DynamicFeeHookV2.sol](../src/DynamicFeeHookV2.sol#L543-L548). Volatile wash trades pay 1.5× to the same treasury pool that funds the rebate. |
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

- The bonus is a **temporary promotional rebate**, not protocol yield. It ends at the earlier of 180 days (six 30-day epochs) or program cap exhaustion.
- Share-seconds accrual **starts after 7 days of continuous deposit**.
- Transferring vault shares can reset/disrupt dwell and accrual state, and may forfeit pending bonus.
- Impermanent loss and smart-contract risk are unchanged by the program. The vault is single-sided OOR; if the price moves into range, part of your USDC converts to the other asset. See [src/LiquidityVaultV2.sol](../src/LiquidityVaultV2.sol).
- Internal automated audit (TSI Audit Scanner) includes a V2.2 hardening re-test on 2026-04-27; findings were remediated and re-tested. Full report: [audits/TSI-Audit-Scanner_2026-04-25.md](../audits/TSI-Audit-Scanner_2026-04-25.md). Operational companion: [docs/HOOK-RISK-RUNBOOK.md](HOOK-RISK-RUNBOOK.md). Internal-audit summary: [README.md](../README.md).
- Owner controls (pause, performance fee up to 20%, hook fee cap up to 10%, treasury share up to 50%) exist; see [src/LiquidityVaultV2.sol](../src/LiquidityVaultV2.sol#L953-L954) (`pause`/`unpause`), [src/LiquidityVaultV2.sol](../src/LiquidityVaultV2.sol#L928) (`setPerformanceFeeBps`), [src/DynamicFeeHookV2.sol](../src/DynamicFeeHookV2.sol#L623) (`setMaxFeeBps`), [src/FeeDistributor.sol](../src/FeeDistributor.sol#L156-L157) (`setTreasuryShare`).

---


