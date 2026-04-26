'use client';

import { useMemo } from 'react';
import { useReadContract } from 'wagmi';
import { vaultAbi } from '@/lib/abis';
import { fmtCompact, fmtUnits } from '@/lib/format';
import { type Deployment } from '@/lib/deployments';
import type { Address } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
}

export function StatsGrid({ deployment, chainId }: Props) {
  const vault = deployment.vault as Address | undefined;
  const enabled = Boolean(vault);

  const {
    data: rawStats,
    isLoading: isStatsLoading,
    isError: isStatsError,
    error: statsError,
  } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'getVaultStats',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const { data: tickLower, isLoading: isTickLowerLoading } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'tickLower',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const { data: tickUpper, isLoading: isTickUpperLoading } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'tickUpper',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const { data: perfBps, isLoading: isPerfLoading } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'performanceFeeBps',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const stats = useMemo(() => {
    if (!rawStats) return undefined;

    if (Array.isArray(rawStats) && rawStats.length >= 6) {
      return rawStats as readonly [bigint, bigint, bigint, bigint, bigint, string];
    }

    const obj = rawStats as unknown as Partial<Record<string, unknown>>;
    if (
      typeof obj.tvl === 'bigint' &&
      typeof obj.sharePrice === 'bigint' &&
      typeof obj.depositors === 'bigint' &&
      typeof obj.liqDeployed === 'bigint' &&
      typeof obj.yieldColl === 'bigint' &&
      typeof obj.feeDesc === 'string'
    ) {
      return [
        obj.tvl,
        obj.sharePrice,
        obj.depositors,
        obj.liqDeployed,
        obj.yieldColl,
        obj.feeDesc,
      ] as const;
    }

    return undefined;
  }, [rawStats]);

  const isLoading = isStatsLoading || isTickLowerLoading || isTickUpperLoading || isPerfLoading;

  const cards = [
    {
      label: 'TVL',
      value: vault
        ? `${fmtCompact(stats?.[0], deployment.assetDecimals)} ${deployment.assetSymbol}`
        : 'Not deployed',
      sub: vault ? 'Total assets under management' : 'Vault address not set',
    },
    {
      label: 'Share price',
      value: stats ? `${fmtUnits(stats[1], 18, 6)}` : '—',
      sub: '1 share → asset units (×10¹⁸)',
    },
    {
      label: 'Depositors',
      value: stats ? stats[2].toString() : '—',
      sub: 'Unique LPs',
    },
    {
      label: 'Yield collected',
      value: stats
        ? `${fmtCompact(stats[4], deployment.assetDecimals)} ${deployment.assetSymbol}`
        : '—',
      sub: 'Lifetime auto-compounded',
    },
    {
      label: 'Performance fee',
      value: perfBps !== undefined ? `${(Number(perfBps) / 100).toFixed(2)}%` : '—',
      sub: 'Treasury cut on yield',
    },
    {
      label: 'Tick range',
      value:
        tickLower !== undefined && tickUpper !== undefined
          ? `${tickLower} → ${tickUpper}`
          : '—',
      sub: 'Owner-rebalanceable',
    },
  ];

  return (
    <div>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
        {cards.map((c) => (
          <div key={c.label} className="card card-hover p-4">
            <div className="stat-label">{c.label}</div>
            <div className="stat-value mt-1">{isLoading && enabled ? '…' : c.value}</div>
            <div className="mt-1 text-xs text-zinc-500">{c.sub}</div>
          </div>
        ))}
      </div>
      {stats?.[5] && (
        <p className="mt-4 text-center text-xs text-zinc-500 font-mono">
          {stats[5]}
        </p>
      )}
      {isStatsError && (
        <p className="mt-2 text-center text-xs text-amber-400">
          Could not read live vault stats from RPC. {statsError?.message}
        </p>
      )}
    </div>
  );
}
