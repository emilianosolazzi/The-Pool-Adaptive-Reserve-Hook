import type { Deployment } from '@/lib/deployments';

/**
 * Plain-English explainer. Facts verified against src/LiquidityVaultV2.sol,
 * src/DynamicFeeHookV2.sol, src/FeeDistributor.sol:
 *  - 25 BPS base hook fee, 1.5x in volatile blocks, maxFeeBps default 50
 *    (owner-adjustable, hard-capped at 1000)
 *  - Default split: 20% of hook fee -> treasury, 80% -> poolManager.donate()
 *    to in-range LPs. treasuryShare is owner-adjustable, hard-capped at 50%
 *    (LP share floor 50%).
 *  - Vault is ERC-4626 single-sided out-of-range (asset only; fee capture starts
 *    once the market price enters the configured range)
 *  - Share price accrues as fees are donated to in-range liquidity; no claim flow.
 *  - Anyone can call collectYield(); redeployment occurs via deposit/rebalance paths.
 */
export function PlainEnglish({ deployment }: { deployment: Deployment }) {
  const a = deployment.assetSymbol;
  const pair = deployment.pairSymbol;

  const lines: { label: string; body: React.ReactNode }[] = [
    {
      label: '01',
      body: (
        <>
          You deposit{' '}
          <span className="text-white font-semibold">{a}</span> into this vault.
        </>
      ),
    },
    {
      label: '02',
      body: (
        <>
          The vault can deploy it as a single-sided concentrated-liquidity
          position on Uniswap&nbsp;v4 on the{' '}
          <span className="text-white font-semibold">{pair}</span> pool.
          While the live price sits above that range, the position is parked in
          {` ${a} `}and not active swap depth yet.
        </>
      ),
    },
    {
      label: '03',
      body: (
        <>
          Swaps routed through the hook attempt to apply a{' '}
          <span className="text-white font-semibold">25&nbsp;bps fee</span>{' '}
          (1.5× in volatile blocks, hard-capped at 50&nbsp;bps).
        </>
      ),
    },
    {
      label: '04',
      body: (
        <>
          By default <span className="text-white font-semibold">80%</span> of
          that fee is donated back to in-range LPs in the pool — including the
          vault once its position is active — in the same transaction.{' '}
          <span className="text-zinc-400">
            (The other 20% funds the treasury. Treasury share is
            owner-adjustable, hard-capped at 50%.)
          </span>
        </>
      ),
    },
    {
      label: '05',
      body: (
        <>
          Your <span className="text-white font-semibold">share price rises</span>{' '}
          as in-range fees accrue — no claim, no staking. Anyone can call{' '}
          <code className="rounded bg-white/5 px-1 font-mono">collectYield()</code>{' '}
          to harvest fees. Deployment into active range occurs on{' '}
          <code className="rounded bg-white/5 px-1 font-mono">deposit()</code>{' '}
          and owner{' '}
          <code className="rounded bg-white/5 px-1 font-mono">rebalance()</code>{' '}
          paths.
        </>
      ),
    },
  ];

  return (
    <section className="mx-auto max-w-6xl px-4 py-14 md:py-20">
      <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-accent-500/10 via-iris-500/5 to-transparent p-6 md:p-10">
        <div className="pointer-events-none absolute -top-24 -right-24 h-64 w-64 rounded-full bg-accent-500/30 blur-3xl" />
        <div className="pointer-events-none absolute -bottom-24 -left-24 h-64 w-64 rounded-full bg-iris-500/30 blur-3xl" />

        <div className="relative">
          <div className="mb-6 flex items-center gap-2">
            <span className="chip">In plain English</span>
          </div>
          <h2 className="mb-8 max-w-2xl text-2xl font-semibold tracking-tight text-white md:text-3xl">
            What happens when you <span className="gradient-text">deposit {a}</span>.
          </h2>

          <ol className="space-y-4">
            {lines.map((l) => (
              <li key={l.label} className="flex items-start gap-4">
                <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-white/10 bg-white/5 font-mono text-xs font-semibold text-accent-300">
                  {l.label}
                </span>
                <p className="text-base leading-relaxed text-zinc-200 md:text-lg">
                  {l.body}
                </p>
              </li>
            ))}
          </ol>

          <div className="mt-8 rounded-2xl border border-white/10 bg-black/20 p-4 text-sm text-zinc-300">
            <span className="text-white font-semibold">Honest caveat.</span> The
            vault is single-sided: it can hold {a} outside the active price band
            while waiting to convert across the owner-configured tick range.
            Fee capture starts when liquidity is in range. Anyone can call{' '}
            <code className="rounded bg-white/5 px-1 font-mono">collectYield()</code>{' '}
            to harvest accrued fees into share price &mdash; that part is
            permissionless. Moving the range itself (
            <code className="rounded bg-white/5 px-1 font-mono">rebalance()</code>)
            is owner-only, so if the market price drifts outside the configured
            ticks the position can sit idle until the owner repositions it.
          </div>
        </div>
      </div>
    </section>
  );
}
