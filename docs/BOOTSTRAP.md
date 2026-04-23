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
| Treasury rebate share | **50% of treasury fees accrued during the program window** | Treasury is `20%` of the 25 bps hook fee → rebate is ~2.5 bps of gross swap volume. See [src/FeeDistributor.sol](../src/FeeDistributor.sol#L16). |
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
| Sandwich / wash-trading to inflate treasury fees | Already mitigated by the 1.5× volatility multiplier + per-block reference-price update: [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L34), [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L35), [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L140). Volatile wash trades pay 1.5× to the same treasury pool that funds the rebate. |
| Treasury drain by spike | `cap_e = $10k` per epoch; excess stays in treasury. |

---

## 5. Implementation sketch

Standalone contract [src/BootstrapRewards.sol](../src/BootstrapRewards.sol):

- Becomes the FeeDistributor's treasury for the program window via `setTreasury(bootstrapRewards)` ([src/FeeDistributor.sol](../src/FeeDistributor.sol#L84)). After the program: `setTreasury(realTreasury)`.
- `pullInflow()` (permissionless, idempotent) splits any new payout-asset balance: `bonusShareBps` (5000 = 50%) into the active epoch's `bonusPool` (capped by `perEpochCap`), the rest forwarded to `realTreasury`. Overflow above the cap also forwards to `realTreasury`.
- `poke(user)` (permissionless) accrues share-seconds for `user` over `[lastPoke, min(now, programEnd)]` using the user's balance at lastPoke, clipped to `perWalletShareCap`, with a `dwellPeriod` (7-day) gate.
- **Finalization window**: after epochEnd, claims are locked for `finalizationDelay` (7 days). During this window, anyone can `poke` any depositor so totalShareSeconds converges to its true value. This eliminates the order-dependent claim race that would otherwise let the first claimer drain the pool.
- `claim(epoch)` (pull-style) opens at `epochEnd + finalizationDelay`, valid for `claimWindow` (90 days). Auto-pokes the caller before computing payout = `bonusPool * userSS / totalSS`.
- `sweepEpoch(epoch)` (permissionless, after claim window) returns unclaimed dust to `realTreasury`.
- `sweepToken(token)` (owner) forwards any non-payout token (e.g. WETH inflows when the swap currency was currency0) to `realTreasury`. Cannot sweep the payout asset.

No changes required to `DynamicFeeHook`, `FeeDistributor`, or `LiquidityVault` — the whole program is implemented in one external contract plus a treasury-address swap.

---

## 6. Honest caveats to put on the UI

- The bonus is a **temporary promotional rebate**, not protocol yield. It ends at the earlier of 180 days or program cap exhaustion.
- Share-seconds accrual **starts after 7 days of continuous deposit**.
- Transferring your vault shares **forfeits unclaimed bonus**.
- Impermanent loss and smart-contract risk are unchanged by the program. The vault is single-sided OOR; if the price moves into range, part of your USDC converts to the other asset. See [src/LiquidityVault.sol](../src/LiquidityVault.sol#L206), [src/LiquidityVault.sol](../src/LiquidityVault.sol#L208).
- External audit is **scheduled at $100K TVL**, not yet completed. See [README.md](../README.md#L174).
- Owner controls (pause, performance fee up to 20%, hook fee cap up to 10%) exist; see [src/LiquidityVault.sol](../src/LiquidityVault.sol#L411), [src/DynamicFeeHook.sol](../src/DynamicFeeHook.sol#L191).

---

## 7. UI copy (drop-in)

**Headline:** “Earn LP fees + a 6-month early-depositor bonus.”
**Subhead:** “First $100K TVL shares 50% of treasury swap fees for 6 months. Time-weighted, capped, paid in USDC.”
**CTA:** “Deposit USDC — eligibility starts after 7 days.”
**Fine print:** “Bonus is share-seconds-weighted, capped at $25K per wallet and $10K per monthly epoch. Transfers of vault shares forfeit unclaimed bonus. Program ends after 180 days or when the $100K TVL window closes. Not investment advice.”
