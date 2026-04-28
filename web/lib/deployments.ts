import { arbitrum, arbitrumSepolia } from 'wagmi/chains';
import type { Address } from 'viem';

export type AppChainId = typeof arbitrum.id | typeof arbitrumSepolia.id;

export const DEFAULT_CHAIN_ID: AppChainId =
  (Number(process.env.NEXT_PUBLIC_DEFAULT_CHAIN_ID) as AppChainId) || arbitrum.id;

const envAddr = (key: string): Address | undefined => {
  const v = process.env[key];
  if (!v || !/^0x[a-fA-F0-9]{40}$/.test(v)) return undefined;
  return v as Address;
};

export interface Deployment {
  vault?: Address;
  lens?: Address;
  hook?: Address;
  distributor?: Address;
  bootstrap?: Address;
  poolManager?: Address;
  asset?: Address;
  swapUrl?: string;
  assetSymbol: string;
  assetDecimals: number;
  pairSymbol: string;
}

export const DEPLOYMENTS: Record<AppChainId, Deployment> = {
  [arbitrum.id]: {
    // V2.1 production set (Phase C, Apr 2026). See repo memory for history.
    vault: envAddr('NEXT_PUBLIC_VAULT_ARB_ONE') ??
      ('0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0' as Address),
    lens: envAddr('NEXT_PUBLIC_VAULT_LENS_ARB_ONE') ??
      ('0x12e86890b75fdee22a35be66550373936d883551' as Address),
    hook: envAddr('NEXT_PUBLIC_HOOK_ARB_ONE') ??
      ('0x486579DE6391053Df88a073CeBd673dd545200cC' as Address),
    distributor: envAddr('NEXT_PUBLIC_DISTRIBUTOR_ARB_ONE') ??
      ('0x5757DA9014EE91055b244322a207EE6F066378B0' as Address),
    // BootstrapRewards (V2.1, Apr 28 2026, programStart 1777348921, 180 days).
    bootstrap: envAddr('NEXT_PUBLIC_BOOTSTRAP_ARB_ONE') ??
      ('0x3E6Ed05c1140612310DDE0d0DDaAcCA6e0d7a03d' as Address),
    poolManager: envAddr('NEXT_PUBLIC_POOL_MANAGER_ARB_ONE') ??
      ('0x360e68faccca8ca495c1b759fd9eee466db9fb32' as Address),
    asset: envAddr('NEXT_PUBLIC_ASSET_ARB_ONE') ??
      ('0xaf88d065e77c8cC2239327C5EDb3A432268e5831' as Address), // USDC native
    swapUrl: process.env.NEXT_PUBLIC_SWAP_URL_ARB_ONE ??
      'https://app.uniswap.org/swap?chain=arbitrum&inputCurrency=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1&outputCurrency=0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
    assetSymbol: process.env.NEXT_PUBLIC_ASSET_SYMBOL ?? 'USDC',
    assetDecimals: Number(process.env.NEXT_PUBLIC_ASSET_DECIMALS ?? 6),
    pairSymbol: process.env.NEXT_PUBLIC_PAIR_SYMBOL ?? 'WETH / USDC',
  },
  [arbitrumSepolia.id]: {
    vault: envAddr('NEXT_PUBLIC_VAULT_ARB_SEPOLIA'),
    lens: envAddr('NEXT_PUBLIC_VAULT_LENS_ARB_SEPOLIA'),
    hook: envAddr('NEXT_PUBLIC_HOOK_ARB_SEPOLIA'),
    distributor: envAddr('NEXT_PUBLIC_DISTRIBUTOR_ARB_SEPOLIA'),
    bootstrap: envAddr('NEXT_PUBLIC_BOOTSTRAP_ARB_SEPOLIA'),
    poolManager: envAddr('NEXT_PUBLIC_POOL_MANAGER_ARB_SEPOLIA') ??
      ('0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317' as Address),
    asset: envAddr('NEXT_PUBLIC_ASSET_ARB_SEPOLIA'),
    swapUrl: process.env.NEXT_PUBLIC_SWAP_URL_ARB_SEPOLIA ?? 'https://app.uniswap.org/swap?chain=arbitrum_sepolia',
    assetSymbol: 'tUSDC',
    assetDecimals: 6,
    pairSymbol: 'tWETH / tUSDC',
  },
};

export const getDeployment = (chainId: AppChainId): Deployment =>
  DEPLOYMENTS[chainId] ?? DEPLOYMENTS[DEFAULT_CHAIN_ID];

// ── Swap infrastructure ──────────────────────────────────────────────────────
// Universal Router (v4-aware) and V4Quoter, per chain. Permit2 is canonical.
export const PERMIT2: Address = '0x000000000022D473030F116dDEE9F6B43aC78BA3';

export interface SwapInfra {
  universalRouter: Address;
  v4Quoter: Address;
  weth: Address;
}

export const SWAP_INFRA: Record<AppChainId, SwapInfra | undefined> = {
  [arbitrum.id]: {
    universalRouter: '0xa51afafe0263b40edaef0df8781ea9aa03e381a3',
    v4Quoter: '0x3972c00f7ed4885e145823eb7c655375d275a1c5',
    weth: '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1',
  },
  [arbitrumSepolia.id]: undefined,
};

export const getSwapInfra = (chainId: AppChainId): SwapInfra | undefined =>
  SWAP_INFRA[chainId];
