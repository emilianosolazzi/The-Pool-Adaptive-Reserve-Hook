# Value Math Examples (Contract-Accurate)

This page aligns example math with the actual Solidity logic in `DynamicFeeHook`, `FeeDistributor`, `LiquidityVault`, and `BootstrapRewards`.

## 1) Per-Swap Hook Fee (DynamicFeeHook)

Contract constants:
- Base hook fee: `HOOK_FEE_BPS = 25` (0.25%)
- Volatility multiplier: `VOLATILITY_FEE_MULTIPLIER = 150` (1.5x)
- Fee cap: `maxFeeBps` (default 50 bps, owner-adjustable)

Formula per swap:

```
rawHookFee = amountIn * 25 / 10_000
volatileHookFee = rawHookFee * 150 / 100   (only if volatility threshold is met)
hookFee = min(volatileHookFee or rawHookFee, amountIn * maxFeeBps / 10_000)
```

Notes:
- The volatility multiplier applies to the hook fee only.
- Pool LP fee is separate from the hook fee and is not multiplied by the hook volatility factor.

## 2) Hook Fee Split (FeeDistributor)

Contract logic:

```
treasuryAmount = hookFee * treasuryShare / 100        (default treasuryShare = 20)
lpDonation     = hookFee - treasuryAmount             (default 80)
```

Important:
- This split applies only to hook fee routed through `FeeDistributor`.
- Pool LP fee does not go through this 20/80 splitter.

## 3) What the Vault Actually Earns

The vault does not receive 100% of `lpDonation`.

Let:
- `phi` = vault share of active in-range liquidity at donation time (0 to 1)
- `poolFeeAmount` = fees from the underlying pool fee tier

Then expected gross vault fee flow in asset terms is:

```
vaultGross ~= phi * lpDonation + phi * poolFeeAmount
```

Then the vault performance fee is applied when yield is collected in asset token:

```
vaultNetAssetYield = vaultGrossAssetPart * (1 - performanceFeeBps/10_000)
```

`LiquidityVault.totalYieldCollected` tracks net asset-token yield after performance fee.
Non-asset-token yield is tracked separately in `currency1YieldCollected`.

## 4) Worked Per-Swap Example

Assume:
- Swap amount = $100,000
- Not volatile (base fee path)
- `treasuryShare = 20`
- Vault active-liquidity share `phi = 1%`
- Pool fee tier example = 0.01% (100 fee units)

Math:

```
hookFee        = 100,000 * 0.25% = 250
treasuryAmount = 250 * 20% = 50
lpDonation     = 200

poolFeeAmount  = 100,000 * 0.01% = 10

vaultGross     ~= 1% * 200 + 1% * 10 = 2.10
```

If volatile path is active:

```
hookFee        = 250 * 1.5 = 375   (subject to maxFeeBps cap)
treasuryAmount = 75
lpDonation     = 300
vaultGross     ~= 1% * 300 + 1% * 10 = 3.10
```

## 5) Daily Example (Assumptions Explicit)

Assume:
- Daily volume `V = $1,000,000,000`
- Volatility-hit probability `p = 20%`
- Expected hook fee bps = `25 * (1 + 0.5*p) = 27.5 bps`
- Pool fee tier = 0.01% (1 bps)
- `treasuryShare = 20%`
- Vault in-range share `phi = 1%`
- `performanceFeeBps = 400` (4%)
- Vault TVL = $10,000,000

Step-by-step:

```
hookFeesDaily      = V * 0.275% = 2,750,000
lpDonationDaily    = 2,750,000 * 80% = 2,200,000
poolFeesDaily      = V * 0.01% = 100,000

vaultGrossDaily    ~= phi * (lpDonationDaily + poolFeesDaily)
				  ~= 1% * (2,200,000 + 100,000)
				  = 23,000

vaultNetDaily      = 23,000 * (1 - 4%) = 22,080
dailyYieldRate     = 22,080 / 10,000,000 = 0.2208%
```

## 6) APR vs APY (matches contract semantics)

`LiquidityVault.getProjectedAPY(recentYield, windowSeconds)` actually returns linear annualized rate in bps:

```
aprBps = (recentYield * 365 days / windowSeconds) * 10_000 / totalAssets
```

Using the daily example above (`dailyYieldRate = 0.2208%`):

```
APR (linear) = 0.2208% * 365 = 80.59%
```

If you choose to model external daily compounding, APY would be:

```
APY = (1 + 0.002208)^365 - 1 ~= 123.7%
```

This compounding APY is an analytical projection, not what `getProjectedAPY` returns.

## 7) BootstrapRewards Math (Optional Layer)

`BootstrapRewards` is configurable, not fixed at one hardcoded bonus percentage.

If enabled and the payout asset arrives at amount `A`:

```
toBonusPool = min(A * bonusShareBps / 10_000, remainingPerEpochCap)
toRealTreasury = A - toBonusPool
```

So bonus impact depends on deployment config:
- `bonusShareBps`
- `epochLength`
- `epochCount`
- `perEpochCap`
- user share-seconds accrual and claim timing

## Practical Reading Guide

- Treat volume, volatility frequency, and in-range share (`phi`) as scenario inputs.
- Treat fee constants, split rules, and performance fee as contract-enforced mechanics.
- For dashboards, label outputs clearly as either `APR (linear, contract-style)` or `APY (compounded projection)`.