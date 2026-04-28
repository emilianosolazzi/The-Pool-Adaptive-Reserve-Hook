'use client';

import { useChainId } from 'wagmi';
import { arbitrum, arbitrumSepolia } from 'wagmi/chains';
import { Nav } from '@/components/Nav';
import { Hero } from '@/components/Hero';
import { PlainEnglish } from '@/components/PlainEnglish';
import { StatsGrid } from '@/components/StatsGrid';
import { VaultCard } from '@/components/VaultCard';
import { BootstrapPanel } from '@/components/BootstrapPanel';
import { SwapPanel } from '@/components/SwapPanel';
import { HowItWorks } from '@/components/HowItWorks';
import { Footer } from '@/components/Footer';
import { ReserveStatus } from '@/components/ReserveStatus';
import { OwnerPanel } from '@/components/OwnerPanel';
import { DEFAULT_CHAIN_ID, getDeployment, type AppChainId } from '@/lib/deployments';

export default function HomePage() {
  const chainId = useChainId();
  const activeChainId: AppChainId =
    chainId === arbitrum.id || chainId === arbitrumSepolia.id
      ? chainId
      : DEFAULT_CHAIN_ID;
  const deployment = getDeployment(activeChainId);
  const explorerBase =
    activeChainId === arbitrumSepolia.id
      ? 'https://sepolia.arbiscan.io'
      : 'https://arbiscan.io';

  return (
    <>
      <Nav />
      <main>
        <Hero pairSymbol={deployment.pairSymbol} swapUrl={deployment.swapUrl} />

        <PlainEnglish deployment={deployment} />

        <section id="vault" className="mx-auto max-w-6xl px-4 py-16">
          <div className="mb-8 flex items-end justify-between">
            <div>
              <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
                Vault overview
              </h2>
              <p className="mt-2 text-zinc-400">
                Live on-chain state. Deposit to start earning fee yield.
              </p>
            </div>
          </div>

          <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
            <div>
              <StatsGrid deployment={deployment} chainId={activeChainId} />
            </div>
            <VaultCard deployment={deployment} chainId={activeChainId} />
          </div>
        </section>

        <BootstrapPanel
          deployment={deployment}
          chainId={activeChainId}
          explorerBase={explorerBase}
        />

        <SwapPanel
          deployment={deployment}
          chainId={activeChainId}
          explorerBase={explorerBase}
        />

        <ReserveStatus
          deployment={deployment}
          chainId={activeChainId}
          explorerBase={explorerBase}
        />

        <OwnerPanel
          deployment={deployment}
          chainId={activeChainId}
          explorerBase={explorerBase}
        />

        <HowItWorks deployment={deployment} chainId={activeChainId} />
      </main>
      <Footer />
    </>
  );
}
