export function Hero({ pairSymbol }: { pairSymbol: string }) {
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
          First $100K TVL shares <strong className="text-white">50% of treasury swap fees</strong> for
          6 months — time-weighted, capped, paid monthly in USDC. On top of the normal LP fee share,
          not instead of it. No new token, no vesting, no emissions.
        </p>
        <div className="mt-8 flex flex-wrap items-center gap-3">
          <a href="#vault" className="btn-primary">Deposit USDC</a>
          <a
            href="https://github.com/emilianosolazzi/The-Pool/blob/main/docs/BOOTSTRAP.md"
            target="_blank"
            rel="noopener noreferrer"
            className="btn-ghost"
          >
            Read the bootstrap spec
          </a>
          <span className="ml-1 text-sm text-zinc-400">
            Eligibility starts after 7 days ·{' '}
            <span className="font-mono text-zinc-200">{pairSymbol}</span> · Arbitrum&nbsp;One
          </span>
        </div>
      </div>
    </section>
  );
}
