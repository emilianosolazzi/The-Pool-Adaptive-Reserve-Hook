# Value Calculator Code Examples (Contract-Accurate)

For user-facing estimates, `feeBasisAmount` may be approximated with swap notional.
For contract-accurate accounting, it is the absolute value of the swap's unspecified-currency delta in `DynamicFeeHookV2.afterSwap`.

## JavaScript / TypeScript

### 1) Hook Fee With Volatility + Cap

```ts
type HookFeeInput = {
  feeBasisAmount: bigint; // abs unspecified-currency delta, token units
  isVolatile: boolean;
  hookFeeBps?: bigint;   // DynamicFeeHookV2.HOOK_FEE_BPS (default 25)
  maxFeeBps?: bigint;    // DynamicFeeHookV2.maxFeeBps (default 50)
};

export function computeHookFee({
  feeBasisAmount,
  isVolatile,
  hookFeeBps = 25n,
  maxFeeBps = 50n,
}: HookFeeInput): bigint {
  const base = (feeBasisAmount * hookFeeBps) / 10_000n;
  const withVol = isVolatile ? (base * 150n) / 100n : base;
  const cap = (feeBasisAmount * maxFeeBps) / 10_000n;
  return withVol < cap ? withVol : cap;
}
```

### 2) Distributor Split (Hook Fee Only)

```ts
export function splitHookFee(hookFee: number, treasuryShare = 20) {
  const treasuryAmount = (hookFee * treasuryShare) / 100;
  const lpDonation = hookFee - treasuryAmount;
  return { treasuryAmount, lpDonation };
}
```

### 3) Vault Capture Estimate (Needs Liquidity Share Input)

```ts
type VaultCaptureInput = {
  lpDonation: number;      // from FeeDistributor (hook fee path)
  poolFeeAmount: number;   // native pool fee path
  vaultLiquidityShare: number; // phi in [0, 1]
  performanceFeeBps: number;   // LiquidityVaultV2.performanceFeeBps
};

export function estimateVaultNetAssetYield(input: VaultCaptureInput) {
  // Assumes the captured yield is realized in the vault asset.
  // Non-asset yield is tracked separately by LiquidityVaultV2.
  const gross = input.vaultLiquidityShare * (input.lpDonation + input.poolFeeAmount);
  const net = gross * (1 - input.performanceFeeBps / 10_000);
  return { gross, net };
}
```

### 4) Contract-Style Annualized Rate (APR, Not Compounded APY)

`LiquidityVaultV2` does not expose an on-chain APR/APY projection helper; this is an analytics-side linear APR proxy:

```ts
export function projectedAprBps(recentYield: number, windowSeconds: number, totalAssets: number) {
  if (windowSeconds === 0 || totalAssets === 0) return 0;
  return ((recentYield * 365 * 24 * 60 * 60) / windowSeconds) * (10_000 / totalAssets);
}
```

### 5) If You Also Want Compounded APY For Analytics

```ts
export function compoundedApyFromDailyRate(dailyRate: number) {
  return Math.pow(1 + dailyRate, 365) - 1;
}
```

## Solidity-Style Pseudocode Checks

### 1) Hook Fee Path

```solidity
uint256 fee = absUnspec * 25 / 10_000;
if (isVolatile) fee = fee * 150 / 100;
uint256 cap = absUnspec * maxFeeBps / 10_000;
if (fee > cap) fee = cap;
```

### 2) Distributor Split

```solidity
uint256 treasuryAmount = amount * treasuryShare / 100;
uint256 lpAmount = amount - treasuryAmount;
```

### 3) Vault Performance Fee On Collected Asset Yield

```solidity
uint256 fee = yieldAmount * performanceFeeBps / 10_000;
uint256 net = yieldAmount - fee;
```

## BootstrapRewards Inflow Split (Optional Program)

```ts
export function splitBootstrapInflow(
  inflowAmount: number,
  bonusShareBps: number,
  remainingEpochCap: number,
) {
  const uncappedBonus = (inflowAmount * bonusShareBps) / 10_000;
  const toBonusPool = Math.min(uncappedBonus, remainingEpochCap);
  const toRealTreasury = inflowAmount - toBonusPool;
  return { toBonusPool, toRealTreasury };
}
```

Use these snippets as calculator primitives, and keep `vaultLiquidityShare` and volatility frequency as explicit scenario inputs.