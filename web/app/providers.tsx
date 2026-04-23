'use client';

import { RainbowKitProvider, darkTheme, getDefaultConfig } from '@rainbow-me/rainbowkit';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { arbitrum, arbitrumSepolia } from 'wagmi/chains';

const projectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? 'the-pool-demo';

export const wagmiConfig = getDefaultConfig({
  appName: 'The Pool',
  projectId,
  chains: [arbitrum, arbitrumSepolia],
  ssr: true,
});

const queryClient = new QueryClient();

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={darkTheme({
            accentColor: '#38bdf8',
            accentColorForeground: '#05060a',
            borderRadius: 'large',
            fontStack: 'system',
          })}
        >
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
