'use client';

import { useMemo } from 'react';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { erc20Abi, bootstrapAbi } from '@/lib/abis';
import { fmtCompact, fmtUnits, shortAddress } from '@/lib/format';
import type { Deployment } from '@/lib/deployments';
import type { Address } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
  explorerBase: string;
}

const formatTimestamp = (ts: bigint | undefined): string => {
  if (!ts) return '—';
  const ms = Number(ts) * 1000;
  if (!Number.isFinite(ms)) return '—';
  return new Date(ms).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
};

const formatCountdown = (target: bigint | undefined): string => {
  if (!target) return '—';
  const now = Math.floor(Date.now() / 1000);
  const delta = Number(target) - now;
  if (delta <= 0) return 'now';
  const d = Math.floor(delta / 86_400);
  const h = Math.floor((delta % 86_400) / 3_600);
  if (d > 0) return `in ${d}d ${h}h`;
  const m = Math.floor((delta % 3_600) / 60);
  return `in ${h}h ${m}m`;
};

/**
 * BootstrapPanel — surfaces the BootstrapRewards epoch-0 bonus pool sitting
 * on-chain so visitors can verify the reward claim is real, not vapor.
 *
 * Reads (from BootstrapRewards on Arbitrum One):
 *   - payoutAsset (USDC), realTreasury
 *   - programStart, epochLength, epochCount, bonusShareBps
 *   - currentEpoch(), epochBounds(0)
 *   - epochs(0)        -> (bonusPool, claimedAmount, totalShareSeconds, swept)
 *   - payoutAsset.balanceOf(bootstrap)   -> total USDC held by the contract
 *   - eligibleSharesOf(connectedWallet)  -> per-user view if connected
 *
 * Hard truths displayed:
 *   - bonusPool already on-chain (epoch 0)
 *   - total contract USDC (often > bonusPool, since pullInflow() must run
 *     to assign untracked balance to the active epoch)
 *   - epoch window timestamps
 */
