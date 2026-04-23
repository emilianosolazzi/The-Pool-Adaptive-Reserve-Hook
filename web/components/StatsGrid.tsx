'use client';

import { useReadContract, useReadContracts } from 'wagmi';
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

  const { data, isLoading } = useReadContracts({
    contracts: enabled
      ? ([
          { address: vault!, abi: vaultAbi, functionName: 'getVaultStats', chainId },
          { address: vault!, abi: vaultAbi, functionName: 'totalSupply', chainId },
          { address: vault!, abi: vaultAbi, functionName: 'tickLower', chainId },
          { address: vault!, abi: vaultAbi, functionName: 'tickUpper', chainId },
          { address: vault!, abi: vaultAbi, functionName: 'performanceFeeBps', chainId },
        ] as const)
      : [],
    query: { enabled, refetchInterval: 15_000 },
  });

  const stats = data?.[0]?.result as
    | readonly [bigint, bigint, bigint, bigint, bigint, string]
    | undefined;
  const totalSupply = data?.[1]?.result as bigint | undefined;
  const tickLower = data?.[2]?.result as number | undefined;
  const tickUpper = data?.[3]?.result as number | undefined;
  const perfBps = data?.[4]?.result as bigint | undefined;

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
    </div>
  );
}
