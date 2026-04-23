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

Open http://localhost:3000.

The app reads on-chain state from Arbitrum One (and Sepolia). If `NEXT_PUBLIC_VAULT_ARB_ONE` is empty, stats render a graceful "not deployed" state so you can ship the UI before contracts go live.

## Deploy to Vercel (free tier)

1. Push the repo to GitHub (already done).
2. On [vercel.com](https://vercel.com) → **New Project** → import `emilianosolazzi/The-Pool`.
3. **Root Directory**: `web`.
4. Framework preset auto-detects **Next.js**. Leave defaults.
5. Add environment variables from [`.env.example`](.env.example):
   - `NEXT_PUBLIC_WC_PROJECT_ID` — get a free one at [cloud.reown.com](https://cloud.reown.com).
   - `NEXT_PUBLIC_VAULT_ARB_ONE`, `NEXT_PUBLIC_HOOK_ARB_ONE`, `NEXT_PUBLIC_DISTRIBUTOR_ARB_ONE` — fill after `forge script script/Deploy.s.sol` completes.
6. Deploy.

Build output is static + edge-compatible; well within the 100 GB / month free-tier bandwidth.

## Updating contract addresses

Set the Vercel env vars and redeploy (or trigger a Deployment Hook). No code change needed.

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
