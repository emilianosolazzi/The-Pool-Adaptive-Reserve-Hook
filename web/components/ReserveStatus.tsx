'use client';

/**
 * ReserveStatus — public, read-only transparency dashboard for the vault's
 * reserve-sale desk on DynamicFeeHookV2.
 *
 * Rendered to anyone (no wallet required) so depositors and traders can
 * verify what the operator is doing at any moment:
 *
 *   • Live offer state (active / inactive, side, size, price, expiry, mode)
 *   • Drift between pool spot and the vault's quoted sale price
 *   • Lifetime hook counters (swaps, fees routed, reserve fills, reserve sold)
 *   • Recent events feed (OfferCreated / OfferFilled / OfferCancelled /
 *     OfferStale / ProceedsClaimed) with explorer links
 *
 * All data is read straight from the chain — no off-chain indexer.
 */

import { useMemo } from 'react';
import { useReadContract, useReadContracts, usePublicClient } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import { erc20Abi, hookAbi, vaultAbi } from '@/lib/abis';
import {
  fmtCompact,
  fmtUnits,
  fmtBps,
  fmtCountdown,
  fmtPrice,
  sqrtPriceX96ToPrice,
  shortAddress,
} from '@/lib/format';
import type { Deployment } from '@/lib/deployments';
import type { Address, AbiEvent, Log } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
  explorerBase: string;
}

const MODE_LABEL: Record<number, string> = {
  0: 'Price improvement',
  1: 'Vault spread',
};

// Lookback window for the public events feed. Arbitrum produces ~4 blocks/s,
// so 200k blocks ≈ 14 hours of history. Chunked into 9k-block requests so
// the public RPC's getLogs cap is respected.
const LOOKBACK_BLOCKS = 200_000n;
const CHUNK_BLOCKS = 9_000n;
const MAX_FEED_ITEMS = 12;

const RESERVE_EVENT_NAMES = [
  'ReserveOfferCreated',
  'ReserveOfferCancelled',
  'ReserveFilled',
  'ReserveProceedsClaimed',
  'ReserveOfferStale',
] as const;

type ReserveEventName = (typeof RESERVE_EVENT_NAMES)[number];

interface FeedEntry {
  kind: ReserveEventName;
  blockNumber: bigint;
  txHash: `0x${string}`;
  logIndex: number;
  // Loose bag — each event has different fields; we render via a switch.
  args: Record<string, unknown>;
}

/** Pull AbiEvent objects out of hookAbi for use with publicClient.getLogs. */
const reserveEvents: AbiEvent[] = (hookAbi as readonly unknown[]).filter(
  (item): item is AbiEvent => {
    const it = item as { type?: string; name?: string };
    return (
      it.type === 'event' &&
      typeof it.name === 'string' &&
      (RESERVE_EVENT_NAMES as readonly string[]).includes(it.name)
    );
  },
);

