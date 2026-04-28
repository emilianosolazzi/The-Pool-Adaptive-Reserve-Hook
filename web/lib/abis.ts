import type { Abi } from 'viem';

// Minimal ABI fragments for UI reads/writes. Extend as needed.

export const erc20Abi = [
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
] as const satisfies Abi;

export const vaultAbi = [
  // ERC-4626 core
  { type: 'function', name: 'asset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'totalAssets', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'convertToAssets', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'convertToShares', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'previewDeposit', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'previewRedeem', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'deposit', stateMutability: 'nonpayable', inputs: [{ type: 'uint256' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'redeem', stateMutability: 'nonpayable', inputs: [{ type: 'uint256' }, { type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  // V2 zap deposit: vault swaps `assetsToSwap` of the asset into the other
  // pool token via the configured V3 zap adapter, then mints LP. Shares are
  // minted from the realised NAV delta, so existing depositors are not
  // diluted by the new depositor's swap cost.
  {
    type: 'function',
    name: 'depositWithZap',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'assets', type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'assetsToSwap', type: 'uint256' },
      { name: 'minOtherOut', type: 'uint256' },
      { name: 'minLiquidity', type: 'uint256' },
      { name: 'minSharesOut', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  // Pool-specific views
  {
    type: 'function',
    name: 'getVaultStats',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'tvl', type: 'uint256' },
      { name: 'sharePrice', type: 'uint256' },
      { name: 'depositors', type: 'uint256' },
      { name: 'liqDeployed', type: 'uint256' },
      { name: 'yieldColl', type: 'uint256' },
      { name: 'feeDesc', type: 'string' },
    ],
  },
  { type: 'function', name: 'tickLower', stateMutability: 'view', inputs: [], outputs: [{ type: 'int24' }] },
  { type: 'function', name: 'tickUpper', stateMutability: 'view', inputs: [], outputs: [{ type: 'int24' }] },
  { type: 'function', name: 'maxTVL', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'performanceFeeBps', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'owner', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  // Owner-only reserve-desk writes
  {
    type: 'function',
    name: 'rebalanceOfferWithMode',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'sellCurrency', type: 'address' },
      { name: 'newSellAmount', type: 'uint128' },
      { name: 'newSqrtPriceX96', type: 'uint160' },
      { name: 'expiry', type: 'uint64' },
      { name: 'mode', type: 'uint8' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'cancelReserveOffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'sellCurrency', type: 'address' }],
    outputs: [{ name: 'returned', type: 'uint128' }],
  },
  {
    type: 'function',
    name: 'collectReserveProceeds',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'currency', type: 'address' }],
    outputs: [{ name: 'amount', type: 'uint256' }],
  },
  // Pool key (set once after deployment)
  { type: 'function', name: 'poolKey', stateMutability: 'view', inputs: [], outputs: [{ type: 'tuple', components: [
    { name: 'currency0', type: 'address' },
    { name: 'currency1', type: 'address' },
    { name: 'fee', type: 'uint24' },
    { name: 'tickSpacing', type: 'int24' },
    { name: 'hooks', type: 'address' },
  ] }] },
] as const satisfies Abi;

// VaultLens — V2.1 split moved aggregate views off the vault into a stateless lens.
export const lensAbi = [
  {
    type: 'function',
    name: 'getVaultStats',
    stateMutability: 'view',
    inputs: [{ name: 'vault', type: 'address' }],
    outputs: [
      { name: 'tvl', type: 'uint256' },
      { name: 'sharePrice', type: 'uint256' },
      { name: 'depositors', type: 'uint256' },
      { name: 'liqDeployed', type: 'uint256' },
      { name: 'yieldColl', type: 'uint256' },
      { name: 'feeDesc', type: 'string' },
    ],
  },
  {
    type: 'function',
    name: 'vaultStatus',
    stateMutability: 'view',
    inputs: [{ name: 'vault', type: 'address' }],
    outputs: [{ type: 'uint8' }],
  },
  {
    type: 'function',
    name: 'poolKeyView',
    stateMutability: 'view',
    inputs: [{ name: 'vault', type: 'address' }],
    outputs: [{ type: 'tuple', components: [
      { name: 'currency0', type: 'address' },
      { name: 'currency1', type: 'address' },
      { name: 'fee', type: 'uint24' },
      { name: 'tickSpacing', type: 'int24' },
      { name: 'hooks', type: 'address' },
    ] }],
  },
] as const satisfies Abi;

