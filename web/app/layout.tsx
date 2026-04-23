import type { Metadata } from 'next';
import './globals.css';
import '@rainbow-me/rainbowkit/styles.css';
import { Providers } from './providers';

export const metadata: Metadata = {
  title: 'The Pool — Auto-compounding Uniswap v4 LP yield',
  description:
    'Fee-only, auto-compounding LP yield on Uniswap v4. 25 bps dynamic hook fee, 80% donated back to the pool on every swap. No token, no emissions, no lockups.',
  openGraph: {
    title: 'The Pool',
    description:
      'Fee-only, auto-compounding LP yield on Uniswap v4. 25 bps dynamic hook fee, 80% donated back to the pool on every swap.',
    type: 'website',
  },
  icons: { icon: '/favicon.svg' },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
