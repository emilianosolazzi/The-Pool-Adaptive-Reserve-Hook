export function Hero({ pairSymbol }: { pairSymbol: string; swapUrl?: string }) {
  return (
    <section className="relative overflow-hidden border-b border-white/5">
      <div className="absolute inset-0 bg-hero-mesh pointer-events-none" />
      <div className="relative mx-auto max-w-6xl px-4 py-20 md:py-28">
        <div className="mb-6 flex flex-wrap gap-2">
          <span className="chip">
            <span className="h-1.5 w-1.5 rounded-full bg-accent-400 shadow-[0_0_10px_rgba(255,92,184,0.8)]" />
            Early-depositor bonus live
          </span>
          <span className="chip">First $100K TVL</span>
          <span className="chip">6 months</span>
          <span className="chip">Paid in USDC</span>
        </div>
        <h1 className="max-w-3xl text-4xl font-semibold tracking-tight text-white md:text-6xl">
          Earn LP fees{' '}
          <span className="gradient-text">+ a 6-month early-depositor bonus.</span>
        </h1>
        <p className="mt-5 max-w-2xl text-balance text-lg text-zinc-300/90">
          Each hooked swap sends <strong className="text-white">80% back to pool LPs</strong> and{' '}
          <strong className="text-white">20% to treasury</strong>. First $100K TVL then shares{' '}
          <strong className="text-white">50% of that treasury stream</strong> for 6 months, time-weighted,
          capped, and paid in USDC.
        </p>
        <div className="mt-8 flex flex-wrap items-center gap-3">
          <a href="#vault" className="btn-primary">Deposit USDC — eligibility starts after 7 days</a>
          <a
            href="#swap"
            className="btn-ghost border-accent-500/20 bg-accent-500/10 text-accent-50 hover:border-accent-400/40 hover:bg-accent-500/15"
          >
            <span>Swap through the hook</span>
          </a>
          <a
            href="https://github.com/emilianosolazzi/The-Pool/blob/main/docs/BOOTSTRAP.md"
            target="_blank"
            rel="noopener noreferrer"
            className="btn-ghost"
          >
            Read the bootstrap spec
          </a>
          <span className="ml-1 text-sm text-zinc-400">
            <span className="font-mono text-zinc-200">{pairSymbol}</span> · Arbitrum&nbsp;One
          </span>
        </div>
        <p className="mt-4 max-w-3xl text-sm text-zinc-400">
          Swaps route directly through this app to the pool&apos;s own hook on
          Arbitrum One. Deposit USDC into the vault to capture 80% of every
          hook fee in your share price.
        </p>
        <p className="mt-6 max-w-3xl text-xs leading-relaxed text-zinc-500">
          Bonus is share-seconds-weighted, capped at $25K per wallet and $10K per monthly epoch.
          Transfers of vault shares forfeit unclaimed bonus. Program ends after 180 days or when
          the $100K TVL window closes. Not investment advice.
        </p>
      </div>
    </section>
  );
}
