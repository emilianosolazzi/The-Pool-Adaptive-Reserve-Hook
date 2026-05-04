/**
 * Reserve-offer keeper for The Pool.
 *
 * Posts and rebalances VAULT_SPREAD reserve offers on
 * `LiquidityVaultV2` so the vault monetises spread vs. the AMM mid as
 * additional NAV. See `docs/HOOK-RISK-RUNBOOK.md` §3.4 for the policy.
 *
 * By default the keeper key must be the vault `owner()`. If
 * `KEEPER_WRITE_TARGET` is set, the vault owner must be that controller
 * contract and the keeper key must be allowlisted by
 * `controller.reserveKeepers(keeper)`.
 *
 * Required env:
 *   ARBITRUM_RPC_URL       JSON-RPC endpoint
 *   KEEPER_PRIVATE_KEY     0x-prefixed private key for the vault owner
 *   VAULT                  LiquidityVaultV2 address
 *   VAULT_LENS             VaultLens address (provides vaultStatus(address))
 *   HOOK                   DynamicFeeHookV2 address
 *   KEEPER_WRITE_TARGET    Optional controller address that owns the vault
 *
 * Tunables (all optional):
 *   SPREAD_BPS                25       // vault premium vs AMM mid (bps)
 *   REBALANCE_DRIFT_BPS       50       // rebalance when |drift| >= this
 *   MAX_OFFER_BPS_OF_IDLE     500      // 5% of idle asset per offer
 *   OFFER_TTL_SECONDS         900      // 15 min expiry
 *   MIN_SELL_AMOUNT           1000000  // 1 USDC at 6 decimals
 *   GAS_SAFETY_MULTIPLIER     3        // require expectedSpread >= 3 * gasCost
 *   ASSET_PER_NATIVE_E18      0        // asset units per 1e18 wei native;
 *                                      // 0 disables the profitability guard
 *   DRY_RUN                   false    // simulate only, do not broadcast
 *   LOOP                      false    // run forever vs single tick
 *   INTERVAL_MS               60000    // base sleep between ticks
 *   JITTER_MS                 15000    // random extra sleep [0, JITTER_MS]
 *
 * Observability (all optional):
 *   METRICS_HOST              127.0.0.1 // bind address for /metrics
 *   METRICS_PORT              0         // expose Prometheus /metrics on this
 *                                       // port; 0 disables the HTTP server
 *   ALERT_WEBHOOK_URL         ''       // Slack/Discord-compatible webhook;
 *                                      // empty disables alerting
 *   ALERT_COOLDOWN_SECONDS    600      // per-alert-key dedupe window
 */
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  type Address,
} from 'viem';
import { arbitrum } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { createServer, type Server } from 'node:http';

const RPC_URL = mustEnv('ARBITRUM_RPC_URL');
const KEEPER_PRIVATE_KEY = mustEnv('KEEPER_PRIVATE_KEY') as `0x${string}`;

const VAULT = mustEnv('VAULT') as Address;
const VAULT_LENS = mustEnv('VAULT_LENS') as Address;
const HOOK = mustEnv('HOOK') as Address;
const KEEPER_WRITE_TARGET = process.env.KEEPER_WRITE_TARGET as Address | undefined;
const WRITE_TARGET = KEEPER_WRITE_TARGET || VAULT;
const CONTROLLER_MODE = Boolean(KEEPER_WRITE_TARGET);

const DRY_RUN = process.env.DRY_RUN === 'true';

const SPREAD_BPS = BigInt(process.env.SPREAD_BPS ?? '25');
const REBALANCE_DRIFT_BPS = BigInt(process.env.REBALANCE_DRIFT_BPS ?? '50');
const MAX_OFFER_BPS_OF_IDLE = BigInt(process.env.MAX_OFFER_BPS_OF_IDLE ?? '500');
const OFFER_TTL_SECONDS = BigInt(process.env.OFFER_TTL_SECONDS ?? '900');
const MIN_SELL_AMOUNT = BigInt(process.env.MIN_SELL_AMOUNT ?? '1000000');

