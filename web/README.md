# The Pool — Web UI

Next.js 14 + wagmi + RainbowKit + Tailwind. Deploys on Vercel free tier.

## Quick start

```bash
cd web
cp .env.example .env.local
# fill NEXT_PUBLIC_WC_PROJECT_ID and any deployed contract addresses
npm install
npm run dev
```
Current Arbitrum One values:

- NEXT_PUBLIC_VAULT_ARB_ONE=0x87F2db1A41A9227CBfBBC00A5AdE5770C85b3d71
- NEXT_PUBLIC_HOOK_ARB_ONE=0x62076C1Cb0Ea57Acd2353fF45226a1FB1e6100c4
- NEXT_PUBLIC_DISTRIBUTOR_ARB_ONE=0x474F59AE4699743AcC8563e7833e2bE90e7426C3

## What's included

- **Hero** + feature chips
- **Live vault stats** — TVL, share price, depositors, yield collected, performance fee, tick range, `feeDesc` (auto-refresh every 15 s)
- **Deposit / Withdraw card** — ERC-20 approve flow, `deposit(assets, receiver)`, `redeem(shares, receiver, owner)`, tx link to Arbiscan
- **How it works** — 4-step diagram + contract address panel linking to Arbiscan
- **Wallet connect** — RainbowKit, dark-themed, Arbitrum One + Sepolia chains

## Project structure

```
web/
├── app/
│   ├── layout.tsx         # metadata + providers
│   ├── page.tsx           # landing
│   ├── providers.tsx      # wagmi + RainbowKit + react-query
│   └── globals.css        # Tailwind + design tokens
├── components/
│   ├── Nav.tsx
│   ├── Hero.tsx
│   ├── StatsGrid.tsx
│   ├── VaultCard.tsx      # deposit/withdraw
│   ├── HowItWorks.tsx
│   └── Footer.tsx
├── lib/
│   ├── abis.ts            # minimal viem-typed ABI fragments
│   ├── deployments.ts     # per-chain addresses from env
│   └── format.ts
├── public/
│   └── favicon.svg
├── .env.example
├── next.config.mjs
├── tailwind.config.ts
├── postcss.config.mjs
├── tsconfig.json
└── package.json
```