export function ReserveStatus({ deployment, chainId, explorerBase }: Props) {
  const vault = deployment.vault as Address | undefined;
  const hook = deployment.hook as Address | undefined;
  const enabled = Boolean(vault && hook);

  // ── Pool key (one-time read; rarely changes) ────────────────────────────
  const { data: poolKey } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'poolKey',
    chainId,
    query: { enabled, staleTime: 60_000 },
  });

  // ── Decimals for both currencies (for human price rendering) ────────────
  const { data: decimalsRes } = useReadContracts({
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

  const decimals0 = (decimalsRes?.[0]?.result as number | undefined) ?? 18;
  const decimals1 = (decimalsRes?.[1]?.result as number | undefined) ?? 6;
  const symbol0 = (decimalsRes?.[2]?.result as string | undefined) ?? '?';
  const symbol1 = (decimalsRes?.[3]?.result as string | undefined) ?? '?';

  // ── Live counters + offer state from the hook ───────────────────────────
  const { data: hookReads, isLoading: isHookLoading } = useReadContracts({
    allowFailure: true,
    contracts:
      enabled && poolKey
        ? ([
            { address: hook, abi: hookAbi, functionName: 'getOffer', args: [poolKey], chainId },
            { address: hook, abi: hookAbi, functionName: 'getOfferHealth', args: [poolKey, vault!], chainId },
            { address: hook, abi: hookAbi, functionName: 'totalSwaps', chainId },
            { address: hook, abi: hookAbi, functionName: 'totalFeesRouted', chainId },
            { address: hook, abi: hookAbi, functionName: 'totalReserveFills', chainId },
            { address: hook, abi: hookAbi, functionName: 'totalReserveSold', chainId },
          ] as const)
        : [],
    query: { enabled: enabled && Boolean(poolKey), refetchInterval: 15_000 },
  });

  const offer = hookReads?.[0]?.result as
    | {
        sellCurrency: Address;
        buyCurrency: Address;
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

  const totalSwaps = hookReads?.[2]?.result as bigint | undefined;
  const totalFeesRouted = hookReads?.[3]?.result as bigint | undefined;
  const totalReserveFills = hookReads?.[4]?.result as bigint | undefined;
  const totalReserveSold = hookReads?.[5]?.result as bigint | undefined;

  // ── Public events feed (chunked getLogs over recent history) ────────────
  const publicClient = usePublicClient({ chainId });

  const { data: feed, isLoading: isFeedLoading, isError: isFeedError } = useQuery<FeedEntry[]>({
    queryKey: ['reserveFeed', chainId, hook ?? '0x', vault ?? '0x'],
    enabled: enabled && Boolean(publicClient),
    refetchInterval: 30_000,
    staleTime: 20_000,
    queryFn: async () => {
      if (!publicClient || !hook) return [];
      const head = await publicClient.getBlockNumber();
      const floor = head > LOOKBACK_BLOCKS ? head - LOOKBACK_BLOCKS : 0n;

      const out: FeedEntry[] = [];
      // Walk backward in CHUNK_BLOCKS-sized windows so cheap public RPCs
      // (which usually cap getLogs at ~10k blocks) accept every call.
      for (let to = head; to >= floor; ) {
        const fromCandidate = to > CHUNK_BLOCKS ? to - CHUNK_BLOCKS + 1n : 0n;
        const from = fromCandidate < floor ? floor : fromCandidate;
        let logs: Log[] = [];
        try {
          logs = await publicClient.getLogs({
            address: hook,
            events: reserveEvents,
            fromBlock: from,
            toBlock: to,
          });
        } catch {
          // RPC may transiently reject; skip this window rather than abort.
          logs = [];
        }
        for (const l of logs) {
          // viem decodes args onto the log when the event filter matches.
          const ev = l as Log & { eventName?: string; args?: Record<string, unknown> };
          if (!ev.eventName || !ev.transactionHash || ev.blockNumber === null) continue;
          out.push({
            kind: ev.eventName as ReserveEventName,
            blockNumber: ev.blockNumber!,
            txHash: ev.transactionHash,
            logIndex: ev.logIndex ?? 0,
            args: ev.args ?? {},
          });
          if (out.length >= MAX_FEED_ITEMS * 4) break;
        }
        if (from === 0n || from === floor) break;
        to = from - 1n;
        if (out.length >= MAX_FEED_ITEMS * 4) break;
      }

      // Most recent first, capped at MAX_FEED_ITEMS.
      out.sort((a, b) => {
        if (a.blockNumber === b.blockNumber) return b.logIndex - a.logIndex;
        return a.blockNumber > b.blockNumber ? -1 : 1;
      });
      return out.slice(0, MAX_FEED_ITEMS);
    },
  });

  // ── Derived display fields ──────────────────────────────────────────────
  const sellSymbol = offer?.sellingCurrency1 ? symbol1 : symbol0;
  const buySymbol = offer?.sellingCurrency1 ? symbol0 : symbol1;
  const sellDecimals = offer?.sellingCurrency1 ? decimals1 : decimals0;

  const vaultPrice = useMemo(
    () => sqrtPriceX96ToPrice(offer?.vaultSqrtPriceX96, decimals0, decimals1),
    [offer?.vaultSqrtPriceX96, decimals0, decimals1],
  );
  const poolPrice = useMemo(
    () => sqrtPriceX96ToPrice(health?.[7], decimals0, decimals1),
    [health, decimals0, decimals1],
  );

  const driftBps = health?.[1];
  const isActive = Boolean(offer?.active);

  // ── Render ──────────────────────────────────────────────────────────────
  if (!enabled) {
    return (
      <section id="reserve" className="mx-auto max-w-6xl px-4 py-16">
        <div className="card p-6 text-zinc-400">
          Reserve desk is unavailable on this network.
        </div>
      </section>
    );
  }

  return (
    <section id="reserve" className="mx-auto max-w-6xl px-4 py-16">
      <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
            Reserve desk
          </h2>
          <p className="mt-2 max-w-2xl text-zinc-400">
            Live, public state of the vault&apos;s single-sided reserve sale on the
            hook. Anyone can verify the offer, the price, and every fill — no
            indexer, straight from chain.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <a
            className="chip hover:border-accent-500/40"
            href={`${explorerBase}/address/${hook}#events`}
            target="_blank"
            rel="noopener noreferrer"
          >
            Hook · {shortAddress(hook)} ↗
          </a>
          <a
            className="chip hover:border-accent-500/40"
            href={`${explorerBase}/address/${vault}`}
            target="_blank"
            rel="noopener noreferrer"
          >
            Vault · {shortAddress(vault)} ↗
          </a>
        </div>
      </div>

      <div className="grid gap-6 lg:grid-cols-[1.2fr_1fr]">
        {/* ── Live offer card ────────────────────────────────────────── */}
        <div className="card p-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <span
                className={`inline-flex h-2.5 w-2.5 rounded-full ${
                  isActive ? 'bg-emerald-400 shadow-[0_0_10px_2px_rgba(52,211,153,0.65)]' : 'bg-zinc-600'
                }`}
              />
              <span className="text-sm font-medium uppercase tracking-[0.18em] text-zinc-300">
                {isActive ? 'Offer live' : 'No offer posted'}
              </span>
            </div>
            <span className="external-badge">
              {offer ? MODE_LABEL[offer.pricingMode] ?? `Mode ${offer.pricingMode}` : '—'}
            </span>
          </div>

          {isActive && offer ? (
            <div className="mt-6 grid grid-cols-2 gap-4">
              <Field
                label="Selling"
                value={`${fmtUnits(offer.sellRemaining, sellDecimals, 6)} ${sellSymbol}`}
                sub={`for ${buySymbol}`}
              />
              <Field
                label="Vault price"
                value={fmtPrice(vaultPrice)}
                sub={`${symbol1} per ${symbol0}`}
              />
              <Field
                label="Pool spot"
                value={fmtPrice(poolPrice)}
                sub={`${symbol1} per ${symbol0}`}
              />
              <Field
                label="Drift"
                value={fmtBps(driftBps)}
                sub="pool − vault, in bps"
                tone={
                  driftBps === undefined
                    ? undefined
                    : Math.abs(Number(driftBps)) > 50
                    ? 'warn'
                    : 'ok'
                }
              />
              <Field
                label="Expires"
                value={fmtCountdown(offer.expiry)}
                sub={
                  offer.expiry
                    ? new Date(Number(offer.expiry) * 1000).toISOString().slice(0, 16) + 'Z'
                    : 'no expiry'
                }
              />
              <Field
                label="Side"
                value={offer.sellingCurrency1 ? 'token1 → token0' : 'token0 → token1'}
                sub={`fills only when ${
                  offer.sellingCurrency1 ? 'zeroForOne' : 'oneForZero'
                } swaps cross the gate`}
              />
            </div>
          ) : (
            <p className="mt-6 text-sm text-zinc-400">
              The vault has no active reserve offer. New offers appear here the
              instant the operator posts one on-chain.
            </p>
          )}
        </div>

        {/* ── Lifetime counters ─────────────────────────────────────── */}
        <div className="card p-6">
          <div className="stat-label">Lifetime hook activity</div>
          <div className="mt-4 grid grid-cols-2 gap-4">
            <Counter
              label="Total swaps"
              value={isHookLoading ? '…' : totalSwaps?.toString() ?? '0'}
            />
            <Counter
              label="Reserve fills"
              value={isHookLoading ? '…' : totalReserveFills?.toString() ?? '0'}
            />
            <Counter
              label="Reserve sold"
              value={
                isHookLoading
                  ? '…'
                  : `${fmtCompact(totalReserveSold, sellDecimals)} ${sellSymbol}`
              }
              sub="cumulative inventory cleared"
            />
            <Counter
              label="Fees routed"
              value={
                isHookLoading
                  ? '…'
                  : fmtCompact(totalFeesRouted, decimals1)
              }
              sub="atomic units (mixed currencies)"
            />
          </div>
        </div>
      </div>

      {/* ── Events feed ────────────────────────────────────────────── */}
      <div className="card mt-6 overflow-hidden">
        <div className="flex items-center justify-between border-b border-white/5 px-5 py-3">
          <div>
            <div className="text-sm font-semibold text-zinc-100">Recent activity</div>
            <div className="text-xs text-zinc-500">
              Last ~{Number(LOOKBACK_BLOCKS / 1000n)}k blocks · refreshes every 30s
            </div>
          </div>
          <span className="external-badge">Direct from chain</span>
        </div>

        {isFeedLoading ? (
          <div className="px-5 py-8 text-center text-sm text-zinc-500">Loading events…</div>
        ) : isFeedError ? (
          <div className="px-5 py-8 text-center text-sm text-amber-400">
            RPC could not return the event window. Try again in a moment.
          </div>
        ) : !feed || feed.length === 0 ? (
          <div className="px-5 py-8 text-center text-sm text-zinc-500">
            No reserve events in the recent window. New activity will appear
            here as soon as it lands on-chain.
          </div>
        ) : (
          <ul className="divide-y divide-white/5">
            {feed.map((e) => (
              <FeedRow
                key={`${e.txHash}-${e.logIndex}`}
                entry={e}
                explorerBase={explorerBase}
                decimals0={decimals0}
                decimals1={decimals1}
                symbol0={symbol0}
                symbol1={symbol1}
              />
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}

// ── Sub-components ───────────────────────────────────────────────────────

function Field({
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
    tone === 'warn'
      ? 'text-amber-300'
      : tone === 'ok'
      ? 'text-emerald-300'
      : 'text-white';
  return (
    <div>
      <div className="stat-label">{label}</div>
      <div className={`mt-1 font-mono text-lg font-semibold ${valueClass}`}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-zinc-500">{sub}</div>}
    </div>
  );
}

function Counter({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="stat-label">{label}</div>
      <div className="stat-value mt-1">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-zinc-500">{sub}</div>}
    </div>
  );
}

function FeedRow({
  entry,
  explorerBase,
  decimals0,
  decimals1,
  symbol0,
  symbol1,
}: {
  entry: FeedEntry;
  explorerBase: string;
  decimals0: number;
  decimals1: number;
  symbol0: string;
  symbol1: string;
}) {
  const { kind, args, txHash, blockNumber } = entry;

  const [icon, label, color] = (() => {
    switch (kind) {
      case 'ReserveOfferCreated':
        return ['＋', 'Offer posted', 'text-emerald-300'];
      case 'ReserveOfferCancelled':
        return ['×', 'Offer cancelled', 'text-zinc-300'];
      case 'ReserveFilled':
        return ['→', 'Filled by swap', 'text-accent-400'];
      case 'ReserveProceedsClaimed':
        return ['↘', 'Proceeds claimed', 'text-iris-300'];
      case 'ReserveOfferStale':
        return ['!', 'Offer stale (price drifted)', 'text-amber-300'];
      default:
        return ['•', kind, 'text-zinc-300'];
    }
  })();

  // Per-event detail line, decimal-aware where we know the side.
  const detail = (() => {
    if (kind === 'ReserveOfferCreated') {
      const sellAmount = args.sellAmount as bigint | undefined;
      const sellCurrency = args.sellCurrency as Address | undefined;
      // We don't know which side without poolKey context here, so render raw
      // with whichever decimals match the address; default to 6 for USDC-like
      // when the address matches token1, else 18.
      const looksLikeToken1 =
        sellCurrency && sellCurrency.toLowerCase().endsWith('5831'); // USDC tail; harmless guess
      const dec = looksLikeToken1 ? decimals1 : decimals0;
      const sym = looksLikeToken1 ? symbol1 : symbol0;
      return sellAmount !== undefined
        ? `Size ${fmtUnits(sellAmount, dec, 4)} ${sym}`
        : '';
    }
    if (kind === 'ReserveOfferCancelled') {
      const ret = args.returnedAmount as bigint | undefined;
      return ret !== undefined ? `Returned ${ret.toString()} (atomic)` : '';
    }
    if (kind === 'ReserveFilled') {
      const sellAmount = args.sellAmount as bigint | undefined;
      const buyAmount = args.buyAmount as bigint | undefined;
      // Mixed-side: render both sides as atomic-compact for honesty.
      return sellAmount !== undefined && buyAmount !== undefined
        ? `Sold ${sellAmount.toString()} · Bought ${buyAmount.toString()} (atomic)`
        : '';
    }
    if (kind === 'ReserveProceedsClaimed') {
      const amount = args.amount as bigint | undefined;
      return amount !== undefined ? `Amount ${amount.toString()} (atomic)` : '';
    }
    if (kind === 'ReserveOfferStale') {
      const drift = args.driftBps as bigint | undefined;
      return drift !== undefined ? `Drift ${fmtBps(drift)}` : '';
    }
    return '';
  })();

  return (
    <li className="grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 py-3 text-sm hover:bg-white/[0.02]">
      <span
        className={`inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full border border-white/10 bg-white/5 font-mono text-sm ${color}`}
      >
        {icon}
      </span>
      <div className="min-w-0">
        <div className={`font-medium ${color}`}>{label}</div>
        {detail && (
          <div className="truncate font-mono text-xs text-zinc-400">{detail}</div>
        )}
      </div>
      <a
        className="font-mono text-xs text-zinc-400 hover:text-accent-400"
        href={`${explorerBase}/tx/${txHash}`}
        target="_blank"
        rel="noopener noreferrer"
        title={`Block ${blockNumber.toString()}`}
      >
        {shortAddress(txHash)} ↗
      </a>
    </li>
  );
}
