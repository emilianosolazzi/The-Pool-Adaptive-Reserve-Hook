export function Hero({ pairSymbol }: { pairSymbol: string }) {
  return (
    <section className="relative overflow-hidden border-b border-white/5">
      <div className="absolute inset-0 bg-grid-fade pointer-events-none" />
      <div className="relative mx-auto max-w-6xl px-4 py-20 md:py-28">
        <div className="mb-6 flex flex-wrap gap-2">
          <span className="chip">
            <span className="h-1.5 w-1.5 rounded-full bg-lime-400" />
            Fee-only yield
          </span>
          <span className="chip">25 bps dynamic hook fee</span>
          <span className="chip">1.5× volatility multiplier</span>
          <span className="chip">80% back to LPs</span>
        </div>
        <h1 className="max-w-3xl text-4xl font-semibold tracking-tight text-white md:text-6xl">
          Auto-compounding LP yield on{' '}
          <span className="bg-gradient-to-br from-accent-400 to-lime-400 bg-clip-text text-transparent">
            Uniswap&nbsp;v4.
          </span>
        </h1>
        <p className="mt-5 max-w-2xl text-balance text-lg text-zinc-400">
          The Pool attaches a programmable fee layer to any v4 concentrated-liquidity
          pool. 20% of every swap fee funds the treasury; 80% is donated back to
          the pool on the same transaction. Share price appreciates automatically —
          no claims, no staking, no emissions.
        </p>
        <div className="mt-8 flex flex-wrap items-center gap-3">
          <a href="#vault" className="btn-primary">Open the vault</a>
          <a
            href="https://github.com/emilianosolazzi/The-Pool/blob/main/docs/ARCHITECTURE.md"
            target="_blank"
            rel="noopener noreferrer"
            className="btn-ghost"
          >
            Read the architecture
          </a>
          <span className="ml-1 text-sm text-zinc-500">
            Reference deployment: <span className="font-mono text-zinc-300">{pairSymbol}</span> · Arbitrum&nbsp;One
          </span>
        </div>
      </div>
    </section>
  );
}
