'use client';

/**
 * OwnerPanel — owner-only reserve-desk control surface.
 *
 * Renders ONLY when the connected wallet equals `vault.owner()`. Anyone else
 * sees nothing. Exposes the three on-chain operations the owner currently runs
 * via `cast`:
 *
 *   • Post / refresh offer (rebalanceOfferWithMode)   — atomic cancel+claim+post
 *   • Cancel active offer  (cancelReserveOffer)
 *   • Collect proceeds      (collectReserveProceeds)
 *
 * UX niceties:
 *   - "Suggest price" button reads the live pool sqrtPriceX96 from the hook's
 *     getOfferHealth view and applies a user-chosen spread in bps (default 25)
 *     in the right direction for the chosen sell currency. No manual sqrt math.
 *   - Explicit pre-flight readout of pool spot vs vault price + drift.
 *   - Tx state banners + Arbiscan link on confirmation.
 *
 * Security:
 *   - Hard gate on owner check (read straight from chain, refetched).
 *   - All writes go through wagmi's `useWriteContract`; signature happens in
 *     the connected wallet (Ledger via WalletConnect, MetaMask, etc.).
 */

import { useEffect, useMemo, useState } from 'react';
import {
  useAccount,
  useChainId,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import {
  parseUnits,
  isAddress,
  type Address,
  type Hex,
} from 'viem';
import { erc20Abi, vaultAbi, hookAbi } from '@/lib/abis';
import {
  fmtBps,
  fmtPrice,
  fmtUnits,
  shortAddress,
  sqrtPriceX96ToPrice,
} from '@/lib/format';
import type { Deployment } from '@/lib/deployments';

interface Props {
  deployment: Deployment;
  chainId: number;
  explorerBase: string;
}

type Mode = 0 | 1; // PRICE_IMPROVEMENT | VAULT_SPREAD
type Side = 'sell0' | 'sell1';

const MODE_OPTIONS: { value: Mode; label: string; hint: string }[] = [
  {
    value: 1,
    label: 'Vault spread',
    hint: 'Sell at fixed price. Fills only when AMM spot is at-or-better than your quote — captures spread.',
  },
  {
    value: 0,
    label: 'Price improvement',
    hint: 'Permissive gate: any swap that pushes through your price triggers a fill.',
  },
];

const SPREAD_PRESETS_BPS = [10, 25, 50, 100];
const DEFAULT_SPREAD_BPS = 25;
const DEFAULT_EXPIRY_MIN = 30;

const Q96 = 2n ** 96n;

/**
 * Apply a spread in bps to a sqrtPriceX96.
 *
 * `direction` indicates the sign:
 *   - 'down' returns sqrtP * (10000 - bps) / 10000 (vault accepts a worse price)
 *   - 'up'   returns sqrtP * (10000 + bps) / 10000 (vault demands a better price)
 *
 * Note: in sqrt-space, `bps` here is the half-spread on price — applying it
 * once to sqrt is a first-order approximation. For the small spreads used by
 * the desk (≤100 bps) this matches the cast playbook the user has been
 * running and is well within tick precision.
 */
function applySqrtSpread(
  sqrtP: bigint,
  bps: number,
  direction: 'up' | 'down',
): bigint {
  const num =
    direction === 'down' ? BigInt(10_000 - Math.floor(bps)) : BigInt(10_000 + Math.floor(bps));
  return (sqrtP * num) / 10_000n;
}

export function OwnerPanel({ deployment, chainId, explorerBase }: Props) {
  const vault = deployment.vault as Address | undefined;
  const hook = deployment.hook as Address | undefined;
  const enabled = Boolean(vault && hook);

  const { address: wallet, isConnected } = useAccount();
  const connectedChain = useChainId();
  const onCorrectChain = connectedChain === chainId;

  // ── Owner gate ──────────────────────────────────────────────────────────
  const { data: ownerAddr } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'owner',
    chainId,
    query: { enabled, staleTime: 30_000 },
  });

  const isOwner =
    enabled &&
    isConnected &&
    ownerAddr &&
    wallet &&
    (wallet as string).toLowerCase() === (ownerAddr as string).toLowerCase();

  // ── Pool key + token metadata (always read so panel can render preview) ──
  const { data: poolKey } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'poolKey',
    chainId,
    query: { enabled, staleTime: 60_000 },
  });

  const { data: tokenMeta } = useReadContracts({
    allowFailure: true,
    contracts: poolKey
      ? ([
          { address: poolKey.currency0, abi: erc20Abi, functionName: 'decimals', chainId },
          { address: poolKey.currency1, abi: erc20Abi, functionName: 'decimals', chainId },
          { address: poolKey.currency0, abi: erc20Abi, functionName: 'symbol', chainId },
          { address: poolKey.currency1, abi: erc20Abi, functionName: 'symbol', chainId },
        ] as const)
      : [],
    query: { enabled: Boolean(poolKey), staleTime: 60_000 },
  });

  const decimals0 = (tokenMeta?.[0]?.result as number | undefined) ?? 18;
  const decimals1 = (tokenMeta?.[1]?.result as number | undefined) ?? 6;
  const symbol0 = (tokenMeta?.[2]?.result as string | undefined) ?? 'token0';
  const symbol1 = (tokenMeta?.[3]?.result as string | undefined) ?? 'token1';

  // ── Live offer + health (drives status + suggest-price) ─────────────────
  const { data: hookReads, refetch: refetchHook } = useReadContracts({
    allowFailure: true,
    contracts:
      enabled && poolKey
        ? ([
            { address: hook, abi: hookAbi, functionName: 'getOffer', args: [poolKey], chainId },
            { address: hook, abi: hookAbi, functionName: 'getOfferHealth', args: [poolKey, vault!], chainId },
          ] as const)
        : [],
    query: { enabled: enabled && Boolean(poolKey), refetchInterval: 15_000 },
  });

  const offer = hookReads?.[0]?.result as
    | {
        sellCurrency: Address;
        sellRemaining: bigint;
        vaultSqrtPriceX96: bigint;
        expiry: bigint;
        sellingCurrency1: boolean;
        active: boolean;
        pricingMode: number;
      }
    | undefined;
  const health = hookReads?.[1]?.result as
    | readonly [boolean, bigint, bigint, bigint, bigint, bigint, bigint, bigint]
    | undefined;

  const poolSqrtP = health?.[7];
  const driftBps = health?.[1];
  const proceeds0 = health?.[4];
  const proceeds1 = health?.[5];

  // ── Form state ──────────────────────────────────────────────────────────
  const [side, setSide] = useState<Side>('sell1'); // default to selling token1 (USDC)
  const [mode, setMode] = useState<Mode>(1);
  const [size, setSize] = useState<string>('0.1');
  const [spreadBps, setSpreadBps] = useState<number>(DEFAULT_SPREAD_BPS);
  const [expiryMin, setExpiryMin] = useState<number>(DEFAULT_EXPIRY_MIN);
  const [vaultSqrtStr, setVaultSqrtStr] = useState<string>('');

  // Set sensible default side once token symbols are known: prefer selling the
  // token that the swap panel typically buys (token1 in USDC/WETH layouts).
  useEffect(() => {
    if (offer?.active) {
      setSide(offer.sellingCurrency1 ? 'sell1' : 'sell0');
      setMode(offer.pricingMode === 0 || offer.pricingMode === 1 ? (offer.pricingMode as Mode) : 1);
    }
  }, [offer?.active, offer?.sellingCurrency1, offer?.pricingMode]);

  const sellCurrency: Address | undefined =
    poolKey && (side === 'sell1' ? poolKey.currency1 : poolKey.currency0);
  const sellSymbol = side === 'sell1' ? symbol1 : symbol0;
  const sellDecimals = side === 'sell1' ? decimals1 : decimals0;

  const sizeUnits = useMemo(() => {
    if (!size || !Number.isFinite(Number(size))) return undefined;
    try {
      return parseUnits(size as `${number}`, sellDecimals);
    } catch {
      return undefined;
    }
  }, [size, sellDecimals]);

  const vaultSqrt: bigint | undefined = useMemo(() => {
    if (!vaultSqrtStr) return undefined;
    try {
      const v = BigInt(vaultSqrtStr);
      return v > 0n ? v : undefined;
    } catch {
      return undefined;
    }
  }, [vaultSqrtStr]);

  const vaultPrice = useMemo(
    () => sqrtPriceX96ToPrice(vaultSqrt, decimals0, decimals1),
    [vaultSqrt, decimals0, decimals1],
  );
  const poolPrice = useMemo(
    () => sqrtPriceX96ToPrice(poolSqrtP, decimals0, decimals1),
    [poolSqrtP, decimals0, decimals1],
  );

  // ── Suggest price ───────────────────────────────────────────────────────
  // VAULT_SPREAD gate (line ~422 of DynamicFeeHookV2): the vault price must
  // sit on the side of the pool spot that lets the AMM cross it. For an
  // exact-input zeroForOne swap (sell currency1) the gate is
  // `poolSqrt >= vaultSqrt` → vaultSqrt should be slightly BELOW pool.
  // For oneForZero (sell currency0) it's the inverse → ABOVE pool.
  const suggest = () => {
    if (!poolSqrtP) return;
    const direction: 'up' | 'down' = side === 'sell1' ? 'down' : 'up';
    const next = applySqrtSpread(poolSqrtP, spreadBps, direction);
    setVaultSqrtStr(next.toString());
  };

  // ── Writes ──────────────────────────────────────────────────────────────
  const { writeContract, data: txHash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess: isMined } = useWaitForTransactionReceipt({
    hash: txHash,
    chainId,
  });
  // After confirmation, refresh hook reads.
  useEffect(() => {
    if (isMined) {
      refetchHook();
    }
  }, [isMined, refetchHook]);

  const canPost =
    isOwner &&
    onCorrectChain &&
    !!sellCurrency &&
    !!sizeUnits &&
    sizeUnits > 0n &&
    !!vaultSqrt &&
    !isPending &&
    !isMining;

  const expiryUnix = (): bigint => {
    const mins = Math.max(1, Math.floor(expiryMin));
    return BigInt(Math.floor(Date.now() / 1000) + mins * 60);
  };

  const post = () => {
    if (!vault || !sellCurrency || !sizeUnits || !vaultSqrt) return;
    reset();
    writeContract({
      address: vault,
      abi: vaultAbi,
      functionName: 'rebalanceOfferWithMode',
      args: [sellCurrency, sizeUnits, vaultSqrt, expiryUnix(), mode],
      chainId,
    });
  };

  const cancel = () => {
    if (!vault || !sellCurrency) return;
    reset();
    writeContract({
      address: vault,
      abi: vaultAbi,
      functionName: 'cancelReserveOffer',
      args: [sellCurrency],
      chainId,
    });
  };

  const collect = (currency: Address) => {
    if (!vault) return;
    reset();
    writeContract({
      address: vault,
      abi: vaultAbi,
      functionName: 'collectReserveProceeds',
      args: [currency],
      chainId,
    });
  };

  // ── Render gate ─────────────────────────────────────────────────────────
  // Hidden entirely for non-owners. No flicker on initial load: we wait for
  // ownerAddr to resolve before deciding.
  if (!enabled) return null;
  if (!ownerAddr) return null;
  if (!isOwner) return null;

  // ── Render ──────────────────────────────────────────────────────────────
  return (
    <section id="owner" className="mx-auto max-w-6xl px-4 py-12">
      <div className="card border-accent-500/30 bg-gradient-to-br from-accent-500/5 to-iris-500/5 p-6">
        <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="external-badge mb-2">Owner controls</div>
            <h2 className="text-xl font-semibold tracking-tight md:text-2xl">
              Reserve desk · operator panel
            </h2>
            <p className="mt-1 max-w-2xl text-sm text-zinc-400">
              Connected as the vault owner. All writes go straight to{' '}
              <span className="font-mono">{shortAddress(vault)}</span>. Each
              action is signed by your wallet on chain {chainId}.
            </p>
          </div>
          {!onCorrectChain && (
            <div className="rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-xs text-amber-200">
              Switch your wallet to chain {chainId} to send transactions.
            </div>
          )}
        </div>

        {/* Pre-flight: pool vs vault price */}
        <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Offer status" value={offer?.active ? 'Live' : 'None'} tone={offer?.active ? 'ok' : undefined} />
          <Stat
            label="Pool spot"
            value={fmtPrice(poolPrice)}
            sub={`${symbol1} per ${symbol0}`}
          />
          <Stat
            label="Current vault price"
            value={offer?.active ? fmtPrice(sqrtPriceX96ToPrice(offer.vaultSqrtPriceX96, decimals0, decimals1)) : '—'}
            sub={offer?.active ? `${symbol1} per ${symbol0}` : 'no active offer'}
          />
          <Stat
            label="Drift"
            value={offer?.active ? fmtBps(driftBps) : '—'}
            sub="pool − vault"
            tone={
              offer?.active && driftBps !== undefined
                ? Math.abs(Number(driftBps)) > 50
                  ? 'warn'
                  : 'ok'
                : undefined
            }
          />
        </div>

        {/* ── Form: post / refresh ─────────────────────────────────── */}
        <div className="grid gap-6 lg:grid-cols-[1.4fr_1fr]">
          <div className="rounded-xl border border-white/10 bg-black/20 p-5">
            <div className="mb-4 text-sm font-semibold text-zinc-100">Post or refresh offer</div>

            <Label>Side</Label>
            <div className="mb-4 grid grid-cols-2 gap-2">
              <Toggle
                active={side === 'sell1'}
                onClick={() => setSide('sell1')}
                title={`Sell ${symbol1}`}
                sub="zeroForOne fills"
              />
              <Toggle
                active={side === 'sell0'}
                onClick={() => setSide('sell0')}
                title={`Sell ${symbol0}`}
                sub="oneForZero fills"
              />
            </div>

            <Label>Size ({sellSymbol})</Label>
            <input
              className="input mb-4"
              inputMode="decimal"
              placeholder={`e.g. 0.1 ${sellSymbol}`}
              value={size}
              onChange={(e) => setSize(e.target.value)}
            />

            <Label>Pricing mode</Label>
            <div className="mb-4 grid gap-2 md:grid-cols-2">
              {MODE_OPTIONS.map((m) => (
                <button
                  key={m.value}
                  type="button"
                  onClick={() => setMode(m.value)}
                  className={`rounded-xl border px-3 py-2.5 text-left text-sm transition ${
                    mode === m.value
                      ? 'border-accent-500/60 bg-accent-500/10 text-white'
                      : 'border-white/10 bg-white/[0.02] text-zinc-300 hover:border-white/20'
                  }`}
                >
                  <div className="font-semibold">{m.label}</div>
                  <div className="mt-0.5 text-xs text-zinc-500">{m.hint}</div>
                </button>
              ))}
            </div>

            <div className="mb-4 grid gap-3 md:grid-cols-[1fr_auto_auto]">
              <div>
                <Label>Vault sqrtPriceX96</Label>
                <input
                  className="input"
                  inputMode="numeric"
                  placeholder="suggest from pool spot →"
                  value={vaultSqrtStr}
                  onChange={(e) => setVaultSqrtStr(e.target.value.replace(/\s/g, ''))}
                />
                <div className="mt-1 text-xs text-zinc-500">
                  {vaultPrice && Number.isFinite(vaultPrice)
                    ? `≈ ${fmtPrice(vaultPrice)} ${symbol1} / ${symbol0}`
                    : 'enter raw uint160 or click Suggest'}
                </div>
              </div>
              <div>
                <Label>Spread</Label>
                <select
                  className="input"
                  value={spreadBps}
                  onChange={(e) => setSpreadBps(Number(e.target.value))}
                >
                  {SPREAD_PRESETS_BPS.map((b) => (
                    <option key={b} value={b}>
                      {b} bps
                    </option>
                  ))}
                </select>
              </div>
              <div className="self-end">
                <button
                  type="button"
                  className="btn-ghost h-[42px]"
                  onClick={suggest}
                  disabled={!poolSqrtP}
                  title="Compute vaultSqrtPriceX96 from current pool spot ± spread"
                >
                  Suggest
                </button>
              </div>
            </div>

            <Label>Expires in (minutes)</Label>
            <div className="mb-5 grid grid-cols-[1fr_auto] gap-2">
              <input
                className="input"
                type="number"
                min={1}
                value={expiryMin}
                onChange={(e) => setExpiryMin(Number(e.target.value))}
              />
              <div className="flex items-center gap-1">
                {[10, 30, 60, 360].map((n) => (
                  <button
                    key={n}
                    type="button"
                    className={`rounded-lg border px-2.5 py-1.5 text-xs transition ${
                      expiryMin === n
                        ? 'border-accent-500/60 bg-accent-500/10 text-white'
                        : 'border-white/10 bg-white/[0.02] text-zinc-300 hover:border-white/20'
                    }`}
                    onClick={() => setExpiryMin(n)}
                  >
                    {n < 60 ? `${n}m` : `${n / 60}h`}
                  </button>
                ))}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-3">
              <button
                type="button"
                className="btn-primary"
                disabled={!canPost}
                onClick={post}
              >
                {isPending
                  ? 'Confirm in wallet…'
                  : isMining
                  ? 'Mining…'
                  : offer?.active
                  ? 'Refresh offer'
                  : 'Post offer'}
              </button>
              <button
                type="button"
                className="btn-ghost"
                onClick={cancel}
                disabled={!offer?.active || isPending || isMining || !onCorrectChain}
              >
                Cancel active offer
              </button>
            </div>

            {writeError && (
              <p className="mt-3 break-all text-xs text-amber-300">
                {(writeError as Error).message}
              </p>
            )}
            {txHash && (
              <p className="mt-3 text-xs text-zinc-400">
                Tx{' '}
                <a
                  className="font-mono text-accent-400 hover:underline"
                  href={`${explorerBase}/tx/${txHash}`}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  {shortAddress(txHash as Hex)}
                </a>{' '}
                {isMining ? '· mining' : isMined ? '· confirmed' : '· submitted'}
              </p>
            )}
          </div>

          {/* ── Right column: proceeds + summary ─────────────────────── */}
          <div className="space-y-4">
            <div className="rounded-xl border border-white/10 bg-black/20 p-5">
              <div className="text-sm font-semibold text-zinc-100">Unclaimed proceeds</div>
              <div className="mt-1 text-xs text-zinc-500">
                Buy-side tokens sitting in the hook from past fills. Pull them
                back into the vault.
              </div>
              <div className="mt-4 space-y-3">
                <ProceedsRow
                  label={symbol0}
                  amount={proceeds0}
                  decimals={decimals0}
                  onClick={() => poolKey && collect(poolKey.currency0)}
                  disabled={!poolKey || (proceeds0 ?? 0n) === 0n || isPending || isMining || !onCorrectChain}
                />
                <ProceedsRow
                  label={symbol1}
                  amount={proceeds1}
                  decimals={decimals1}
                  onClick={() => poolKey && collect(poolKey.currency1)}
                  disabled={!poolKey || (proceeds1 ?? 0n) === 0n || isPending || isMining || !onCorrectChain}
                />
              </div>
            </div>

            <div className="rounded-xl border border-white/10 bg-black/20 p-5 text-xs text-zinc-400">
              <div className="mb-1 font-semibold text-zinc-100">How this works</div>
              <p>
                Posting writes <span className="font-mono">rebalanceOfferWithMode</span>{' '}
                on the vault. Existing offers are cancelled, both proceeds
                claimed, and a fresh offer posted in one transaction. Anyone
                swapping through the pool fills the offer automatically — no
                taker-side action.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// ── Sub-components ───────────────────────────────────────────────────────

function Label({ children }: { children: React.ReactNode }) {
  return <div className="stat-label mb-1.5">{children}</div>;
}

function Stat({
  label,
  value,
  sub,
  tone,
}: {
  label: string;
  value: string;
  sub?: string;
  tone?: 'ok' | 'warn';
}) {
  const valueClass =
    tone === 'warn' ? 'text-amber-300' : tone === 'ok' ? 'text-emerald-300' : 'text-white';
  return (
    <div className="rounded-xl border border-white/10 bg-black/20 px-4 py-3">
      <div className="stat-label">{label}</div>
      <div className={`mt-1 font-mono text-base font-semibold ${valueClass}`}>{value}</div>
      {sub && <div className="mt-0.5 text-[11px] text-zinc-500">{sub}</div>}
    </div>
  );
}

function Toggle({
  active,
  onClick,
  title,
  sub,
}: {
  active: boolean;
  onClick: () => void;
  title: string;
  sub: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`rounded-xl border px-3 py-2.5 text-left text-sm transition ${
        active
          ? 'border-accent-500/60 bg-accent-500/10 text-white'
          : 'border-white/10 bg-white/[0.02] text-zinc-300 hover:border-white/20'
      }`}
    >
      <div className="font-semibold">{title}</div>
      <div className="mt-0.5 text-xs text-zinc-500">{sub}</div>
    </button>
  );
}

function ProceedsRow({
  label,
  amount,
  decimals,
  onClick,
  disabled,
}: {
  label: string;
  amount: bigint | undefined;
  decimals: number;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <div className="flex items-center justify-between rounded-lg border border-white/5 bg-white/[0.02] px-3 py-2.5">
      <div>
        <div className="text-xs text-zinc-400">{label}</div>
        <div className="font-mono text-sm text-white">
          {fmtUnits(amount, decimals, 6)}
        </div>
      </div>
      <button
        type="button"
        className="btn-ghost text-xs"
        onClick={onClick}
        disabled={disabled}
      >
        Collect
      </button>
    </div>
  );
}
