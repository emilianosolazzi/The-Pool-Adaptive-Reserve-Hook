# The-Pool Audit Report

![PASSED — TSI Audit Scanner](assets/badge-passed.svg)

**Repo:** https://github.com/emilianosolazzi/The-Pool
**Date:** 2026-04-25 (initial) · **Re-test:** 2026-04-25 @ commit `22894ce`
**Scope:** `src/BaseHook.sol`, `src/DynamicFeeHook.sol`, `src/FeeDistributor.sol`, `src/LiquidityVault.sol` (~800 LoC)
**Stack:** Uniswap v4 hook + ERC-4626 single-asset LP vault, Solidity ^0.8.24

---

## Re-test Verdict — 2026-04-25 @ `22894ce`

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