// ── Tunable bounds ────────────────────────────────────────────────────
// Reject obviously broken configurations at startup so a typo in env
// can never produce a write that the contract will accept but is
// economically nonsensical (e.g. 0% spread, 100%+ of idle, 0 TTL).
if (SPREAD_BPS === 0n || SPREAD_BPS >= 20_000n) {
  throw new Error(`SPREAD_BPS=${SPREAD_BPS} out of range (must be in (0, 20000))`);
}
if (MAX_OFFER_BPS_OF_IDLE === 0n || MAX_OFFER_BPS_OF_IDLE > 10_000n) {
  throw new Error(
    `MAX_OFFER_BPS_OF_IDLE=${MAX_OFFER_BPS_OF_IDLE} out of range (must be in (0, 10000])`,
  );
}
if (OFFER_TTL_SECONDS === 0n) {
  throw new Error('OFFER_TTL_SECONDS must be > 0');
}
if (REBALANCE_DRIFT_BPS === 0n) {
  throw new Error('REBALANCE_DRIFT_BPS must be > 0 (else every tick rebalances)');
}

// Profitability guard. Skip a write if the *expected* spread profit on the
// offer (in `asset` units) is below `gasCost * GAS_SAFETY_MULTIPLIER`,
// where gasCost is priced in `asset` via ASSET_PER_NATIVE_E18 (asset units
// per 1e18 wei of native). On Arbitrum this is cheap, but the guard avoids
// dust rebalances. Set ASSET_PER_NATIVE_E18=0 to disable.
const GAS_SAFETY_MULTIPLIER = BigInt(process.env.GAS_SAFETY_MULTIPLIER ?? '3');
const ASSET_PER_NATIVE_E18 = BigInt(process.env.ASSET_PER_NATIVE_E18 ?? '0');

// Loop jitter. Each tick sleeps INTERVAL_MS + random([0, JITTER_MS]).
const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? '60000');
const JITTER_MS = Number(process.env.JITTER_MS ?? '15000');

// Observability. Both are opt-in.
const METRICS_HOST = process.env.METRICS_HOST ?? '127.0.0.1';
const METRICS_PORT = Number(process.env.METRICS_PORT ?? '0');
const ALERT_WEBHOOK_URL = process.env.ALERT_WEBHOOK_URL ?? '';
const ALERT_COOLDOWN_SECONDS = Number(process.env.ALERT_COOLDOWN_SECONDS ?? '600');

if (!Number.isInteger(METRICS_PORT) || METRICS_PORT < 0 || METRICS_PORT > 65_535) {
  throw new Error(`METRICS_PORT=${process.env.METRICS_PORT} out of range (must be 0-65535)`);
}

// ReservePricingMode enum (see src/DynamicFeeHookV2.sol):
//   0 = PRICE_IMPROVEMENT
//   1 = VAULT_SPREAD
const VAULT_SPREAD_MODE = 1 as const;

// LiquidityVaultV2.VaultStatus enum:
//   0 = UNCONFIGURED
//   1 = PAUSED
//   2 = IN_RANGE
//   3 = OUT_OF_RANGE
const VAULT_STATUS_PAUSED = 1;
const VAULT_STATUS_UNCONFIGURED = 0;

function mustEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

const vaultAbi = parseAbi([
  'function poolKey() view returns (address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)',
  'function asset() view returns (address)',
  'function owner() view returns (address)',
  'function reserveHook() view returns (address)',
]);

const reserveWriteAbi = parseAbi([
  'function offerReserveToHookWithMode(address sellCurrency,uint128 sellAmount,uint160 vaultSqrtPriceX96,uint64 expiry,uint8 mode)',
  'function rebalanceOfferWithMode(address sellCurrency,uint128 sellAmount,uint160 vaultSqrtPriceX96,uint64 expiry,uint8 mode)',
]);

const controllerGuardAbi = parseAbi([
  'function reserveKeepers(address keeper) view returns (bool)',
  'function vault() view returns (address)',
]);

const vaultLensAbi = parseAbi([
  'function vaultStatus(address vault) view returns (uint8)',
]);

