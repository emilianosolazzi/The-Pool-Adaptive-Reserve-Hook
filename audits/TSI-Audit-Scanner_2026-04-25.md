# The-Pool Audit Report

![PASSED — TSI Audit Scanner](assets/badge-passed.svg)

**Repo:** https://github.com/emilianosolazzi/The-Pool
**Date:** 2026-04-25 (initial) · **Re-test:** 2026-04-25 @ `22894ce` · **V2.1 re-test:** 2026-04-27 @ `44fc5fe` · **V2.2 hardening re-test:** 2026-04-27 @ `8c962fa`
**Scope (V1):** `src/BaseHook.sol`, `src/DynamicFeeHook.sol`, `src/FeeDistributor.sol`, `src/LiquidityVault.sol`, `src/BootstrapRewards.sol` (~1280 LoC)
**Scope (V2.1):** `src/DynamicFeeHookV2.sol`, `src/LiquidityVaultV2.sol`, `script/DeployHookV2AndVault.s.sol`
**Scope (V2.2, this re-test):** same V2 surface + `src/FeeDistributor.sol` recovery path + reserve-fill fuzz invariant suite + CI.
**Stack:** Uniswap v4 hook + ERC-4626 USDC-entry zap vault + reserve-sale (limit-order) hook fills, Solidity ^0.8.24

---

## V2.2 Hardening Re-test — 2026-04-27 @ `8c962fa`

**Status: V2.2 SHIPPED — 221/221 tests pass (216 deterministic + 5 handler-driven fuzz invariants × 256 runs × 15 depth, 0 reverts across ~19 200 random action sequences).**

This re-test layers seven hardening commits on top of the V2.1 audit-ready
baseline. No new audit findings were introduced; three V2.1 residual items
are now closed, and additional defense-in-depth was added against
operational failure modes (failed distributions, native-ETH dust,
off-anchor NAV pricing).

### Commits in this hardening pass

| Commit | Subject |
|--------|---------|
| `14756c4` | feat(hardening): P0 + reserve-fill invariants + distributor recovery |
| `331f67d` | feat(vault): bootstrap-rewards auto-poke on share transfers |
| `0075701` | feat(vault): deviation-guarded NAV pricing rule + OOR-clamp |
| `2f43c02` | fix(vault): tighten NAV deviation cap to 5%, harden math, document anchor flow |
| `152f371` | harden(vault): explicitly reject native ETH + owner-only `rescueNative` |
| `02acc7b` | harden(hook): track failed-distribution tally + owner acknowledge primitive |
| `41b8913` | test(hook): handler-driven fuzz invariants for `_tryFillReserve` |
| `8c962fa` | ci: add minimal GitHub Actions workflow (build + test, no-fork) |

### Findings closed (V2.1 → V2.2)

| Finding | Class | Status | Fix location |
|---------|-------|--------|--------------|
| V2.1-R1 Volatility-oracle freeze on 100%-reserve-absorbed swaps | Oracle / accounting | ✅ MITIGATED | `DynamicFeeHookV2` afterSwap path: `_lastSqrtPriceX96` refresh keyed off block boundary irrespective of reserve-fill share; falls back to `100` (no boost) on stale read — benign under-charge, never over-charge. |
| V2.1-R2 No fuzz/invariant test on `_tryFillReserve` math | Coverage | ✅ FIXED | `test/ReserveFillFuzzInvariants.t.sol` — handler-driven stateful fuzz over the post / cancel / swap / claim state machine; 5 invariants asserting per-currency escrow + proceeds conservation, hook-balance dominance, `totalReserveSold` ↔ ghost-sum equality, and offer-active ⇒ on-chain-escrowed. |
| V2.2-N1 NAV pricing drift between owner-set anchor and live AMM | Accounting | ✅ FIXED | `LiquidityVaultV2` — deviation-guarded NAV: `MAX_NAV_DEVIATION_CAP` lowered from 2000 bps → 500 bps; `_priceWithinTolerance` rewritten as two-step `FullMath.mulDiv` in 1e18 fixed-point so no intermediate exceeds 256 bits even at `MAX_SQRT_PRICE`; OOR clamp + bootstrap NatSpec requiring owner-init before unpause. |
| V2.2-N2 Native ETH silently accepted with no withdrawal path | Asset hygiene | ✅ FIXED | `LiquidityVaultV2` — `error NativeNotSupported`; `receive()` and `fallback()` revert; `rescueNative(to, amount) onlyOwner nonReentrant` for SELFDESTRUCT-forced dust; emits `NativeRescued`. |
| V2.2-N3 Fee-distribution failure left no on-chain unresolved tally | Operational | ✅ FIXED | `DynamicFeeHookV2` — soft-fail try/catch around `distribute()` now increments `mapping(address => uint256) failedDistribution` per currency; owner-only `acknowledgeFailedDistribution(currency, amount)` decrements with under-flow guard and emits `FailedDistributionAcknowledged`. Pairs with `FeeDistributor.retryDistribute` / `sweepUndistributed` from V1 closeout. |
| V2.2-N4 BootstrapRewards lazy-poke could underweight active LPs on fast share churn | Accounting | ✅ FIXED | `LiquidityVaultV2._update` overrides ERC20 transfer hook to auto-poke both endpoints, eliminating the "forgot to poke" footgun called out in V1 H-3. |

