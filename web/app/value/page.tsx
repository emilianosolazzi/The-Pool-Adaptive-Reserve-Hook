'use client';

import { useChainId } from 'wagmi';
import { arbitrum, arbitrumSepolia } from 'wagmi/chains';
import { Nav } from '@/components/Nav';
import { Footer } from '@/components/Footer';
import { DEFAULT_CHAIN_ID, getDeployment, type AppChainId } from '@/lib/deployments';
import { ValueCalculator } from '@/components/ValueCalculator';

export default function ValuePage() {
  const chainId = useChainId();
  const activeChainId: AppChainId =
    chainId === arbitrum.id || chainId === arbitrumSepolia.id
      ? chainId
      : DEFAULT_CHAIN_ID;
  const deployment = getDeployment(activeChainId);

  return (
    <>
      <Nav />
      <main className="min-h-screen bg-gradient-to-br from-zinc-900 via-zinc-800 to-zinc-900">
        <div className="mx-auto max-w-7xl px-4 py-16">
          <div className="mb-12 text-center">
            <h1 className="text-4xl font-bold tracking-tight text-white md:text-5xl">
              Real Value Calculator
            </h1>
            <p className="mt-4 text-xl text-zinc-400">
              See the actual mathematics behind The-Pool&apos;s yield generation
            </p>
            <p className="mt-2 text-sm text-zinc-500">
              Based on live Arbitrum One WETH/USDC pool data and real fee generation
            </p>
          </div>

          <ValueCalculator deployment={deployment} chainId={activeChainId} />
        </div>
      </main>
      <Footer />
    </>
  );
}