const hookAbi = parseAbi([
  'function getOfferHealth((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,address vault) view returns (bool active,int256 driftBps,uint256 escrow0,uint256 escrow1,uint256 proceeds0,uint256 proceeds1,uint160 vaultSqrtPriceX96,uint160 poolSqrtPriceX96)',
  // Storage-level offer view. NOTE: `active` here is the raw storage flag.
  // The hook does NOT auto-clear it on expiry (`_tryFillReserve` just
  // no-ops past `expiry`), so an expired offer still reports active=true
  // and `createReserveOfferWithMode` would revert with OfferAlreadyActive.
  // The keeper must inspect `expiry` and use the rebalance path in that case.
  'function getOffer((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key) view returns ((address sellCurrency,address buyCurrency,uint128 sellRemaining,uint160 vaultSqrtPriceX96,uint64 expiry,bool sellingCurrency1,bool active,uint8 pricingMode))',
  'function failedDistribution(address currency) view returns (uint256)',
]);

const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
]);

const account = privateKeyToAccount(KEEPER_PRIVATE_KEY);

const publicClient = createPublicClient({
  chain: arbitrum,
  transport: http(RPC_URL),
});

const walletClient = createWalletClient({
  account,
  chain: arbitrum,
  transport: http(RPC_URL),
});

function abs(x: bigint): bigint {
  return x < 0n ? -x : x;
}

function capOfferAmount(idleBalance: bigint): bigint {
  return (idleBalance * MAX_OFFER_BPS_OF_IDLE) / 10_000n;
}

// ---- Metrics --------------------------------------------------------------
const metrics = {
  startedAt: new Date().toISOString(),
  startedAtSec: Math.floor(Date.now() / 1000),
  ticks: 0,
  posts: 0,
  rebalances: 0,
  noops: 0,
  errors: 0,
  alertsSent: 0,
  gasSpentWei: 0n,
  spreadBpsLastFill: 0n,
  // Gauges, refreshed each tick. -1 / 0n means "unknown".
  lastTickAtSec: 0,
  lastIdleAsset: 0n,
  lastDriftBps: 0n,
  lastVaultStatus: -1,
  lastFailedAsset: 0n,
  lastOfferActive: 0,
};

function logMetrics() {
  console.log('[metrics]', {
    ...metrics,
    gasSpentWei: metrics.gasSpentWei.toString(),
    spreadBpsLastFill: metrics.spreadBpsLastFill.toString(),
    lastIdleAsset: metrics.lastIdleAsset.toString(),
    lastDriftBps: metrics.lastDriftBps.toString(),
    lastFailedAsset: metrics.lastFailedAsset.toString(),
  });
}

// ---- Prometheus exposition ------------------------------------------------
// Hand-rolled to avoid adding prom-client. Format reference:
// https://prometheus.io/docs/instrumenting/exposition_formats/
function renderProm(): string {
  const lines: string[] = [];
  const push = (
    name: string,
    type: 'counter' | 'gauge',
    help: string,
    value: bigint | number,
  ) => {
    lines.push(`# HELP ${name} ${help}`);
    lines.push(`# TYPE ${name} ${type}`);
    lines.push(`${name} ${value.toString()}`);
  };
  push('keeper_started_at_seconds', 'gauge', 'Unix start time of keeper process.', metrics.startedAtSec);
  push('keeper_last_tick_at_seconds', 'gauge', 'Unix time of last completed tick.', metrics.lastTickAtSec);
  push('keeper_ticks_total', 'counter', 'Total ticks attempted.', metrics.ticks);
  push('keeper_posts_total', 'counter', 'Successful offerReserveToHookWithMode calls.', metrics.posts);
  push('keeper_rebalances_total', 'counter', 'Successful rebalanceOfferWithMode calls.', metrics.rebalances);
  push('keeper_noops_total', 'counter', 'Ticks that took no action.', metrics.noops);
  push('keeper_errors_total', 'counter', 'Tick or send errors.', metrics.errors);
  push('keeper_alerts_sent_total', 'counter', 'Webhook alerts emitted (post-cooldown).', metrics.alertsSent);
  push('keeper_gas_spent_wei', 'counter', 'Cumulative wei spent on successful txs.', metrics.gasSpentWei);
  push('keeper_spread_bps_last_fill', 'gauge', 'SPREAD_BPS used on the last successful write.', metrics.spreadBpsLastFill);
  push('keeper_idle_asset', 'gauge', 'Vault idle asset balance observed last tick.', metrics.lastIdleAsset);
  push('keeper_drift_bps', 'gauge', 'Last observed drift bps (signed).', metrics.lastDriftBps);
  push('keeper_vault_status', 'gauge', 'VaultLens.vaultStatus enum (-1=unknown).', metrics.lastVaultStatus);
  push('keeper_failed_distribution_asset', 'gauge', 'Hook failedDistribution[asset] last tick.', metrics.lastFailedAsset);
  push('keeper_offer_active', 'gauge', '1 if storage-flag active offer existed last tick, else 0.', metrics.lastOfferActive);
  push('keeper_spread_bps_config', 'gauge', 'Configured SPREAD_BPS env.', SPREAD_BPS);
  push('keeper_rebalance_drift_bps_config', 'gauge', 'Configured REBALANCE_DRIFT_BPS env.', REBALANCE_DRIFT_BPS);
  return lines.join('\n') + '\n';
}