The pre-existing V2.1 Tier-1 findings (V2-T1.1 … V2-T1.6, plus the
first-deposit inflation/donation mitigation) remain ✅ FIXED.

### Test inventory — 221/221 pass

```
forge test --no-match-contract Fork
Ran 15 test suites: 221 tests passed, 0 failed, 0 skipped
```

Coverage delta vs. V2.1 (154 → 221, +67):

- `test/LiquidityVaultV2.t.sol` — +14 (8 NAV-deviation + 6 native-ETH).
- `test/RealityCheck.t.sol` — +7 distributor recovery (failed-distribution
  tally, acknowledge under-flow, sweep round-trip with reverting receiver).
- `test/DynamicFeeHookV2.t.sol` — +6 (failed-distribution tally regression).
- `test/ReserveFillInvariants.t.sol` — 8 deterministic conservation
  scenarios (post / cancel / partial fill / drain / claim / re-post).
- `test/ReserveFillFuzzInvariants.t.sol` — **5 handler-driven fuzz
  invariants**, default profile (256 runs × 15 depth), 0 reverts:
  1. `invariant_hookBalanceDominates` — hook ERC20 ≥ escrow + proceeds per
     currency.
  2. `invariant_escrowConservation` —
     `ghostEscrowedIn[c] = ghostReturned[c] + ghostSold[c] + escrow[c]`.
  3. `invariant_proceedsConservation` —
     `ghostProceedsAccrued[c] = ghostClaimed[c] + proceeds[c]`.
  4. `invariant_totalReserveSoldMatchesGhost` —
     `hook.totalReserveSold == Σ ghostSold[c]`.
  5. `invariant_offerActiveImpliesEscrowed` — handler/on-chain agreement +
     `sellRemaining > 0`.

### CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs `forge
build --sizes` then `forge test --no-match-contract Fork -vvv` on push and
PR to `main`. The exclude pattern matches `ForkTest` (archived) and
`LiquidityVaultV2ForkTest` — both require `ARBITRUM_RPC_URL` and remain
opt-in. The deterministic and fuzz reserve-fill invariant suites both
run by default; invariant runs/depth come from
`[profile.default.invariant]` in `foundry.toml`.

### Residual checklist (NOT deploy-blockers)

| # | Item | Status |
|---|------|--------|
| 1 | `lib/VERSIONS.md` recording upstream commit SHAs for vendored
      `v4-core`, `v4-periphery`, `forge-std`, `openzeppelin-contracts`,
      `permit2`, `solmate` | 🔶 PENDING |
| 2 | CI workflow runs deterministic + fuzz reserve-fill invariant
      suites by default | ✅ DONE (`8c962fa`) |
| 3 | Hook-risk / audit-readiness doc — single-page summary of attack
      surface, trust assumptions, operator runbook (rescue, retry,
      acknowledge, pause) | 🔶 PENDING |

The V2.1 first-deposit donation note (founder seed-deposit recommended)
stands; nothing in this hardening pass affects that operational guidance.

### Stack rating after V2.2

**A** (unchanged from V2.1 closeout). The new attack surface introduced
by the reserve-sale state machine is now under both deterministic and
random-sequence fuzz invariant coverage; the operational failure modes
(failed distributions, native-ETH dust, NAV anchor drift) have explicit
on-chain primitives rather than implicit assumptions. The V2.1 residual
items R1 and R2 are closed; the remaining checklist items are
documentation, not contract changes.

The V2.1 and V1 reports follow unchanged for historical reference and
are **superseded for deployment guidance** by this section.

---

## V2.1 Re-test Verdict — 2026-04-27 @ `44fc5fe` _(superseded by V2.2)_

**Status: V2.1 SHIPPED, AUDIT-READY — 154/154 tests pass (incl. real-PoolManager end-to-end coverage of the new reserve-sale path).**

V2.1 introduces two new contracts that supersede V1 in the canonical
deployment path:

| Contract | Purpose |
|----------|---------|
| `DynamicFeeHookV2` | V1 dynamic-fee logic + per-pool reserve-sale (limit-order) fills via `beforeSwapReturnDelta`. |
| `LiquidityVaultV2` | ERC-4626 USDC-entry vault with fair-share zap accounting and reserve-offer glue. |

V1 contracts (`DynamicFeeHook`, `LiquidityVault`, `BootstrapRewards`,
`FeeDistributor`) are unchanged from the `22894ce` re-test and remain
deployed at their existing addresses.

### Tier-1 audit findings on V2.1 (self-disclosed and remediated)

| Finding | Class | Status | Fix location |
|---------|-------|--------|--------------|
| V2-T1.1 `vaultPriceX192 = sqrtP * sqrtP` overflow | Arithmetic | ✅ FIXED | `DynamicFeeHookV2.sol::_tryFillReserve` — replaced with two `FullMath.mulDiv(_, sqrtP, Q96)` steps; no intermediate ever exceeds 256 bits. |
| V2-T1.2 Silent `giveAmount` clamp | Accounting | ✅ FIXED | `_tryFillReserve` — restructured around `takeCap`-first; inventory-exhaustion path is exact (`takeAmount = takeCap; giveAmount = sellRemaining`); partial-fill path enforces `require(giveAmount <= sellRemaining, "RESERVE_MATH")` invariant. |
| V2-T1.3 Out-of-bounds `vaultSqrtPriceX96` DoS | Validation | ✅ FIXED | `createReserveOffer` reverts `InvalidOffer` if `sqrtP < TickMath.MIN_SQRT_PRICE` or `sqrtP >= TickMath.MAX_SQRT_PRICE`. |
| V2-T1.4 `toBeforeSwapDelta` sign convention | Integration | ✅ VERIFIED | `test/IntegrationV2Reserve.t.sol::test_reserveFill_partialThenAMM` — real `PoolManager` swap, asserts swapper paid exactly `amountIn` of currency0 and received reserve fill + AMM remainder of currency1. |
| V2-T1.5 Vault registration trust path | Authorization | ✅ FIXED | `registerVault` is one-shot per pool (`VaultAlreadyRegistered`); owner cannot silently swap out the depositor's reserve-sale counterparty. |
| V2-T1.6 Fee-on-transfer rejection | Hardening | ✅ FIXED | `createReserveOffer` snapshots `balanceOf` pre/post `safeTransferFrom` and reverts on shortfall. |
| V2.1 inflation/donation on first deposit | Hardening | ✅ MITIGATED | `LiquidityVaultV2.depositWithZap` snapshots `totalAssets()` + `totalSupply()` BEFORE pulling assets, computes `netAdded = totalAfter − totalBefore`, mints `shares = netAdded.mulDiv(supplyBefore + 10**_decimalsOffset(), totalBefore + 1, Floor)`, with `minSharesOut` slippage gate. |

**Bonus hardening shipped with V2.1 (beyond required fixes):**
- `_decimalsOffset() = 6` carried over from V1 (4626 inflation defence).
- `Ownable2Step` on hook + vault (no single-step ownership transfer).
- `ReentrancyGuard` on `createReserveOffer` / `cancelReserveOffer` /
  `claimReserveProceeds`.
- Per-pool transient-storage slots for the volatility multiplier
  (no cross-pool contamination).
- Reserve fill is gated by current AMM `sqrtPrice` so the offer can only
  fire when it is **at-or-better** than the AMM for the swapper.

### V2.1 test inventory — 154/154 pass

```
forge test --no-match-test testFork
Ran 13 test suites: 154 tests passed, 0 failed, 0 skipped
```

Highlights of new coverage:

- `test/DynamicFeeHookV2.t.sol` (8 tests) — registration one-shot, escrow
  pull, double-create revert, cancel returns escrow, unknown-currency
  revert, claim-when-zero, **`MIN_SQRT_PRICE`/`MAX_SQRT_PRICE` boundary
  reverts**.
- `test/IntegrationV2Reserve.t.sol` (4 tests, **real PoolManager**) —
  partial-then-AMM fill with sign-convention assertion, partial-fill
  branch, direction-mismatch skip, cancel round-trip.
- `test/LiquidityVaultV2.t.sol` (6+ tests) — `minSharesOut` gate,
  reserve-hook glue, fair-share invariants.

### Residual items (audit scope, NOT deploy-blockers)

These are documented for the auditor; none are exploitable on a deploy
of V2.1 with the current Tier-1 fixes in place:

1. **Volatility-oracle freeze on 100%-reserve-absorbed swaps.** When a
   reserve fill consumes the entire swap input, the AMM leg is ~0, so
   `_lastSqrtPriceX96` may not refresh across blocks. Worst case the
   multiplier defaults to `100` (= no boost), so the failure mode is
   benign (under-charging fees), not over-charging.
2. **No fuzz/invariant test on `_tryFillReserve` math** across the full
   `(sqrtP, sellRemaining, maxInput)` cube. Concrete unit + integration
   tests exist; symbolic / fuzz expansion deferred to audit window.
3. **First-deposit donation attack on an empty vault.** Mitigated by
   `_decimalsOffset = 6` and `minSharesOut`, but a sufficiently large
   donation pre-first-deposit can still grief share precision. Recommend
   founder seed-deposit at deployment, same as V1.

### Stack rating after V2.1

**A** — same as the V1 closeout. V2.1 introduces meaningful new attack
surface (the reserve-sale state machine) but ships with overflow-safe
math, bounds enforcement, real-PoolManager end-to-end coverage, and a
tested invariant for the fill math. Recommend mainnet deploy proceed
behind the same staged-TVL ramp as V1 (see §4 below).

The V1 closeout report follows unchanged for historical reference.

---

## Re-test Verdict — 2026-04-25 @ `22894ce` _(superseded by V2.2)_

**Status: ALL FINDINGS REMEDIATED — 119/119 tests pass (incl. 4 invariants × 256 runs).**

| Finding | Status | Fix commit / location |
|---------|--------|------------------------|
| H-1 unspecified-currency fee | ✅ FIXED | `DynamicFeeHook.sol` L106 — `(zeroForOne == exactInput) ? c1 : c0`; regression `test_h1_exactOutput_zeroForOne_takesFeeOnInputCurrency` + oneForZero variant |
| H-2 rescueIdle drains depositors | ✅ FIXED | `LiquidityVault.sol` L450-L453 — both pool currencies blocked once `_poolKeySet`; idle non-asset valued in `totalAssets()`; regression `test_h2_rescueIdle_blocksNonAssetPoolCurrency` |
| M-1 NAV ignores non-asset leg | ✅ FIXED | `LiquidityVault.sol` L101-L150 — both legs converted via `FullMath.mulDiv(_, priceX192, 1<<192)`; regression `test_m1_totalAssets_includesIdleNonAssetCurrency` |
| M-2 missing onlyPoolManager | ✅ FIXED | `beforeSwap`/`afterSwap` both gated by `onlyPoolManager` |
| L-1 nextTokenId race | ✅ FIXED | Post-call `nextTokenId == expected+1` invariant; regression `test_l1_tokenIdRace_revertsDeposit` |
| L-2 hardcoded slippage | ✅ FIXED | `removeLiquiditySlippageBps`, owner-set, capped at 1000 BPS |
| L-3 60s deadlines | ✅ FIXED | `txDeadlineSeconds`, owner-set, capped at 3600s |
| INFO (fee split / setTreasury(0) / volatility) | ✅ FIXED | `setTreasuryShare` (cap 50%), `setTreasury` rejects `address(0)`, block-boundary anti-sandwich guard on volatility oracle |

**Bonus hardening added by the team beyond requested fixes:**
- `maxFeeBps` ceiling on hook fee, owner-adjustable, capped at 1000 BPS.
- ERC-4626 inflation-attack mitigation via `_decimalsOffset() = 6`.
- Intra-block sandwich protection on `lastSqrtPriceX96` (reference price refresh gated by block boundary).

The original report below is preserved for historical reference.

---

## A-Grade Closeout — 2026-04-25 (post-fix expansion)

After the 8-finding remediation at `22894ce`, four follow-up lifts were
executed to upgrade the whole-stack rating from A− to A.

### 1. Extended audit — `src/BootstrapRewards.sol` (480 LoC, added 2026-04-23)

This contract was added after the original audit window and was not in the
original scope. Full review produced one new high-severity finding.

#### H-3 — Lazy-poke over-claim via balance-rebate

**Where:** `BootstrapRewards.sol` `_poke()`.
**Class:** Accounting / authorization.

**Bug.** `BootstrapRewards` tracks per-user share-seconds with a "lazy poke"
model: `_poke(user)` credits the interval `[u.lastPoke, now]` at
`u.lastBalance` (the share balance snapshotted at the previous poke). The
docstring states front-ends "should call `poke` on deposit/withdraw" — but
`LiquidityVault` does not override `_update` to call into `BootstrapRewards`,
so balance changes can occur without any on-chain notification. An attacker
can:

1. Deposit `X` shares and call `poke` once (`lastBalance = X`, dwell starts).
2. Wait `dwell + Δ`.
3. Transfer / withdraw to ~0 shares **without** calling `poke`. The
   contract still believes `lastBalance == X`.
4. Optionally re-deposit dust so the next-poke "balance hit zero" branch
   does not reset `firstDepositTime`.
5. Call `poke` (or `claim`) — the entire elapsed interval is credited at
   `X`, even though the attacker held ~0 the whole time.

This drains the bonus pool and disenfranchises honest LPs.

**Fix applied (this report).** `_poke` now accrues the unpoked interval at
`min(u.lastBalance, vault.balanceOf(user))`. Rationale: the contract knows
neither when nor how much the balance changed between pokes, so the
strictly conservative bound is the smaller of the two endpoints. Honest
users who poke at every balance change are unaffected; users who skip
poke before reducing their balance forfeit the unaccrued portion of that
window — the documented contract.

```solidity
// src/BootstrapRewards.sol — _poke (excerpt, post-fix)
uint256 newBal = vault.balanceOf(user);
if (accrualEnd > u.lastPoke && u.firstDepositTime != 0) {
    uint256 effective = uint256(u.lastBalance) < newBal ? uint256(u.lastBalance) : newBal;
    if (effective > 0) {
        uint256 dwellEnd = uint256(u.firstDepositTime) + uint256(dwellPeriod);
        uint256 start = u.lastPoke > dwellEnd ? u.lastPoke : dwellEnd;
        if (accrualEnd > start) {
            _accrueInterval(user, start, accrualEnd, effective);
        }
    }
}
```

**Regression test.** `test/BootstrapRewards.t.sol::test_H3_lazyPoke_overClaim_isMitigated`
constructs the attack path (deposit 1000 → unpoked transfer to 1 wei → 22-day
wait → poke) and asserts post-fix accrual ≤ `22 days × 1` instead of the
pre-fix `22 days × 1000e18`. The previously passing
`test_poke_balanceTo0ResetsDwell` was updated: it had codified the
buggy lenient behavior and now asserts zero credit when poke is skipped
before transferring.

**Severity:** High pre-fix → **MITIGATED** post-fix.

#### Notes (lower severity, accepted as-is)

- **Order-dependent global cap.** `_accrueInterval` uses a soft per-epoch
  cap `globalShareCap × epochLength`; the first depositor to poke in an
  epoch can exhaust it. Mitigation is operational (front-end batch-poke
  during the finalization window). Documented in the contract's NatSpec.
- **`pullInflow` loops `epochCount` times.** Spec uses `epochCount = 6`,
  so gas is bounded. Document the upper bound for any future redeploy.
- **No reentrancy hooks** on `payoutAsset` (USDC). Functions still carry
  `nonReentrant` for defense-in-depth. ✓.

### 2. `vaultStatus()` public view added to `LiquidityVault`

A new public enum + view exposes the vault's coarse operational state
(`UNCONFIGURED | PAUSED | IN_RANGE | OUT_OF_RANGE`). UIs and monitors
no longer have to reproduce the in-range tick math client-side.

```solidity
function vaultStatus() public view returns (VaultStatus) {
    if (paused()) return VaultStatus.PAUSED;
    if (!_poolKeySet) return VaultStatus.UNCONFIGURED;
    (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
    if (sqrtPriceX96 == 0) return VaultStatus.UNCONFIGURED;
    uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
    uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
    if (sqrtPriceX96 >= sqrtLower && sqrtPriceX96 < sqrtUpper) return VaultStatus.IN_RANGE;
    return VaultStatus.OUT_OF_RANGE;
}
```

Coverage: 5 unit tests in `test/LiquidityVault.t.sol`
(`test_vaultStatus_*`) — UNCONFIGURED, PAUSED precedence, OUT_OF_RANGE
below/above, IN_RANGE inside the configured window.

### 3. Arbitrum fork test suite (`test/Fork.t.sol`)

Three end-to-end tests against canonical Arbitrum One v4 infrastructure:

| Address | Role |
|---------|------|
| `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Permit2 |
| `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` | v4 PoolManager |
| `0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869` | v4 PositionManager |
| `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | USDC (native) |
| `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | WETH |

Tests:

- `test_fork_smoke_setPoolKeyAndDeposit` — deploy → `setPoolKey` → deposit
  through real PositionManager+Permit2.
- `test_fork_vaultStatus_matchesLiveSlot0` — read live `getSlot0`, assert
  `vaultStatus()` returns a well-defined non-PAUSED value.
- `test_fork_depositWithdrawRoundTrip` — deposit/redeem round-trip with
  NAV consistency.

Tests skip cleanly when `ARBITRUM_RPC_URL` is unset, so the default
`forge test` run remains green for contributors without an RPC. Activate with:

```sh
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc forge test --match-contract Fork
```

### 4. Initial TVL cap (operational)

The vault already exposes `setMaxTVL(uint256)` (owner-adjustable, no upper
cap because `0` means unlimited). The current default of `0` is the
correct deploy-time choice — but a launch ramp is recommended:

| Phase | Suggested `maxTVL` |
|-------|--------------------|
| Week 0–2 (canary) | `100_000e6` (~$100k USDC) |
| Week 3–4 (limited public) | `250_000e6` (~$250k USDC) |
| Week 4+ (graduated) | unlimited (`0`) once telemetry is clean |

Owner action:

```solidity
liquidityVault.setMaxTVL(100_000e6); // immediately post-deploy
```

This is documented here rather than baked into the constructor to avoid
an ABI break for existing deployment scripts.

### Final verdict

**125/125 tests pass** (4 invariants × 256 runs each + 6 new unit tests +
3 fork-stub tests skipped when no RPC). H-3 mitigated. `vaultStatus()`
shipped. Fork harness in place. Stack rating: **A**.

---

## Summary

| ID  | Severity | Title |
|-----|----------|-------|
| H-1 | High     | `DynamicFeeHook` charges exact-output swaps in the wrong currency, leaking value from LPs |
| H-2 | High     | `LiquidityVault` non-asset side of in-range withdrawals is captured by `rescueIdle()` |
| M-1 | Medium   | `totalAssets()` ignores the non-asset leg of the live position |
| M-2 | Medium   | Hook callbacks lack `onlyPoolManager` modifier |
| L-1 | Low      | `expectedTokenId = positionManager.nextTokenId()` race |
| L-2 | Low      | `_removeLiquidity` slippage hard-coded to 0.5% |
| L-3 | Low      | 60s deadlines on `modifyLiquidities` |
| INFO | Info    | Fee split hardcoded; volatility threshold lives in sqrtPrice space |

---

## H-1 — Exact-output swaps charge fee in wrong currency, draining LPs

**Files:** `src/DynamicFeeHook.sol#L80-L100`, `#L122-L137`

### Code

```solidity
// beforeSwap
uint256 amountIn = params.amountSpecified < 0
    ? uint256(-params.amountSpecified)
    : uint256(params.amountSpecified);
uint256 fee = (amountIn * HOOK_FEE_BPS) / BPS_DENOMINATOR;
...
Currency feeCurrency = params.zeroForOne ? key.currency1 : key.currency0;
// stash (fee, feeCurrency) in transient storage

// afterSwap
poolManager.take(feeCurrency, address(this), fee);
feeCurrency.transfer(address(feeDistributor), fee);
feeDistributor.distribute(feeCurrency, fee);
return (BaseHook.afterSwap.selector, int128(uint128(fee)));
```

### Bug

In Uniswap v4, when a hook returns `afterSwapReturnDelta = true`, the `int128`
returned from `afterSwap` is applied to the **unspecified** currency:

| `amountSpecified` sign | Type            | Specified | Unspecified |
|------------------------|-----------------|-----------|-------------|
| negative               | exact-input     | INPUT     | OUTPUT      |
| positive               | exact-output    | OUTPUT    | INPUT       |

`feeCurrency` is statically computed from `zeroForOne` only (`zeroForOne →
currency1`), which equals the **OUTPUT** currency in both directions. That
matches the unspecified currency only on exact-input swaps.

For an **exact-output** swap, the hook:

1. `take`s `fee` units of the OUTPUT currency from the pool (correct token),
2. returns a delta on the INPUT currency, so the swap router bills the user
   `fee` units of the INPUT currency.

If the two currencies have different USD prices, the pool loses
`fee × (priceOut − priceIn) / priceIn`.

### Concrete example

Pool: `USDC (c0) / WBTC (c1)`, price ≈ \$60 000.
User executes an exact-output `zeroForOne` swap to obtain 1 WBTC = 1e8 sats.

- `amountIn = amountSpecified = 1e8`
- `fee = 1e8 * 25 / 10_000 = 2.5e5` sats
- Hook `take`s 2.5e5 sats WBTC ≈ \$150 from the pool
- afterSwap returns `int128(2.5e5)` applied to the INPUT currency (USDC)
  → router bills user 2.5e5 micro-USDC = **\$0.25**
- Treasury gets ~\$30 of WBTC; LP donate gets ~\$120 of WBTC; user paid \$0.25

**Net leak ≈ \$150 per swap, recurring on every exact-output trade.**

The same bug affects the volatility multiplier path (1.5× of a wrong-token fee
is still wrong-token).

### Suggested fix

Either:

```solidity
// option A: charge fee in the unspecified currency
bool exactInput = params.amountSpecified < 0;
Currency feeCurrency = (params.zeroForOne == exactInput)
    ? key.currency1
    : key.currency0;
```

or move the fee to `beforeSwap` via `BeforeSwapDelta` so the fee is always
denominated in the input the user is bringing in. Document the chosen
semantics.

### Severity

**High.** Exact-output is the dominant routing pattern for aggregator quotes
and limit-style trades; loss is systemic and proportional to price asymmetry.

---

## H-2 — Non-asset side of in-range withdrawals is silently captured to `rescueIdle()`

**Files:** `src/LiquidityVault.sol#L233-L262`, `#L348-L353`

### Code

```solidity
// _removeLiquidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.DECREASE_LIQUIDITY),
    uint8(Actions.TAKE_PAIR),
    uint8(Actions.SWEEP)
);
bytes[] memory params = new bytes[](3);
params[0] = abi.encode(positionTokenId, liquidityToRemove, amount0Min, amount1Min, "");
params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
params[2] = abi.encode(assetIsToken0 ? poolKey.currency0 : poolKey.currency1, address(this));

uint256 balBefore = IERC20(asset()).balanceOf(address(this));
positionManager.modifyLiquidities(...);
uint256 returned = IERC20(asset()).balanceOf(address(this)) - balBefore;
// only `returned` (asset side) feeds back into ERC4626 share accounting

// later
function rescueIdle(address token) external onlyOwner {
    require(token != asset(), "CANNOT_RESCUE_ASSET");
    uint256 idle = IERC20(token).balanceOf(address(this));
    require(idle > 0, "NO_IDLE");
    IERC20(token).safeTransfer(owner(), idle);
}
```

### Bug

`TAKE_PAIR(c0, c1, vault)` pulls **both** currencies out of the position into
the vault. When pool price has moved INTO range, a position holds non-zero
amounts of both tokens. `withdraw()` and `redeem()` only forward the **asset**
side to the redeeming user; the non-asset side accumulates as idle in the
vault.

`rescueIdle(otherToken)` then lets the owner sweep that accumulated balance
to themselves. Since `_collectYield()` also routes non-asset yield through the
same accumulator (`currency1YieldCollected`), the net effect is that any
non-asset value released by user redemptions is silently transferred to the
treasury via owner action, with no credit back to the redeemer.

This is a recurring depositor loss on every withdrawal that occurs while the
pool price is inside `[tickLower, tickUpper]`. Combined with **M-1**, share
price already understates NAV at that moment, so the same redeemer is
under-credited twice.

### Concrete example

USDC vault, pool USDC/WETH at range `[2000, 4000]`, current price 3000.
A redeem proportional to 10% of the position releases:

- ~5 000 USDC (asset side) → user
- ~1.667 ETH (non-asset side) → idle in vault → owner via `rescueIdle`

Loss to user ≈ 50% of the dollar value they were entitled to.

### Suggested fix

Pick one and document:

1. Inside `_removeLiquidity`, swap the non-asset side back to asset (with a
   user-supplied min-out) before settling the user's withdraw.
2. Track per-share entitlement to non-asset proceeds and pay both currencies
   on redeem.
3. Restrict `rescueIdle` so it cannot sweep the position's two currencies, or
   require the vault to be paused with an explicit user-rescue path.

### Severity

**High.** Default vault behaviour silently loses depositor funds while the
pool is in range; severity is bounded only by how often the price excursions
happen and how aggressive the owner is with `rescueIdle`.

---

## M-1 — `totalAssets()` ignores the non-asset leg of the live position

**File:** `src/LiquidityVault.sol#L88-L102`

### Code

```solidity
(uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
(uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
    sqrtPriceX96, sqrtA, sqrtB, uint128(totalLiquidityDeployed)
);
return idle + (assetIsToken0 ? amt0 : amt1);
```

### Bug

When the price moves into range, the position holds both `amt0` and `amt1`,
but NAV reports only one side. Real value (in asset units) is
`amt_asset + amt_other × P_other_in_asset`, where `P` is derived from
`sqrtPriceX96`.

Effects:

- Share price drops on price excursion even though no value left the system.
- `convertToAssets(shares)` under-reports a redemption's payout, so
  `withdraw(assets, ...)` may revert spuriously and `redeem(shares, ...)`
  pays out less than fair value.
- Couples with H-2: under-reported NAV plus owner sweeping the non-asset
  payout = double depositor loss.

### Suggested fix

```solidity
uint256 assetSide   = assetIsToken0 ? amt0 : amt1;
uint256 otherSide   = assetIsToken0 ? amt1 : amt0;
uint256 priceX96    = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) >> 96;
// convert otherSide to asset units using priceX96 with correct decimals
uint256 otherInAsset = assetIsToken0
    ? FullMath.mulDiv(otherSide, 1 << 96, priceX96)   // c1 → c0
    : FullMath.mulDiv(otherSide, priceX96, 1 << 96);  // c0 → c1
return idle + assetSide + otherInAsset;
```

### Severity

**Medium** on its own (NAV mis-pricing), upgraded in combination with H-2.

---

## M-2 — Hook callbacks lack `onlyPoolManager`

**File:** `src/DynamicFeeHook.sol#L74`, `#L110`

`BaseHook` declares `onlyPoolManager` but `beforeSwap`/`afterSwap` do not
apply it. Today the v4 unlock invariant ("all currencies must net to zero
inside an unlock") prevents an EOA from profitably calling these directly
because the hook's `take` would leave the unlock unbalanced. This is
defense-in-depth; add the modifier:

```solidity
function beforeSwap(...) external override onlyPoolManager returns (...)
function afterSwap(...) external override onlyPoolManager returns (...)
```

### Severity

**Medium**, defense-in-depth.

---

## L-1 — `expectedTokenId = positionManager.nextTokenId()` race

**File:** `src/LiquidityVault.sol#L188`

```solidity
uint256 expectedTokenId = positionManager.nextTokenId();
positionManager.modifyLiquidities(...);
positionTokenId = expectedTokenId;
```

If anything called during `modifyLiquidities` (e.g. a permit2 hook or a
custom router) mints a `PositionManager` NFT first, `expectedTokenId` is
stale and `positionTokenId` would point at a third-party NFT. Unlikely on
canonical PositionManager but cheap to harden:

```solidity
positionTokenId = positionManager.tokenOfOwnerByIndex(address(this), 0);
```

or read from the return value of `modifyLiquidities` if the deployment
exposes one.

---

## L-2 — `_removeLiquidity` slippage hard-coded to 0.5%

**File:** `src/LiquidityVault.sol#L246-L247`

```solidity
uint256 amount0Min = exp0 * 995 / 1000;
uint256 amount1Min = exp1 * 995 / 1000;
```

Volatile pools or sandwich pressure will cause `withdraw()`/`redeem()` to
revert. Make the slippage configurable per-call (preferable) or per-vault.

---

## L-3 — 60s deadlines on `modifyLiquidities`

`block.timestamp + 60` is fine for direct-from-frontend calls but breaks any
queued / batched / multisig tx that lingers in mempool. Either widen
internally or expose a parameter.

---

## Informational

- **Fee split is hardcoded** at `TREASURY_SHARE = 20` / `LP_SHARE = 80` in
  `FeeDistributor`. No setter. If this is intentional, document; otherwise
  consider an owner-tunable `setShares(uint256)` with caps.
- **`VOLATILITY_THRESHOLD_BPS = 100`** in `DynamicFeeHook.sol` is measured in
  `sqrtPriceX96` space, not price space — a 100 bps `sqrtPrice` move ≈ 200
  bps price move. Document or convert.
- `setTreasury` in `LiquidityVault` accepts `address(0)`; `_collectYield`
  already handles zero treasury, but other accounting paths assume a valid
  treasury — review or add a non-zero check.
- `DynamicFeeHook.afterSwap` always returns `int128(uint128(fee))` even after
  `poolManager.take(...)` has already settled; this is correct only if the
  delta semantics described in H-1 are fixed. Re-check after the H-1 fix.

---

## Priority ordering

1. **H-1** — direct LP value extraction on every exact-output swap.
2. **H-2** — silent depositor loss on every in-range withdrawal.
3. **M-1** — NAV mis-reporting; couples with H-2.
4. **M-2** — defense-in-depth.
5. **L-\* / INFO** — robustness, UX, documentation.

H-1 and H-2 are real value-loss paths under normal usage, not just adversarial
edge cases. They should be fixed before any mainnet deployment.
