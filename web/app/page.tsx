'use client';

import { useChainId } from 'wagmi';
import { Nav } from '@/components/Nav';
import { Hero } from '@/components/Hero';
import { StatsGrid } from '@/components/StatsGrid';
import { VaultCard } from '@/components/VaultCard';
import { HowItWorks } from '@/components/HowItWorks';
import { Footer } from '@/components/Footer';
import { DEFAULT_CHAIN_ID, getDeployment, type AppChainId } from '@/lib/deployments';

export default function HomePage() {
  const chainId = useChainId();
  const activeChainId = (chainId as AppChainId) ?? DEFAULT_CHAIN_ID;
  const deployment = getDeployment(activeChainId);

  return (
    <>
      <Nav />
      <main>
        <Hero pairSymbol={deployment.pairSymbol} />

        <section id="vault" className="mx-auto max-w-6xl px-4 py-16">
          <div className="mb-8 flex items-end justify-between">
            <div>
              <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
                Vault overview
              </h2>
              <p className="mt-2 text-zinc-400">
                Live on-chain state. Deposit to start auto-compounding.
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

        <HowItWorks deployment={deployment} />
      </main>
      <Footer />
    </>
  );
}