async function startMetricsServer(): Promise<Server | undefined> {
  if (METRICS_PORT === 0) return undefined;
  const server = createServer((req, res) => {
    if (req.url === '/metrics') {
      res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' });
      res.end(renderProm());
      return;
    }
    if (req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok\n');
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(METRICS_PORT, METRICS_HOST, () => {
      server.off('error', reject);
      console.log(
        `[metrics] HTTP server listening on ${METRICS_HOST}:${METRICS_PORT} (/metrics, /healthz)`,
      );
      resolve();
    });
  });
  return server;
}

function closeMetricsServer(server: Server | undefined): Promise<void> {
  if (!server) return Promise.resolve();
  return new Promise((resolve, reject) => {
    server.close((err) => {
      if (err) reject(err);
      else resolve();
    });
  });
}

// ---- Alerting -------------------------------------------------------------
// Fires a webhook on operational anomalies. Slack/Discord/Generic JSON
// compatible: posts `{ text: "..." }`. Per-key cooldown prevents spam when
// a condition persists across ticks.
const alertCooldown = new Map<string, number>();

async function alert(key: string, message: string, severity: 'warn' | 'error' = 'warn') {
  if (!ALERT_WEBHOOK_URL) return;
  const nowSec = Math.floor(Date.now() / 1000);
  const last = alertCooldown.get(key) ?? 0;
  if (nowSec - last < ALERT_COOLDOWN_SECONDS) return;
  alertCooldown.set(key, nowSec);
  const text = `[the-pool keeper][${severity}][${key}] ${message}`;
  try {
    const res = await fetch(ALERT_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    });
    if (!res.ok) {
      console.warn(`[alert] webhook returned ${res.status}: ${await res.text().catch(() => '')}`);
      return;
    }
    metrics.alertsSent += 1;
  } catch (err) {
    console.warn('[alert] webhook send failed:', err);
  }
}

/// Approximate the spread the vault would earn on a single full-inventory
/// fill, expressed in `asset` units. For SPREAD_BPS << 10000 this is
/// roughly: sellAmount * SPREAD_BPS / 10000.
function expectedSpreadInAsset(sellAmount: bigint): bigint {
  return (sellAmount * SPREAD_BPS) / 10_000n;
}

/// Convert `gas * gasPriceWei` to `asset` units using ASSET_PER_NATIVE_E18.
/// Returns 0n when ASSET_PER_NATIVE_E18 is unset (guard disabled).
function gasCostInAsset(gas: bigint, gasPriceWei: bigint): bigint {
  if (ASSET_PER_NATIVE_E18 === 0n) return 0n;
  const wei = gas * gasPriceWei;
  return (wei * ASSET_PER_NATIVE_E18) / 10n ** 18n;
}

function sleep(ms: number): Promise<void> {
  return new Promise((res) => setTimeout(res, ms));
}

/**
 * VAULT_SPREAD math.
 *
 * sqrtP = sqrt(P). For small spread s, sqrtP' ≈ sqrtP * (1 ± s/2).
 *
 * Selling currency1 (e.g. USDC) — vault wants pool >= vault, so vault
 * sqrtP must be BELOW pool sqrtP. Use (1 - s/2).
 */
function vaultSpreadSqrtForSellingCurrency1(poolSqrtPriceX96: bigint, spreadBps: bigint): bigint {
  return (poolSqrtPriceX96 * (20_000n - spreadBps)) / 20_000n;
}

