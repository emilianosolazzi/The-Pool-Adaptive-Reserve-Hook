'use client';

import { useMemo, useState } from 'react';
import { useReadContract, useReadContracts } from 'wagmi';
import { vaultAbi, poolManagerAbi } from '@/lib/abis';
import { fmtCompact } from '@/lib/format';
import { type Deployment } from '@/lib/deployments';
import { encodeAbiParameters, keccak256, type Address, type Hex } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
}

interface PoolData {
  liquidity: bigint;
  sqrtPriceX96: bigint;
  tick: number;
  protocolFee: number;
  hookFee: number;
  feeGrowth0: bigint;
  feeGrowth1: bigint;
}

interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

type VaultStatsTuple = readonly [bigint, bigint, bigint, bigint, bigint, string];

export function ValueCalculator({ deployment, chainId }: Props) {
  const [depositAmount, setDepositAmount] = useState('1000');
  const [dailyVolumeUsd, setDailyVolumeUsd] = useState('100000000');
  const [volatilityHitRatePct, setVolatilityHitRatePct] = useState('20');
  const [vaultLiquiditySharePct, setVaultLiquiditySharePct] = useState('1');
  const [timeframe, setTimeframe] = useState<'1D' | '7D' | '30D' | '1Y'>('30D');

  const vault = deployment.vault as Address | undefined;
  const poolManager = deployment.poolManager as Address | undefined;

  // Get vault stats
  const {
    data: vaultStatsData,
    isLoading: isVaultStatsLoading,
    isError: isVaultStatsError,
    error: vaultStatsError,
  } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'getVaultStats',
    chainId,
    query: { enabled: Boolean(vault), refetchInterval: 30_000 },
  });

  const vaultStats = useMemo<VaultStatsTuple | undefined>(() => {
    if (!vaultStatsData) return undefined;

    if (Array.isArray(vaultStatsData) && vaultStatsData.length >= 6) {
      return vaultStatsData as unknown as VaultStatsTuple;
    }

    const obj = vaultStatsData as unknown as Partial<Record<string, unknown>>;
    if (
      typeof obj.tvl === 'bigint' &&
      typeof obj.sharePrice === 'bigint' &&
      typeof obj.depositors === 'bigint' &&
      typeof obj.liqDeployed === 'bigint' &&
      typeof obj.yieldColl === 'bigint' &&
      typeof obj.feeDesc === 'string'
    ) {
      return [
        obj.tvl,
        obj.sharePrice,
        obj.depositors,
        obj.liqDeployed,
        obj.yieldColl,
        obj.feeDesc,
      ];
    }

    return undefined;
  }, [vaultStatsData]);

  const { data: performanceFeeBpsData } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'performanceFeeBps',
    chainId,
    query: { enabled: Boolean(vault), refetchInterval: 30_000 },
  });

  const performanceFeeBps = Number(performanceFeeBpsData ?? 0n);

  // Get pool key from vault (we need this for pool queries)
  const {
    data: poolKeyData,
    isLoading: isPoolKeyLoading,
    isError: isPoolKeyError,
  } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'poolKey',
    chainId,
    query: { enabled: Boolean(vault) },
  });

  const poolKey = useMemo<PoolKey | undefined>(() => {
    if (!poolKeyData) return undefined;

    if (Array.isArray(poolKeyData) && poolKeyData.length >= 5) {
      return {
        currency0: poolKeyData[0] as Address,
        currency1: poolKeyData[1] as Address,
        fee: Number(poolKeyData[2]),
        tickSpacing: Number(poolKeyData[3]),
        hooks: poolKeyData[4] as Address,
      };
    }

    const obj = poolKeyData as unknown as Partial<Record<string, unknown>>;
    if (
      typeof obj.currency0 === 'string' &&
      typeof obj.currency1 === 'string' &&
      obj.fee !== undefined &&
      obj.tickSpacing !== undefined &&
      typeof obj.hooks === 'string'
    ) {
      return {
        currency0: obj.currency0 as Address,
        currency1: obj.currency1 as Address,
        fee: Number(obj.fee),
        tickSpacing: Number(obj.tickSpacing),
        hooks: obj.hooks as Address,
      };
    }

    return undefined;
  }, [poolKeyData]);

  const poolId = useMemo(() => {
    if (!poolKey) return undefined;
    return keccak256(
      encodeAbiParameters(
        [
          { type: 'address' },
          { type: 'address' },
          { type: 'uint24' },
          { type: 'int24' },
          { type: 'address' },
        ],
        [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
      ),
    ) as Hex;
  }, [poolKey]);

  // Get pool data
  const { data: poolData } = useReadContracts({
    contracts: poolId && poolManager ? [
      {
        address: poolManager,
        abi: poolManagerAbi,
        functionName: 'getSlot0',
        args: [poolId],
        chainId,
      },
      {
        address: poolManager,
        abi: poolManagerAbi,
        functionName: 'getLiquidity',
        args: [poolId],
        chainId,
      },
      {
        address: poolManager,
        abi: poolManagerAbi,
        functionName: 'getFeeGrowthGlobal0X128',
        args: [poolId],
        chainId,
      },
      {
        address: poolManager,
        abi: poolManagerAbi,
        functionName: 'getFeeGrowthGlobal1X128',
        args: [poolId],
        chainId,
      },
    ] : [],
    query: { enabled: Boolean(poolId && poolManager), refetchInterval: 30_000 },
  });

  const poolInfo = useMemo((): PoolData | undefined => {
    if (!poolData) return undefined;
    return {
      sqrtPriceX96: poolData[0]?.result?.[0] as bigint,
      tick: poolData[0]?.result?.[1] as number,
      protocolFee: poolData[0]?.result?.[2] as number,
      hookFee: poolData[0]?.result?.[3] as number,
      liquidity: poolData[1]?.result as bigint,
      feeGrowth0: poolData[2]?.result as bigint,
      feeGrowth1: poolData[3]?.result as bigint,
    };
  }, [poolData]);

  // Contract-aligned scenario calculations.
  const calculations = useMemo(() => {
    if (!vaultStats) return null;

    const tvl = Number(vaultStats[0]) / 1e6;
    if (!Number.isFinite(tvl) || tvl <= 0) return null;

    const volume = Math.max(parseFloat(dailyVolumeUsd) || 0, 0);
    const volatilityRate = Math.min(Math.max((parseFloat(volatilityHitRatePct) || 0) / 100, 0), 1);
    const vaultLiquidityShare = Math.min(Math.max((parseFloat(vaultLiquiditySharePct) || 0) / 100, 0), 1);

    // DynamicFeeHookV2 constants and expected fee path.
    const baseHookFeeBps = 25;
    const expectedHookFeeBps = baseHookFeeBps * (1 + 0.5 * volatilityRate);
    const hookFeeRate = expectedHookFeeBps / 10_000;

    // Pool fee comes from poolKey.fee (Uniswap format: 1e6 = 100%).
    // Fallback to the known deployment tier when poolKey read is delayed.
    const poolFeeRate = poolKey ? Number(poolKey.fee) / 1_000_000 : 0.0005;

    const hookFeesDaily = volume * hookFeeRate;
    const treasuryShare = 0.2;
    const lpDonationDaily = hookFeesDaily * (1 - treasuryShare);
    const poolFeesDaily = volume * poolFeeRate;

    // Vault captures only its in-range liquidity share phi.
    const vaultGrossDaily = vaultLiquidityShare * (lpDonationDaily + poolFeesDaily);

    // LiquidityVaultV2 performance fee applied at collection time on asset-token yield.
    const perfFeeRate = performanceFeeBps / 10_000;
    const vaultNetDaily = vaultGrossDaily * (1 - perfFeeRate);

    const deposit = Math.max(parseFloat(depositAmount) || 0, 0);
    // Use post-deposit TVL so ownership share remains in [0,1].
    // Using deposit/tvl can exceed 100% when the simulated deposit is larger than current TVL.
    const postDepositTvl = tvl + deposit;
    const depositShareOfTVL = postDepositTvl > 0 ? deposit / postDepositTvl : 0;

    // APR/APY are USER-PERSPECTIVE: how much *the depositor* earns on their
    // own capital. Computing against raw `tvl` produces nonsense rates when
    // current TVL is tiny relative to the simulated deposit (e.g. $134K%).
    const userDailyYield = vaultNetDaily * depositShareOfTVL;
    const userDailyYieldRate = deposit > 0 ? userDailyYield / deposit : 0;
    const apr = userDailyYieldRate * 365;
    const apyRaw = (1 + userDailyYieldRate) ** 365 - 1;
    // Sanity guard: if compounding overshoots a sensible ceiling (e.g. due to
    // user inputs that imply daily rates > a few %), cap APY display at 3x APR
    // and at most 1000% absolute. Prevents 1e246% nonsense reaching the UI.
    const apyCap = Math.min(3 * apr, 10);
    const apy = Number.isFinite(apyRaw) ? Math.min(apyRaw, apyCap) : apr;
    const apyCapped = apyRaw > apyCap;

    const timeframeMultipliers = {
      '1D': 1,
      '7D': 7,
      '30D': 30,
      '1Y': 365,
    };

    const days = timeframeMultipliers[timeframe];
    const projectedYield = vaultNetDaily * days;
    const projectedReturn = userDailyYield * days;

    return {
      tvl,
      poolLiquidity: poolInfo?.liquidity,
      poolTick: poolInfo?.tick,
      volume,
      expectedHookFeeBps,
      poolFeeRate,
      hookFeesDaily,
      lpDonationDaily,
      poolFeesDaily,
      vaultGrossDaily,
      vaultNetDaily,
      aprPct: apr * 100,
      apyPct: apy * 100,
      apyCapped,
      projectedYield,
      deposit,
      projectedReturn,
      depositShareOfTVL,
      assumptions: {
        volatilityHitRatePct: volatilityRate * 100,
        vaultLiquiditySharePct: vaultLiquidityShare * 100,
        performanceFeePct: perfFeeRate * 100,
      },
    };
  }, [
    vaultStats,
    poolInfo,
    poolKey,
    performanceFeeBps,
    dailyVolumeUsd,
    volatilityHitRatePct,
    vaultLiquiditySharePct,
    depositAmount,
    timeframe,
  ]);

  const isBlockingLoad = !vaultStats && (isVaultStatsLoading || isPoolKeyLoading);
  const hasBlockingError = !vaultStats && (isVaultStatsError || isPoolKeyError);

  if (isBlockingLoad) {
    return (
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-8 text-center">
        <div className="text-zinc-400">Loading real-time pool data...</div>
      </div>
    );
  }

  if (hasBlockingError) {
    return (
      <div className="rounded-lg border border-amber-700/40 bg-amber-950/20 p-8 text-center">
        <div className="text-amber-300">Could not load live vault data right now.</div>
        <div className="mt-2 text-sm text-zinc-400">
          RPC may be slow or rate-limited. Try refresh in a few seconds.
        </div>
        {vaultStatsError ? (
          <div className="mt-2 text-xs text-zinc-500">{vaultStatsError.message}</div>
        ) : null}
      </div>
    );
  }

  if (!calculations) {
    return (
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-8 text-center">
        <div className="text-zinc-400">No vault data available yet.</div>
      </div>
    );
  }

  return (
    <div className="space-y-8">
      {/* Real Pool Data */}
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-6">
        <h2 className="mb-4 text-2xl font-semibold text-white">Live Pool Data</h2>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <div className="rounded bg-zinc-700/50 p-4">
            <div className="text-sm text-zinc-400">Pool Liquidity (raw L)</div>
            <div className="text-2xl font-bold text-white">
              {fmtCompact(calculations.poolLiquidity, 0)}
            </div>
          </div>
          <div className="rounded bg-zinc-700/50 p-4">
            <div className="text-sm text-zinc-400">Vault TVL</div>
            <div className="text-2xl font-bold text-white">
              ${fmtCompact(BigInt(Math.floor(calculations.tvl * 1e6)), 6)}
            </div>
          </div>
          <div className="rounded bg-zinc-700/50 p-4">
            <div className="text-sm text-zinc-400">Current Tick</div>
            <div className="text-2xl font-bold text-white">
              {calculations.poolTick?.toLocaleString() || '—'}
            </div>
          </div>
        </div>
      </div>

      {/* Fee Generation Math */}
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-6">
        <h2 className="mb-4 text-2xl font-semibold text-white">Fee Generation Mathematics</h2>

        <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
          <div className="space-y-3">
            <h3 className="text-lg font-medium text-zinc-300">Fee Structure</h3>
            <div className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span className="text-zinc-400">Expected Hook Fee:</span>
                <span className="text-white">{(calculations.expectedHookFeeBps / 100).toFixed(3)}%</span>
              </div>
              <div className="flex justify-between">
                <span className="text-zinc-400">Pool Fee:</span>
                <span className="text-white">{(calculations.poolFeeRate * 100).toFixed(3)}%</span>
              </div>
              <div className="flex justify-between font-medium">
                <span className="text-zinc-300">Volatile-swap share:</span>
                <span className="text-white">{calculations.assumptions.volatilityHitRatePct.toFixed(1)}%</span>
              </div>
            </div>
          </div>

          <div className="space-y-3">
            <h3 className="text-lg font-medium text-zinc-300">Revenue Split</h3>
            <div className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span className="text-zinc-400">Hook Fee to LP Donation:</span>
                <span className="text-white">80.0%</span>
              </div>
              <div className="flex justify-between">
                <span className="text-zinc-400">Hook Fee to Treasury:</span>
                <span className="text-white">20.0%</span>
              </div>
              <div className="flex justify-between">
                <span className="text-zinc-400">Vault share of active LP liquidity:</span>
                <span className="text-white">{calculations.assumptions.vaultLiquiditySharePct.toFixed(4)}%</span>
              </div>
            </div>
          </div>
        </div>

        <div className="rounded bg-zinc-700/30 p-4">
          <h3 className="mb-2 text-lg font-medium text-zinc-300">Daily Fee Generation</h3>
          <div className="mb-2 text-sm text-zinc-400">
            Scenario daily volume: ${calculations.volume.toLocaleString(undefined, { maximumFractionDigits: 0 })}
          </div>
          <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
            <div className="text-center">
              <div className="text-2xl font-bold text-green-400">
                ${calculations.hookFeesDaily.toLocaleString(undefined, { maximumFractionDigits: 0 })}
              </div>
              <div className="text-xs text-zinc-400">Hook Fees</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-blue-400">
                ${calculations.lpDonationDaily.toLocaleString(undefined, { maximumFractionDigits: 0 })}
              </div>
              <div className="text-xs text-zinc-400">LP Donation (from hook)</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-purple-400">
                ${calculations.vaultNetDaily.toLocaleString(undefined, { maximumFractionDigits: 0 })}
              </div>
              <div className="text-xs text-zinc-400">Vault Net Daily Yield</div>
            </div>
          </div>
        </div>
      </div>

      {/* APR/APY Calculator */}
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-6">
        <h2 className="mb-4 text-2xl font-semibold text-white">APR / APY Calculator</h2>

        <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
          <div className="rounded bg-zinc-700/30 p-4 text-center">
            <div className="mb-1 text-4xl font-bold text-green-400">
              {calculations.aprPct.toFixed(2)}%
            </div>
            <div className="text-zinc-400">APR (linear annualization on your deposit)</div>
          </div>
          <div className="rounded bg-zinc-700/30 p-4 text-center">
            <div className="mb-1 text-4xl font-bold text-blue-400">
              {calculations.apyPct.toFixed(2)}%{calculations.apyCapped ? '+' : ''}
            </div>
            <div className="text-zinc-400">
              APY (daily compounding{calculations.apyCapped ? ', capped at 3× APR' : ''})
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 gap-6 md:grid-cols-3">
          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-2">
              Deposit Amount (USDC)
            </label>
            <input
              type="number"
              value={depositAmount}
              onChange={(e) => setDepositAmount(e.target.value)}
              className="w-full rounded border border-zinc-600 bg-zinc-700 px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              placeholder="1000"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-2">
              Daily Volume (USD)
            </label>
            <input
              type="number"
              value={dailyVolumeUsd}
              onChange={(e) => setDailyVolumeUsd(e.target.value)}
              className="w-full rounded border border-zinc-600 bg-zinc-700 px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              placeholder="100000000"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-2">
              Timeframe
            </label>
            <select
              value={timeframe}
              onChange={(e) => setTimeframe(e.target.value as '1D' | '7D' | '30D' | '1Y')}
              className="w-full rounded border border-zinc-600 bg-zinc-700 px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
            >
              <option value="1D">1 Day</option>
              <option value="7D">7 Days</option>
              <option value="30D">30 Days</option>
              <option value="1Y">1 Year</option>
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-2">
              Swaps That Trigger The 1.5x Fee (%)
            </label>
            <input
              type="number"
              min="0"
              max="100"
              value={volatilityHitRatePct}
              onChange={(e) => setVolatilityHitRatePct(e.target.value)}
              className="w-full rounded border border-zinc-600 bg-zinc-700 px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
            />
            <p className="mt-2 text-xs leading-relaxed text-zinc-400">
              Of all swaps in your scenario, what percentage do you expect to hit the protocol&apos;s
              volatile-block multiplier and pay the higher hook fee?
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-2">
              Your Vault Share Of Active In-Range Liquidity (%)
            </label>
            <input
              type="number"
              min="0"
              max="100"
              value={vaultLiquiditySharePct}
              onChange={(e) => setVaultLiquiditySharePct(e.target.value)}
              className="w-full rounded border border-zinc-600 bg-zinc-700 px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
            />
            <p className="mt-2 text-xs leading-relaxed text-zinc-400">
              When the vault is actually in range, what share of the total fee-earning liquidity in
              that price band do you expect it to represent?
            </p>
          </div>
        </div>

        <div className="mt-6 rounded bg-zinc-700/30 p-4">
          <h3 className="mb-3 text-lg font-medium text-zinc-300">Return Projection</h3>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <div className="text-center">
              <div className="text-2xl font-bold text-white">
                ${calculations.deposit.toLocaleString()}
              </div>
              <div className="text-xs text-zinc-400">Deposit</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-green-400">
                ${calculations.projectedReturn.toFixed(2)}
              </div>
              <div className="text-xs text-zinc-400">Projected Yield</div>
            </div>
            <div className="text-center">
              <div className="text-2xl font-bold text-blue-400">
                ${(calculations.deposit + calculations.projectedReturn).toLocaleString()}
              </div>
              <div className="text-xs text-zinc-400">Final Value</div>
            </div>
          </div>
        </div>
      </div>

      {/* Assumptions & Methodology */}
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-6">
        <h2 className="mb-4 text-2xl font-semibold text-white">Methodology & Assumptions</h2>

        <div className="space-y-4 text-sm text-zinc-400">
          <div>
            <strong className="text-zinc-300">Expected Hook Fee:</strong> 25 bps base with 1.5x multiplier when volatile.
            Expected hook bps shown above is 25 * (1 + 0.5 * volatility hit rate).
            For scenario math we approximate swap-level fee basis with volume notional;
            on-chain fee basis is the absolute unspecified-currency delta per swap.
          </div>
          <div>
            <strong className="text-zinc-300">Fee Split Accuracy:</strong> 20/80 split applies only to hook fees in `FeeDistributor`.
            Pool fees are separate and do not pass through the 20/80 splitter.
          </div>
          <div>
            <strong className="text-zinc-300">Vault Capture:</strong> Vault earns only its share of active in-range liquidity,
            set here as {calculations.assumptions.vaultLiquiditySharePct.toFixed(4)}%.
          </div>
          <div>
            <strong className="text-zinc-300">Performance Fee:</strong> {calculations.assumptions.performanceFeePct.toFixed(2)}%
            from `performanceFeeBps` is applied to collected asset-token yield.
            This scenario assumes captured yield is realized in the asset token at collection time.
          </div>
          <div className="pt-2 border-t border-zinc-700">
            <em className="text-zinc-500">
              APR is linear annualization on your deposit:
              {' '}vaultNetDaily × deposit/(TVL+deposit) × 365 / deposit. APY is
              daily compounding of the same rate, capped at 3× APR for display
              sanity. These are scenario outputs, not guaranteed returns.
            </em>
          </div>
        </div>
      </div>
    </div>
  );
}