export function BootstrapPanel({ deployment, chainId, explorerBase }: Props) {
  const bootstrap = deployment.bootstrap as Address | undefined;
  const enabled = Boolean(bootstrap);
  const { address: account } = useAccount();

  const { data: schedule } = useReadContracts({
    allowFailure: true,
    contracts: enabled
      ? ([
          { address: bootstrap, abi: bootstrapAbi, functionName: 'payoutAsset', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'realTreasury', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'programStart', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'epochLength', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'epochCount', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'bonusShareBps', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'perEpochCap', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'currentEpoch', chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'epochBounds', args: [0n], chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'epochs', args: [0n], chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'isEpochFinalized', args: [0n], chainId },
          { address: bootstrap, abi: bootstrapAbi, functionName: 'isClaimWindowOpen', args: [0n], chainId },
        ] as const)
      : [],
    query: { enabled, refetchInterval: 20_000 },
  });

  const payoutAsset = schedule?.[0]?.result as Address | undefined;
  const realTreasury = schedule?.[1]?.result as Address | undefined;
  const programStart = schedule?.[2]?.result as bigint | undefined;
  const epochLength = schedule?.[3]?.result as bigint | undefined;
  const epochCount = schedule?.[4]?.result as number | undefined;
  const bonusShareBps = schedule?.[5]?.result as number | undefined;
  const perEpochCap = schedule?.[6]?.result as bigint | undefined;
  const currentEpoch = schedule?.[7]?.result as bigint | undefined;
  const epoch0Bounds = schedule?.[8]?.result as readonly [bigint, bigint] | undefined;
  const epoch0 = schedule?.[9]?.result as
    | readonly [bigint, bigint, bigint, boolean]
    | undefined;
  const epoch0Finalized = schedule?.[10]?.result as boolean | undefined;
  const epoch0ClaimOpen = schedule?.[11]?.result as boolean | undefined;

  // Tracked balance on the contract (often > bonusPool until pullInflow runs)
  const { data: contractBalance } = useReadContract({
    address: payoutAsset,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: bootstrap ? [bootstrap] : undefined,
    chainId,
    query: { enabled: Boolean(bootstrap && payoutAsset), refetchInterval: 20_000 },
  });

  // Per-user eligibility (only when connected)
  const { data: userEligibleShares } = useReadContract({
    address: bootstrap,
    abi: bootstrapAbi,
    functionName: 'eligibleSharesOf',
    args: account ? [account] : undefined,
    chainId,
    query: { enabled: Boolean(bootstrap && account), refetchInterval: 20_000 },
  });

  const bonusPool = epoch0?.[0];
  const claimedAmount = epoch0?.[1];
  const totalShareSeconds = epoch0?.[2];
  const swept = epoch0?.[3];

  const epochState = useMemo(() => {
    if (currentEpoch === undefined || epochCount === undefined) return '—';
    if (currentEpoch === BigInt(2) ** BigInt(256) - BigInt(1)) {
      return programStart && Number(programStart) * 1_000 > Date.now()
        ? 'pre-program'
        : 'program ended';
    }
    return `epoch ${currentEpoch.toString()} / ${epochCount}`;
  }, [currentEpoch, epochCount, programStart]);

  const epoch0Status = useMemo(() => {
    if (swept) return 'swept';
    if (epoch0ClaimOpen) return 'claim window open';
    if (epoch0Finalized) return 'claim window closed';
    return 'accruing';
  }, [swept, epoch0Finalized, epoch0ClaimOpen]);

  if (!bootstrap) return null;

  const dec = deployment.assetDecimals;
  const sym = deployment.assetSymbol;

  const explorerLink = (a?: string, label?: string) =>
    a ? (
      <a
        href={`${explorerBase}/address/${a}`}
        target="_blank"
        rel="noopener noreferrer"
        className="font-mono text-accent-400 hover:underline"
      >
        {label ?? shortAddress(a)}
      </a>
    ) : (
      <span className="font-mono text-zinc-600">—</span>
    );

  return (
    <section className="mx-auto max-w-6xl px-4 py-12">
      <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="mb-2 flex items-center gap-2">
            <span className="chip">
              <span className="h-1.5 w-1.5 rounded-full bg-accent-400 shadow-[0_0_10px_rgba(255,92,184,0.8)]" />
              Bootstrap pool · live on-chain
            </span>
          </div>
          <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
            Real {sym} sitting in epoch 0
          </h2>
          <p className="mt-2 max-w-2xl text-sm text-zinc-400">
            Verify these numbers yourself. Every value below is read live from{' '}
            {explorerLink(bootstrap, 'BootstrapRewards')} and{' '}
            {explorerLink(payoutAsset, sym)} on Arbitrum One.
          </p>
        </div>
        <span className="chip">{epochState}</span>
      </div>

      <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-4">
        <div className="card p-4">
          <div className="stat-label">Epoch 0 bonus pool</div>
          <div className="stat-value mt-1">
            {bonusPool !== undefined ? `${fmtUnits(bonusPool, dec, 2)} ${sym}` : '—'}
          </div>
          <div className="mt-1 text-xs text-zinc-500">
            Fills as hook fees accumulate from swaps
          </div>
        </div>

        <div className="card p-4">
          <div className="stat-label">Claimed so far</div>
          <div className="stat-value mt-1">
            {claimedAmount !== undefined ? `${fmtUnits(claimedAmount, dec, 2)} ${sym}` : '—'}
          </div>
          <div className="mt-1 text-xs text-zinc-500">
            Cumulative claims by eligible LPs
          </div>
        </div>

        <div className="card p-4">
          <div className="stat-label">Contract balance</div>
          <div className="stat-value mt-1">
            {contractBalance !== undefined
              ? `${fmtUnits(contractBalance, dec, 2)} ${sym}`
              : '—'}
          </div>
          <div className="mt-1 text-xs text-zinc-500">
            Total {sym} held by BootstrapRewards
          </div>
        </div>

        <div className="card p-4">
          <div className="stat-label">Per-epoch cap</div>
          <div className="stat-value mt-1">
            {perEpochCap !== undefined ? `${fmtCompact(perEpochCap, dec)} ${sym}` : '—'}
          </div>
          <div className="mt-1 text-xs text-zinc-500">
            Hard ceiling on epoch bonus pool
          </div>
        </div>
      </div>

      <div className="mt-4 grid gap-3 md:grid-cols-2">
        <div className="card p-4">
          <div className="stat-label">Epoch 0 window</div>
          <div className="mt-2 space-y-1 text-sm text-zinc-300">
            <div className="flex justify-between">
              <span className="text-zinc-500">Start</span>
              <span className="font-mono">{formatTimestamp(epoch0Bounds?.[0])}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-zinc-500">End</span>
              <span className="font-mono">{formatTimestamp(epoch0Bounds?.[1])}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-zinc-500">End in</span>
              <span className="font-mono text-zinc-200">
                {formatCountdown(epoch0Bounds?.[1])}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-zinc-500">Status</span>
              <span className="font-mono text-zinc-200">{epoch0Status}</span>
            </div>
          </div>
        </div>

        <div className="card p-4">
          <div className="stat-label">Program parameters</div>
          <div className="mt-2 space-y-1 text-sm text-zinc-300">
            <div className="flex justify-between">
              <span className="text-zinc-500">Bonus share of treasury</span>
              <span className="font-mono">
                {bonusShareBps !== undefined
                  ? `${(bonusShareBps / 100).toFixed(2)}%`
                  : '—'}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-zinc-500">Epoch length</span>
              <span className="font-mono">
                {epochLength
                  ? `${(Number(epochLength) / 86_400).toFixed(0)} days`
                  : '—'}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-zinc-500">Total epochs</span>
              <span className="font-mono">{epochCount ?? '—'}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-zinc-500">Real treasury</span>
              <span>{explorerLink(realTreasury)}</span>
            </div>
          </div>
        </div>
      </div>

      <div className="mt-4 grid gap-3 md:grid-cols-2">
        <div className="card p-4 text-sm leading-relaxed text-zinc-400">
          <div className="text-white font-semibold">Why this is real</div>
          <p className="mt-2">
            Click{' '}
            <a
              href={`${explorerBase}/address/${bootstrap}#readContract`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-accent-400 hover:underline"
            >
              Read Contract on Arbiscan
            </a>{' '}
            and call <code className="rounded bg-white/5 px-1 font-mono">epochs(0)</code>.
            The first return value is{' '}
            <code className="rounded bg-white/5 px-1 font-mono">bonusPool</code> in{' '}
            {sym} units (×10<sup>{dec}</sup>). It will match the value above. Anyone can
            also call{' '}
            <code className="rounded bg-white/5 px-1 font-mono">payoutAsset.balanceOf(bootstrap)</code>{' '}
            and confirm the {sym} actually sits in the contract — not in a treasury
            wallet.
          </p>
          <p className="mt-3">
            <span className="text-white">Untracked balance.</span> If contract balance{' '}
            {`>`} bonus pool, anyone may call{' '}
            <code className="rounded bg-white/5 px-1 font-mono">pullInflow()</code> on
            BootstrapRewards to commit the residual into the active epoch&apos;s bonus pool.
            Permissionless, idempotent.
          </p>
        </div>

        <div className="card p-4 text-sm leading-relaxed text-zinc-400">
          <div className="text-white font-semibold">Your eligibility</div>
          {account ? (
            <>
              <p className="mt-2">
                <span className="text-zinc-500">Wallet</span>{' '}
                <span className="font-mono text-zinc-200">{shortAddress(account)}</span>
              </p>
              <p className="mt-1">
                <span className="text-zinc-500">Eligible shares right now</span>{' '}
                <span className="font-mono text-zinc-200">
                  {userEligibleShares !== undefined
                    ? fmtUnits(userEligibleShares, 18, 4)
                    : '—'}
                </span>
              </p>
              <p className="mt-3 text-xs text-zinc-500">
                Eligible shares = your vault share balance, capped per-wallet. Bonus
                accrual requires holding shares through the epoch dwell period; transfers
                can reset/disrupt accrual and may forfeit pending bonus.
              </p>
            </>
          ) : (
            <p className="mt-2 text-zinc-500">
              Connect a wallet to preview your bonus eligibility.
            </p>
          )}
          {totalShareSeconds !== undefined ? (
            <p className="mt-3 text-xs text-zinc-500">
              Epoch 0 totalShareSeconds: <span className="font-mono">{totalShareSeconds.toString()}</span>
            </p>
          ) : null}
        </div>
      </div>
    </section>
  );
}