/**
 * Selling currency0 (e.g. WETH) — vault wants pool <= vault, so vault
 * sqrtP must be ABOVE pool sqrtP. Use (1 + s/2).
 */
function vaultSpreadSqrtForSellingCurrency0(poolSqrtPriceX96: bigint, spreadBps: bigint): bigint {
  return (poolSqrtPriceX96 * (20_000n + spreadBps)) / 20_000n;
}

async function sendOrPrint(
  label: string,
  functionName: 'offerReserveToHookWithMode' | 'rebalanceOfferWithMode',
  args: readonly [Address, bigint, bigint, bigint, number],
) {
  console.log(`\nAction: ${label}`);
  console.log({ functionName, args: args.map(String) });

  // Profitability guard.
  if (ASSET_PER_NATIVE_E18 > 0n && !DRY_RUN) {
    try {
      const [gas, gasPrice] = await Promise.all([
        publicClient.estimateContractGas({
          account,
          address: WRITE_TARGET,
          abi: reserveWriteAbi,
          functionName,
          args,
        }),
        publicClient.getGasPrice(),
      ]);
      const sellAmount = args[1];
      const expectedProfit = expectedSpreadInAsset(sellAmount);
      const gasCost = gasCostInAsset(gas, gasPrice);
      const required = gasCost * GAS_SAFETY_MULTIPLIER;
      console.log('[profit-guard]', {
        gas: gas.toString(),
        gasPriceWei: gasPrice.toString(),
        gasCostAsset: gasCost.toString(),
        expectedProfitAsset: expectedProfit.toString(),
        requiredAsset: required.toString(),
      });
      if (expectedProfit < required) {
        console.warn(
          `Skipping ${label}: expected profit ${expectedProfit} < required ${required}.`,
        );
        metrics.noops += 1;
        return;
      }
    } catch (err) {
      console.warn('Profitability guard failed; proceeding anyway:', err);
    }
  }

  if (DRY_RUN) {
    console.log('DRY_RUN=true, not sending tx.');
    return;
  }

  const { request } = await publicClient.simulateContract({
    account,
    address: WRITE_TARGET,
    abi: reserveWriteAbi,
    functionName,
    args,
  });

  const hash = await walletClient.writeContract(request);
  console.log(`Tx sent: ${hash}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`Tx status: ${receipt.status}`);
  if (receipt.status === 'success') {
    metrics.gasSpentWei += BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice ?? 0n);
    metrics.spreadBpsLastFill = SPREAD_BPS;
    if (functionName === 'offerReserveToHookWithMode') metrics.posts += 1;
    else metrics.rebalances += 1;
  } else {
    metrics.errors += 1;
    await alert('tx-reverted', `${functionName} reverted on-chain. Tx: ${hash}`, 'error');
  }
}

async function tick() {
  console.log(`\n[${new Date().toISOString()}] Keeper tick`);

  const [pkC0, pkC1, pkFee, pkSpacing, pkHooks] = await publicClient.readContract({
    address: VAULT,
    abi: vaultAbi,
    functionName: 'poolKey',
  });
  const poolKey = {
    currency0: pkC0,
    currency1: pkC1,
    fee: pkFee,
    tickSpacing: pkSpacing,
    hooks: pkHooks,
  } as const;

  const [asset, ownerAddr, vaultStatus, configuredReserveHook] = await Promise.all([
    publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: 'asset' }),
    publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: 'owner' }),
    publicClient.readContract({
      address: VAULT_LENS,
      abi: vaultLensAbi,
      functionName: 'vaultStatus',
      args: [VAULT],
    }),
    publicClient.readContract({
      address: VAULT,
      abi: vaultAbi,
      functionName: 'reserveHook',
    }),
  ]);

  // ── Env-mismatch guards ──────────────────────────────────────────
  // A wrong HOOK env is not fund-stealing (writes go through the
  // vault), but it lets the keeper read health from one hook and post
  // offers that the vault routes to a different hook — producing
  // failing or wasteful writes. Catch it before any write.
  const hookEnvLower = HOOK.toLowerCase();
  if (poolKey.hooks.toLowerCase() !== hookEnvLower) {
    throw new Error(
      `HOOK env ${HOOK} does not match poolKey.hooks ${poolKey.hooks}`,
    );
  }
  if (configuredReserveHook.toLowerCase() !== hookEnvLower) {
    throw new Error(
      `HOOK env ${HOOK} does not match vault.reserveHook ${configuredReserveHook}`,
    );
  }
  const assetLower = asset.toLowerCase();
  const c0Lower = poolKey.currency0.toLowerCase();
  const c1Lower = poolKey.currency1.toLowerCase();
  if (assetLower !== c0Lower && assetLower !== c1Lower) {
    throw new Error(
      `Vault asset ${asset} is not pool currency0/currency1: ${poolKey.currency0}/${poolKey.currency1}`,
    );
  }

  if (CONTROLLER_MODE) {
    const writeTargetLower = WRITE_TARGET.toLowerCase();
    if (ownerAddr.toLowerCase() !== writeTargetLower) {
      throw new Error(
        `KEEPER_WRITE_TARGET ${WRITE_TARGET} is not vault owner ${ownerAddr}.`,
      );
    }

    const [controllerVault, keeperAllowed] = await Promise.all([
      publicClient.readContract({
        address: WRITE_TARGET,
        abi: controllerGuardAbi,
        functionName: 'vault',
      }),
      publicClient.readContract({
        address: WRITE_TARGET,
        abi: controllerGuardAbi,
        functionName: 'reserveKeepers',
        args: [account.address],
      }),
    ]);

    if (controllerVault.toLowerCase() !== VAULT.toLowerCase()) {
      throw new Error(
        `KEEPER_WRITE_TARGET ${WRITE_TARGET} controls vault ${controllerVault}, not env VAULT ${VAULT}.`,
      );
    }
    if (!keeperAllowed) {
      throw new Error(
        `Keeper key ${account.address} is not allowlisted in controller.reserveKeepers.`,
      );
    }
  } else if (ownerAddr.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(
      `Keeper key ${account.address} is not vault owner ${ownerAddr}. ` +
        `Set KEEPER_WRITE_TARGET to the controller when the vault is controller-owned.`,
    );
  }

  metrics.lastVaultStatus = Number(vaultStatus);

  if (vaultStatus === VAULT_STATUS_PAUSED) {
    console.log('Vault is PAUSED. Skipping.');
    await alert('vault-paused', `Vault ${VAULT} is PAUSED.`, 'warn');
    return;
  }
  if (vaultStatus === VAULT_STATUS_UNCONFIGURED) {
    console.log('Vault is UNCONFIGURED. Skipping.');
    await alert('vault-unconfigured', `Vault ${VAULT} is UNCONFIGURED.`, 'warn');
    return;
  }

  const idleAsset = await publicClient.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [VAULT],
  });

  const health = await publicClient.readContract({
    address: HOOK,
    abi: hookAbi,
    functionName: 'getOfferHealth',
    args: [poolKey, VAULT],
  });

  const [
    active,
    driftBps,
    escrow0,
    escrow1,
    proceeds0,
    proceeds1,
    currentVaultSqrt,
    poolSqrt,
  ] = health;

  const failedAsset = await publicClient.readContract({
    address: HOOK,
    abi: hookAbi,
    functionName: 'failedDistribution',
    args: [asset],
  });

  console.log({
    keeper: account.address,
    writeTarget: WRITE_TARGET,
    controllerMode: CONTROLLER_MODE,
    asset,
    idleAsset: idleAsset.toString(),
    active,
    driftBps: driftBps.toString(),
    escrow0: escrow0.toString(),
    escrow1: escrow1.toString(),
    proceeds0: proceeds0.toString(),
    proceeds1: proceeds1.toString(),
    currentVaultSqrt: currentVaultSqrt.toString(),
    poolSqrt: poolSqrt.toString(),
    failedAsset: failedAsset.toString(),
    vaultStatus,
  });

  // Update gauges before any return path so /metrics reflects the latest tick.
  metrics.lastTickAtSec = Math.floor(Date.now() / 1000);
  metrics.lastIdleAsset = idleAsset;
  metrics.lastDriftBps = driftBps;
  metrics.lastFailedAsset = failedAsset;
  metrics.lastOfferActive = active ? 1 : 0;

  if (failedAsset > 0n) {
    console.warn(
      `ALERT: failedDistribution[${asset}] = ${failedAsset}. Owner must call ` +
        `acknowledgeFailedDistribution(...) on the hook after off-chain settlement.`,
    );
    await alert(
      'failed-distribution',
      `failedDistribution[${asset}]=${failedAsset} on hook ${HOOK}. Owner must acknowledgeFailedDistribution.`,
      'error',
    );
  }

  if (poolSqrt === 0n) {
    console.warn('Pool sqrt is zero; pool uninitialized. Skipping.');
    return;
  }

  if (idleAsset < MIN_SELL_AMOUNT) {
    console.log('Idle asset below minimum sell amount. Skipping.');
    return;
  }

  const sellAmount = capOfferAmount(idleAsset);

  if (sellAmount < MIN_SELL_AMOUNT) {
    console.log('Capped sell amount below minimum. Skipping.');
    return;
  }

  // Pick spread direction based on which side of the pool `asset` is on.
  const sellingCurrency1 = assetLower === c1Lower;
  const vaultSqrtPriceX96 = sellingCurrency1
    ? vaultSpreadSqrtForSellingCurrency1(poolSqrt, SPREAD_BPS)
    : vaultSpreadSqrtForSellingCurrency0(poolSqrt, SPREAD_BPS);

  const expiry = BigInt(Math.floor(Date.now() / 1000)) + OFFER_TTL_SECONDS;

  const args = [
    asset,
    sellAmount,
    vaultSqrtPriceX96,
    expiry,
    VAULT_SPREAD_MODE,
  ] as const;

  // ── Expired-offer detection ─────────────────────────────────────
  // The hook's `_tryFillReserve` only no-ops past expiry — it does NOT
  // clear `offers[pid].active`. So `getOfferHealth.active` (which is
  // the raw storage flag) can be true for an offer that is no longer
  // fillable. If we tried to post a fresh offer in that state,
  // `createReserveOfferWithMode` would revert with OfferAlreadyActive.
  // Use the rebalance path, which atomically cancels-then-posts.
  let onchainExpired = false;
  if (active) {
    const onchainOffer = await publicClient.readContract({
      address: HOOK,
      abi: hookAbi,
      functionName: 'getOffer',
      args: [poolKey],
    });
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    // Match the hook's own check (`block.timestamp > o.expiry`) exactly,
    // so we don't rebalance one second before the hook would consider the
    // offer expired.
    if (onchainOffer.expiry !== 0n && nowSec > onchainOffer.expiry) {
      onchainExpired = true;
      console.log(
        `Active offer storage-flag is true but expired at ${onchainOffer.expiry} (now ${nowSec}). Rebalancing.`,
      );
    }
  }

  if (!active) {
    await sendOrPrint('post VAULT_SPREAD reserve offer', 'offerReserveToHookWithMode', args);
    return;
  }

  if (onchainExpired) {
    await sendOrPrint('rebalance expired VAULT_SPREAD reserve offer', 'rebalanceOfferWithMode', args);
    return;
  }

  if (abs(driftBps) >= REBALANCE_DRIFT_BPS) {
    await sendOrPrint('rebalance stale VAULT_SPREAD reserve offer', 'rebalanceOfferWithMode', args);
    return;
  }

  metrics.noops += 1;
  console.log('Active offer healthy. No action.');
}

async function safeTick() {
  metrics.ticks += 1;
  try {
    await tick();
  } catch (err) {
    metrics.errors += 1;
    console.error('Keeper tick failed:', err);
    const msg = err instanceof Error ? err.message : String(err);
    await alert('tick-error', `Tick failed: ${msg}`, 'error');
  } finally {
    logMetrics();
  }
}

async function main() {
  const metricsServer = await startMetricsServer();
  await safeTick();

  if (process.env.LOOP !== 'true') {
    await closeMetricsServer(metricsServer);
    return;
  }

  // Loop with jittered interval. Avoids predictable, gameable timing.
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const jitter = JITTER_MS > 0 ? Math.floor(Math.random() * JITTER_MS) : 0;
    await sleep(INTERVAL_MS + jitter);
    await safeTick();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
