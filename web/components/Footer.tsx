export function Footer() {
  return (
    <footer className="border-t border-white/5 py-10">
      <div className="mx-auto flex max-w-6xl flex-col items-center gap-3 px-4 text-sm text-zinc-500 md:flex-row md:justify-between">
        <div>
          © {new Date().getFullYear()} The Pool. MIT-licensed.
        </div>
        <div className="flex items-center gap-5">
          <a
            href="https://github.com/emilianosolazzi/The-Pool"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-white"
          >
            GitHub
          </a>
          <a
            href="https://github.com/emilianosolazzi/The-Pool/blob/main/docs/ARCHITECTURE.md"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-white"
          >
            Architecture
          </a>
          <a
            href="https://docs.uniswap.org/contracts/v4/overview"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-white"
          >
            Uniswap v4
          </a>
        </div>
      </div>
      <div className="mx-auto mt-6 max-w-6xl px-4 text-[11px] leading-relaxed text-zinc-600">
        This interface is a reference UI for the open-source DeFi Hook Protocol. No
        warranty — interact at your own risk. Read the contracts before depositing.
      </div>
    </footer>
  );
}
