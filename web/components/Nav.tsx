'use client';

import { ConnectButton } from '@rainbow-me/rainbowkit';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useChainId } from 'wagmi';
import { arbitrum, arbitrumSepolia } from 'wagmi/chains';
import { DEFAULT_CHAIN_ID, getDeployment, type AppChainId } from '@/lib/deployments';

export function Nav() {
  const pathname = usePathname();
  const onHome = pathname === '/';
  const chainId = useChainId();
  const activeChainId: AppChainId =
    chainId === arbitrum.id || chainId === arbitrumSepolia.id
      ? chainId
      : DEFAULT_CHAIN_ID;
  const deployment = getDeployment(activeChainId);

  const howHref = onHome ? '#how' : '/#how';
  const vaultHref = onHome ? '#vault' : '/#vault';
  const reserveHref = onHome ? '#reserve' : '/#reserve';
  const externalIcon = (
    <svg viewBox="0 0 16 16" aria-hidden="true" className="h-3.5 w-3.5">
      <path
        d="M6 4h6v6M12 4 4 12"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="1.5"
      />
    </svg>
  );

  return (
    <header className="sticky top-0 z-40 border-b border-white/5 bg-ink-950/60 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4">
        <Link href="/" className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-accent-500 to-iris-500 text-white font-black shadow-glow">
            P
          </div>
          <span className="font-semibold tracking-tight">The&nbsp;Pool</span>
          <span className="chip ml-2 hidden sm:inline-flex">Uniswap v4 hook</span>
        </Link>
        <nav className="hidden items-center gap-6 text-sm text-zinc-300 md:flex">
          <Link href={howHref} className="hover:text-white">How it works</Link>
          <Link href="/value" className="hover:text-white">Value Calculator</Link>
          <Link href={vaultHref} className="hover:text-white">Vault</Link>
          <Link href={reserveHref} className="hover:text-white">Reserve desk</Link>
          {deployment.swapUrl ? (
            <a
              href={deployment.swapUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 rounded-full border border-accent-500/20 bg-accent-500/10 px-3 py-1.5 text-xs font-semibold text-accent-100 transition hover:border-accent-400/40 hover:bg-accent-500/15 hover:text-white"
            >
              <span>Swap on Uniswap</span>
              {externalIcon}
            </a>
          ) : null}
          <a
            href="https://github.com/emilianosolazzi/The-Pool"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-white"
          >
            GitHub
          </a>
        </nav>
        <ConnectButton
          chainStatus="icon"
          showBalance={false}
          accountStatus={{ smallScreen: 'avatar', largeScreen: 'full' }}
        />
      </div>
    </header>
  );
}