// Uniswap v4 PoolManager ABI for pool state queries
export const poolManagerAbi = [
  {
    type: 'function',
    name: 'getSlot0',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'tick', type: 'int24' },
      { name: 'protocolFee', type: 'uint24' },
      { name: 'hookFee', type: 'uint24' },
    ],
  },
  {
    type: 'function',
    name: 'getLiquidity',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: 'liquidity', type: 'uint128' }],
  },
  {
    type: 'function',
    name: 'getFeeGrowthGlobal0X128',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: 'feeGrowthGlobal0X128', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getFeeGrowthGlobal1X128',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: 'feeGrowthGlobal1X128', type: 'uint256' }],
  },
] as const satisfies Abi;

// BootstrapRewards — surfaces epoch bonus pool, schedule, payout asset
export const bootstrapAbi = [
  { type: 'function', name: 'payoutAsset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'realTreasury', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'programStart', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  { type: 'function', name: 'epochLength', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  { type: 'function', name: 'epochCount', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint32' }] },
  { type: 'function', name: 'bonusShareBps', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint16' }] },
  { type: 'function', name: 'perEpochCap', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'perWalletShareCap', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'programEnd', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'currentEpoch', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  {
    type: 'function',
    name: 'epochBounds',
    stateMutability: 'view',
    inputs: [{ name: 'epoch', type: 'uint256' }],
    outputs: [
      { name: 'start', type: 'uint256' },
      { name: 'end', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'epochs',
    stateMutability: 'view',
    inputs: [{ type: 'uint256' }],
    outputs: [
      { name: 'bonusPool', type: 'uint128' },
      { name: 'claimedAmount', type: 'uint128' },
      { name: 'totalShareSeconds', type: 'uint256' },
      { name: 'swept', type: 'bool' },
    ],
  },
  { type: 'function', name: 'isEpochFinalized', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'isClaimWindowOpen', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'eligibleSharesOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'claimed', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'pullInflow', stateMutability: 'nonpayable', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'poke', stateMutability: 'nonpayable', inputs: [{ type: 'address' }], outputs: [] },
  {
    type: 'function',
    name: 'claim',
    stateMutability: 'nonpayable',
    inputs: [{ type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
  },
] as const satisfies Abi;

// Universal Router execute() — v4 swaps go through here
export const universalRouterAbi = [
  {
    type: 'function',
    name: 'execute',
    stateMutability: 'payable',
    inputs: [
      { name: 'commands', type: 'bytes' },
      { name: 'inputs', type: 'bytes[]' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [],
  },
] as const satisfies Abi;

// V4Quoter — exact-input single-pool quote. Reverts with the result; viem
// surfaces it via simulateContract / readContract on Arbitrum.
export const v4QuoterAbi = [
  {
    type: 'function',
    name: 'quoteExactInputSingle',
    stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'params',
        type: 'tuple',
        components: [
          {
            name: 'poolKey',
            type: 'tuple',
            components: [
              { name: 'currency0', type: 'address' },
              { name: 'currency1', type: 'address' },
              { name: 'fee', type: 'uint24' },
              { name: 'tickSpacing', type: 'int24' },
              { name: 'hooks', type: 'address' },
            ],
          },
          { name: 'zeroForOne', type: 'bool' },
          { name: 'exactAmount', type: 'uint128' },
          { name: 'hookData', type: 'bytes' },
        ],
      },
    ],
    outputs: [
      { name: 'amountOut', type: 'uint256' },
      { name: 'gasEstimate', type: 'uint256' },
    ],
  },
] as const satisfies Abi;

// Permit2 — only the bits the SwapPanel needs
export const permit2Abi = [
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
      { name: 'nonce', type: 'uint48' },
    ],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
    ],
    outputs: [],
  },
] as const satisfies Abi;

// DynamicFeeHookV2 — public reads + reserve-desk events. Used by ReserveStatus
// (the public transparency dashboard) and any future owner admin panel.
export const hookAbi = [
  // Counters / diagnostics
  { type: 'function', name: 'totalSwaps', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalFeesRouted', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalReserveFills', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalReserveSold', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'feeDistributor', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  // Reserve-offer reads (PoolKey-keyed)
  {
    type: 'function',
    name: 'offerActive',
    stateMutability: 'view',
    inputs: [{ name: 'key', type: 'tuple', components: [
      { name: 'currency0', type: 'address' },
      { name: 'currency1', type: 'address' },
      { name: 'fee', type: 'uint24' },
      { name: 'tickSpacing', type: 'int24' },
      { name: 'hooks', type: 'address' },
    ] }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 'getOffer',
    stateMutability: 'view',
    inputs: [{ name: 'key', type: 'tuple', components: [
      { name: 'currency0', type: 'address' },
      { name: 'currency1', type: 'address' },
      { name: 'fee', type: 'uint24' },
      { name: 'tickSpacing', type: 'int24' },
      { name: 'hooks', type: 'address' },
    ] }],
    outputs: [{ type: 'tuple', components: [
      { name: 'sellCurrency', type: 'address' },
      { name: 'buyCurrency', type: 'address' },
      { name: 'sellRemaining', type: 'uint128' },
      { name: 'vaultSqrtPriceX96', type: 'uint160' },
      { name: 'expiry', type: 'uint64' },
      { name: 'sellingCurrency1', type: 'bool' },
      { name: 'active', type: 'bool' },
      { name: 'pricingMode', type: 'uint8' },
    ] }],
  },
  {
    type: 'function',
    name: 'getOfferHealth',
    stateMutability: 'view',
    inputs: [
      { name: 'key', type: 'tuple', components: [
        { name: 'currency0', type: 'address' },
        { name: 'currency1', type: 'address' },
        { name: 'fee', type: 'uint24' },
        { name: 'tickSpacing', type: 'int24' },
        { name: 'hooks', type: 'address' },
      ] },
      { name: 'vault', type: 'address' },
    ],
    outputs: [
      { name: 'active', type: 'bool' },
      { name: 'driftBps', type: 'int256' },
      { name: 'escrow0', type: 'uint256' },
      { name: 'escrow1', type: 'uint256' },
      { name: 'proceeds0', type: 'uint256' },
      { name: 'proceeds1', type: 'uint256' },
      { name: 'vaultSqrtPriceX96', type: 'uint160' },
      { name: 'poolSqrtPriceX96', type: 'uint160' },
    ],
  },
  // Events — used by usePublicClient.getLogs for the transparency feed.
  {
    type: 'event',
    name: 'ReserveOfferCreated',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'vault', type: 'address', indexed: true },
      { name: 'sellCurrency', type: 'address', indexed: false },
      { name: 'sellAmount', type: 'uint128', indexed: false },
      { name: 'vaultSqrtPriceX96', type: 'uint160', indexed: false },
      { name: 'expiry', type: 'uint64', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ReserveOfferMode',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'vault', type: 'address', indexed: true },
      { name: 'mode', type: 'uint8', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ReserveOfferCancelled',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'vault', type: 'address', indexed: true },
      { name: 'returnedAmount', type: 'uint128', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ReserveFilled',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'vault', type: 'address', indexed: true },
      { name: 'sellAmount', type: 'uint256', indexed: false },
      { name: 'buyAmount', type: 'uint256', indexed: false },
      { name: 'poolSqrtPriceX96', type: 'uint160', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ReserveProceedsClaimed',
    inputs: [
      { name: 'vault', type: 'address', indexed: true },
      { name: 'currency', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ReserveOfferStale',
    inputs: [
      { name: 'poolId', type: 'bytes32', indexed: true },
      { name: 'vault', type: 'address', indexed: true },
      { name: 'driftBps', type: 'int256', indexed: false },
    ],
  },
] as const satisfies Abi;
