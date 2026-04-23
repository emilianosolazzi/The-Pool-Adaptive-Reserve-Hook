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
  hook?: Address;
  distributor?: Address;
  asset?: Address;
  assetSymbol: string;
  assetDecimals: number;
  pairSymbol: string;
}

export const DEPLOYMENTS: Record<AppChainId, Deployment> = {
  [arbitrum.id]: {
    vault: envAddr('NEXT_PUBLIC_VAULT_ARB_ONE'),
    hook: envAddr('NEXT_PUBLIC_HOOK_ARB_ONE'),
    distributor: envAddr('NEXT_PUBLIC_DISTRIBUTOR_ARB_ONE'),
    asset: envAddr('NEXT_PUBLIC_ASSET_ARB_ONE') ??
      ('0xaf88d065e77c8cC2239327C5EDb3A432268e5831' as Address), // USDC native
    assetSymbol: process.env.NEXT_PUBLIC_ASSET_SYMBOL ?? 'USDC',
    assetDecimals: Number(process.env.NEXT_PUBLIC_ASSET_DECIMALS ?? 6),
    pairSymbol: process.env.NEXT_PUBLIC_PAIR_SYMBOL ?? 'WETH / USDC',
  },
  [arbitrumSepolia.id]: {
    vault: envAddr('NEXT_PUBLIC_VAULT_ARB_SEPOLIA'),
    hook: envAddr('NEXT_PUBLIC_HOOK_ARB_SEPOLIA'),
    distributor: envAddr('NEXT_PUBLIC_DISTRIBUTOR_ARB_SEPOLIA'),
    asset: envAddr('NEXT_PUBLIC_ASSET_ARB_SEPOLIA'),
    assetSymbol: 'tUSDC',
    assetDecimals: 6,
    pairSymbol: 'tWETH / tUSDC',
  },
};

export const getDeployment = (chainId: AppChainId): Deployment =>
  DEPLOYMENTS[chainId] ?? DEPLOYMENTS[DEFAULT_CHAIN_ID];
