import { shortAddress } from '@/lib/format';
import type { Deployment } from '@/lib/deployments';
import { arbitrumSepolia } from 'wagmi/chains';

const steps = [
  {
    n: '01',
    title: 'Swap triggers the hook',
    body: 'Swaps routed through the pool hook call DynamicFeeHookV2 — a 25 bps fee is computed from swap deltas and can scale 1.5× during volatile blocks.',
  },
  {
    n: '02',
    title: 'Fee is split and donated',
    body: 'FeeDistributor routes 20% to the treasury and 80% straight into poolManager.donate() — same tx, no escrow. Treasury share is owner-adjustable, hard-capped at 50%.',
  },
  {
    n: '03',
    title: 'Share price accrues',
    body: 'Donated fees flow to in-range LPs including the vault position once active; LiquidityVaultV2 share price rises from those fees — no claim, no staking. Anyone can call collectYield(); deployment into range occurs on deposit/rebalance paths.',
  },
  {
    n: '04',
    title: 'Owner rebalances the range',
    body: 'Ticks are owner-adjustable without touching depositor accounting. Range shifts leave share price untouched.',
  },
];

export function HowItWorks({ deployment, chainId }: { deployment: Deployment; chainId: number }) {
  const isSepolia = chainId === arbitrumSepolia.id;
  const explorerBase = isSepolia ? 'https://sepolia.arbiscan.io' : 'https://arbiscan.io';

  const addrRow = (label: string, a?: string) => (
    <div className="flex items-center justify-between border-b border-white/5 px-4 py-3 text-sm last:border-0">
      <span className="text-zinc-400">{label}</span>
      {a ? (
        <a
          href={`${explorerBase}/address/${a}`}
          target="_blank"
          rel="noopener noreferrer"
          className="font-mono text-accent-400 hover:underline"
        >
          {shortAddress(a)}
        </a>
      ) : (
        <span className="font-mono text-zinc-600">not set</span>
      )}
    </div>
  );

  return (
    <section id="how" className="mx-auto max-w-6xl px-4 py-16">
      <div className="mb-10 flex items-end justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">How it works</h2>
          <p className="mt-2 max-w-xl text-zinc-400">
            Four contracts, one transaction per swap. No off-chain keepers, no token.
          </p>
        </div>
      </div>
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        {steps.map((s) => (
          <div key={s.n} className="card card-hover p-5">
            <div className="font-mono text-xs text-accent-400">{s.n}</div>
            <div className="mt-2 font-semibold text-white">{s.title}</div>
            <div className="mt-2 text-sm leading-relaxed text-zinc-400">{s.body}</div>
          </div>
        ))}
      </div>

      <div className="mt-10 grid gap-6 md:grid-cols-2">
        <div className="card">
          <div className="border-b border-white/5 px-4 py-3 text-xs uppercase tracking-widest text-zinc-500">
            Contracts · {isSepolia ? 'Arbitrum Sepolia' : 'Arbitrum One'}
          </div>
          {addrRow('LiquidityVaultV2', deployment.vault)}
          {addrRow('DynamicFeeHookV2', deployment.hook)}
          {addrRow('FeeDistributor', deployment.distributor)}
          {addrRow('BootstrapRewards', deployment.bootstrap)}
          {addrRow(`Asset (${deployment.assetSymbol})`, deployment.asset)}
        </div>
        <div className="card p-5 text-sm leading-relaxed text-zinc-400">
          <div className="text-white font-semibold">Single-sided by design</div>
          <p className="mt-2">
            The vault holds one asset while waiting to convert across a configured
            tick band. On the reference {deployment.pairSymbol} deployment,
            depositors park {deployment.assetSymbol}; the vault&apos;s liquidity becomes
            active as WETH drops into range. Honest trade-off: while price remains
            outside the band, assets can sit idle until the owner rebalances.
          </p>
          <p className="mt-3">
            <span className="text-white">Security</span> — anti-sandwich reference-price
            gating, two-step ownership handoff, ERC-4626 virtual-shares inflation
            mitigation, <code className="rounded bg-white/5 px-1 font-mono">SafeERC20</code>{' '}
            on every transfer.
          </p>
        </div>
      </div>
    </section>
  );
}
