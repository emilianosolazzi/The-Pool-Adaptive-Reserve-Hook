'use client';

/**
 * SwapPanel — bidirectional WETH/USDC swap routed directly through The-Pool's
 * Uniswap v4 PoolKey via the canonical Universal Router.
 *
 * Yield attribution: while quoting, also shows the user (if they hold vault
 * shares) the share of this swap's hook fee that flows back into THEIR
 * vault position. This is the retention mechanic.
 *
 * Network gating: only renders the live form on Arbitrum One (where SWAP_INFRA
 * is defined). Falls back to a notice on other chains.
 */

import { useEffect, useMemo, useState } from 'react';
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useSimulateContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { arbitrum } from 'wagmi/chains';
import { parseUnits, formatUnits, type Address } from 'viem';
import {
  erc20Abi,
  vaultAbi,
  universalRouterAbi,
  v4QuoterAbi,
  permit2Abi,
} from '@/lib/abis';
import { fmtUnits } from '@/lib/format';
import {
  PERMIT2,
  getSwapInfra,
  type Deployment,
} from '@/lib/deployments';
import {
  encodeV4ExactInSingle,
  makeQuoteParams,
  applySlippage,
  MAX_UINT_160,
  defaultPermit2Expiry,
  defaultSwapDeadline,
  type SwapPlan,
} from '@/lib/swap';

const HOOK_FEE_BPS = 25n;          // DynamicFeeHook base hook fee
const TREASURY_SHARE_BPS = 2000n;  // FeeDistributor default 20%
const LP_DONATION_BPS = 10_000n - TREASURY_SHARE_BPS;
const SLIPPAGE_PRESETS = [10, 50, 100]; // 0.1% / 0.5% / 1.0%

interface SwapPanelProps {
  deployment: Deployment;
  chainId: number;
  explorerBase: string;
}

export function SwapPanel({ deployment, chainId, explorerBase }: SwapPanelProps) {
  const { address } = useAccount();
  const infra = getSwapInfra(chainId as 42161);
  const usdc = deployment.asset as Address | undefined;
  const weth = infra?.weth;
  const hook = deployment.hook as Address | undefined;
  const vault = deployment.vault as Address | undefined;

  const supported = Boolean(infra && chainId === arbitrum.id && usdc && weth && hook && vault);

  // Direction: `inputIsUSDC` true = USDC -> WETH (zeroForOne=false because WETH=currency0)
  // currency0 = WETH (lower address), currency1 = USDC.
  const [inputIsUSDC, setInputIsUSDC] = useState(true);
  const [amount, setAmount] = useState('');
  const [slippageBps, setSlippageBps] = useState(50);
  const [step, setStep] = useState<'idle' | 'approveErc20' | 'approvePermit2' | 'swap'>('idle');

  // Resolve token addresses defensively so hooks can run unconditionally.
  // When `supported` is false we feed harmless zero-value reads through wagmi
  // by gating with `query.enabled`.
  const ZERO = '0x0000000000000000000000000000000000000000' as Address;
  const inputToken: Address = inputIsUSDC ? (usdc ?? ZERO) : (weth ?? ZERO);
  const outputToken: Address = inputIsUSDC ? (weth ?? ZERO) : (usdc ?? ZERO);
  const inputDecimals = inputIsUSDC ? 6 : 18;
  const outputDecimals = inputIsUSDC ? 18 : 6;
  const inputSymbol = inputIsUSDC ? 'USDC' : 'WETH';
  const outputSymbol = inputIsUSDC ? 'WETH' : 'USDC';

  // currency0 < currency1 by sort. WETH (0x82af…) < USDC (0xaf88…), so:
  //   USDC -> WETH means input=currency1 -> output=currency0  => zeroForOne=false
  //   WETH -> USDC means input=currency0 -> output=currency1  => zeroForOne=true
  const zeroForOne = !inputIsUSDC;

  const poolKey = useMemo(
    () => ({
      currency0: weth ?? ZERO,
      currency1: usdc ?? ZERO,
      fee: 500,
      tickSpacing: 10,
      hooks: hook ?? ZERO,
    }),
    [weth, usdc, hook],
  );

  const amountIn = useMemo(() => {
    if (!amount) return 0n;
    try {
      return parseUnits(amount, inputDecimals);
    } catch {
      return 0n;
    }
  }, [amount, inputDecimals]);

  // ── Reads: balances, allowances, vault shares ─────────────────────────────
  const { data: reads, refetch: refetchReads } = useReadContracts({
    contracts:
      supported && address && infra && vault
        ? ([
            { address: inputToken, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId },
            { address: outputToken, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId },
            { address: inputToken, abi: erc20Abi, functionName: 'allowance', args: [address, PERMIT2], chainId },
            { address: PERMIT2, abi: permit2Abi, functionName: 'allowance', args: [address, inputToken, infra.universalRouter], chainId },
            { address: vault, abi: vaultAbi, functionName: 'balanceOf', args: [address], chainId },
            { address: vault, abi: vaultAbi, functionName: 'totalSupply', chainId },
            { address: vault, abi: vaultAbi, functionName: 'getVaultStats', chainId },
          ] as const)
        : [],
    query: { enabled: supported && Boolean(address), refetchInterval: 15_000 },
  });

  const inBalance = reads?.[0]?.result as bigint | undefined;
  const outBalance = reads?.[1]?.result as bigint | undefined;
  const erc20Allow = reads?.[2]?.result as bigint | undefined;
  const permit2Tuple = reads?.[3]?.result as readonly [bigint, number, number] | undefined;
  const userShares = reads?.[4]?.result as bigint | undefined;
  const totalShares = reads?.[5]?.result as bigint | undefined;
  const vaultStats = reads?.[6]?.result as
    | readonly [bigint, bigint, bigint, bigint, bigint, string]
    | undefined;
  const lifetimeYield = vaultStats?.[4]; // yieldColl

  // ── Quote ─────────────────────────────────────────────────────────────────
  const quoteEnabled = supported && amountIn > 0n;
  const { data: quoteSim, error: quoteErr } = useSimulateContract({
    address: infra?.v4Quoter,
    abi: v4QuoterAbi,
    functionName: 'quoteExactInputSingle',
    args: quoteEnabled ? [makeQuoteParams({ poolKey, zeroForOne, amountIn })] : undefined,
    chainId,
    query: { enabled: quoteEnabled, refetchInterval: 10_000 },
  });

  const quoted = quoteSim?.result as readonly [bigint, bigint] | undefined;
  const amountOut = quoted?.[0];
  const minOut = useMemo(
    () => (amountOut ? applySlippage(amountOut, slippageBps) : 0n),
    [amountOut, slippageBps],
  );

  // ── Yield attribution math ────────────────────────────────────────────────
  const hookFee = (amountIn * HOOK_FEE_BPS) / 10_000n;
  const treasuryAmount = (hookFee * TREASURY_SHARE_BPS) / 10_000n;
  const lpDonation = hookFee - treasuryAmount;
  const userShareOfDonation =
    userShares && totalShares && totalShares > 0n
      ? (lpDonation * userShares) / totalShares
      : 0n;
  const userLifetimeFees =
    lifetimeYield !== undefined && userShares && totalShares && totalShares > 0n
      ? (lifetimeYield * userShares) / totalShares
      : 0n;

  // ── Approval flow ─────────────────────────────────────────────────────────
  const needsErc20Approve = (erc20Allow ?? 0n) < amountIn;
  const permit2Allowance = permit2Tuple?.[0] ?? 0n;
  const permit2Expiration = permit2Tuple?.[1] ?? 0;
  const nowSec = Math.floor(Date.now() / 1000);
  const needsPermit2Approve =
    permit2Allowance < amountIn || permit2Expiration <= nowSec;

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  // Refresh after tx
  useEffect(() => {
    if (isSuccess) {
      refetchReads();
      const t = setTimeout(() => reset(), 1500);
      return () => clearTimeout(t);
    }
  }, [isSuccess, refetchReads, reset]);

  if (!supported || !infra) {
    return (
      <section id="swap" className="mx-auto max-w-3xl px-4 py-12">
        <div className="card p-6 text-sm text-zinc-300">
          Direct swap is live on Arbitrum One only. Connect to Arbitrum One to swap
          through the pool&apos;s hook.
        </div>
      </section>
    );
  }

  const onApproveErc20 = () => {
    setStep('approveErc20');
    writeContract({
      address: inputToken,
      abi: erc20Abi,
      functionName: 'approve',
      args: [PERMIT2, MAX_UINT_160],
      chainId,
    });
  };

  const onApprovePermit2 = () => {
    setStep('approvePermit2');
    writeContract({
      address: PERMIT2,
      abi: permit2Abi,
      functionName: 'approve',
      args: [inputToken, infra.universalRouter, MAX_UINT_160, defaultPermit2Expiry()],
      chainId,
    });
  };

  const onSwap = () => {
    if (amountIn === 0n || minOut === 0n) return;
    setStep('swap');
    const plan: SwapPlan = {
      poolKey,
      zeroForOne,
      amountIn,
      amountOutMinimum: minOut,
      currencyIn: inputToken,
      currencyOut: outputToken,
    };
    const { commands, inputs } = encodeV4ExactInSingle(plan);
    writeContract({
      address: infra.universalRouter,
      abi: universalRouterAbi,
      functionName: 'execute',
      args: [commands, inputs, defaultSwapDeadline()],
      chainId,
    });
  };

  const onMax = () => {
    if (inBalance === undefined) return;
    setAmount(formatUnits(inBalance, inputDecimals));
  };

  const flip = () => {
    setInputIsUSDC((v) => !v);
    setAmount('');
  };

  const txAction = needsErc20Approve
    ? { label: `Approve ${inputSymbol} for Permit2`, onClick: onApproveErc20 }
    : needsPermit2Approve
      ? { label: 'Approve Permit2 for Universal Router', onClick: onApprovePermit2 }
      : { label: `Swap ${inputSymbol} for ${outputSymbol}`, onClick: onSwap };

  const swapDisabled =
    amountIn === 0n ||
    !amountOut ||
    isPending ||
    isMining ||
    (inBalance !== undefined && amountIn > inBalance);

  return (
    <section id="swap" className="mx-auto max-w-3xl px-4 py-12">
      <div className="mb-6">
        <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
          Swap directly through the hook
        </h2>
        <p className="mt-2 text-zinc-400 text-sm md:text-base">
          Routes through The-Pool&apos;s own Uniswap v4 PoolKey. 80% of every hook fee
          flows back to in-range LPs (including you, if you&apos;ve deposited).
        </p>
      </div>

      <div className="card p-5 md:p-6">
        {/* Input row */}
        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>From</span>
            <span>
              Balance:{' '}
              {inBalance !== undefined ? fmtUnits(inBalance, inputDecimals, inputIsUSDC ? 2 : 4) : '—'}{' '}
              {inputSymbol}
            </span>
          </div>
          <div className="mt-2 flex items-center gap-3">
            <input
              type="text"
              inputMode="decimal"
              placeholder="0.0"
              value={amount}
              onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
              className="flex-1 bg-transparent text-2xl font-medium text-white outline-none"
            />
            <button
              type="button"
              onClick={onMax}
              className="rounded-lg border border-white/10 px-2 py-1 text-xs text-zinc-300 hover:border-white/20"
            >
              MAX
            </button>
            <span className="rounded-xl bg-white/5 px-3 py-2 text-sm font-semibold text-white">
              {inputSymbol}
            </span>
          </div>
        </div>

        {/* Flip */}
        <div className="my-2 flex justify-center">
          <button
            type="button"
            onClick={flip}
            aria-label="Reverse swap direction"
            className="rounded-xl border border-white/10 bg-zinc-900 px-3 py-1.5 text-zinc-300 hover:border-accent-400/40 hover:text-white"
          >
            ↕
          </button>
        </div>

        {/* Output row */}
        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>To (estimated)</span>
            <span>
              Balance:{' '}
              {outBalance !== undefined ? fmtUnits(outBalance, outputDecimals, inputIsUSDC ? 4 : 2) : '—'}{' '}
              {outputSymbol}
            </span>
          </div>
          <div className="mt-2 flex items-center gap-3">
            <span className="flex-1 text-2xl font-medium text-white">
              {amountOut ? fmtUnits(amountOut, outputDecimals, inputIsUSDC ? 6 : 2) : '0.0'}
            </span>
            <span className="rounded-xl bg-white/5 px-3 py-2 text-sm font-semibold text-white">
              {outputSymbol}
            </span>
          </div>
          {minOut > 0n ? (
            <div className="mt-2 text-xs text-zinc-500">
              Minimum received: {fmtUnits(minOut, outputDecimals, inputIsUSDC ? 6 : 2)} {outputSymbol}
            </div>
          ) : null}
          {quoteErr && amountIn > 0n ? (
            <div className="mt-2 text-xs text-rose-300">
              Quote failed — pool may have insufficient liquidity for this size.
            </div>
          ) : null}
        </div>

        {/* Slippage */}
        <div className="mt-4 flex items-center justify-between text-xs text-zinc-400">
          <span>Slippage tolerance</span>
          <div className="flex gap-1">
            {SLIPPAGE_PRESETS.map((bps) => (
              <button
                key={bps}
                type="button"
                onClick={() => setSlippageBps(bps)}
                className={`rounded-md border px-2 py-1 ${
                  slippageBps === bps
                    ? 'border-accent-400/60 bg-accent-500/10 text-white'
                    : 'border-white/10 text-zinc-300 hover:border-white/20'
                }`}
              >
                {(bps / 100).toFixed(bps < 100 ? 1 : 0)}%
              </button>
            ))}
          </div>
        </div>

        {/* Yield attribution panel */}
        {amountIn > 0n ? (
          <div className="mt-4 rounded-2xl border border-accent-500/20 bg-accent-500/5 p-4 text-sm">
            <div className="font-semibold text-white mb-2">Where this swap&apos;s fee goes</div>
            <div className="grid gap-1 text-zinc-300">
              <Row
                label="Hook fee on this swap (0.25%)"
                value={`${fmtUnits(hookFee, inputDecimals, inputIsUSDC ? 4 : 6)} ${inputSymbol}`}
              />
              <Row
                label="↳ Treasury (20%)"
                value={`${fmtUnits(treasuryAmount, inputDecimals, inputIsUSDC ? 4 : 6)} ${inputSymbol}`}
                muted
              />
              <Row
                label="↳ LP donation (80%)"
                value={`${fmtUnits(lpDonation, inputDecimals, inputIsUSDC ? 4 : 6)} ${inputSymbol}`}
                muted
              />
            </div>
            {userShares && userShares > 0n ? (
              <div className="mt-3 border-t border-white/10 pt-3">
                <div className="font-semibold text-white mb-1">Your stake&apos;s cut</div>
                <Row
                  label={`Your vault shares (${
                    totalShares && totalShares > 0n
                      ? ((Number(userShares) / Number(totalShares)) * 100).toFixed(4)
                      : '0'
                  }% of vault)`}
                  value={`${fmtUnits(userShares, 18, 4)}`}
                />
                <Row
                  label="≈ Your share of this swap's donation"
                  value={`${fmtUnits(userShareOfDonation, inputDecimals, inputIsUSDC ? 6 : 8)} ${inputSymbol}`}
                  highlight
                />
                <Row
                  label="Lifetime fees attributed to your shares"
                  value={`${fmtUnits(userLifetimeFees, deployment.assetDecimals, 4)} ${deployment.assetSymbol}`}
                  muted
                />
                <p className="mt-2 text-xs text-zinc-400">
                  Each swap routed here grows the vault&apos;s share price. The number above
                  is your slice; it updates after this transaction confirms.
                </p>
              </div>
            ) : (
              <div className="mt-3 border-t border-white/10 pt-3 text-xs text-zinc-400">
                Hold vault shares to capture a slice of every swap&apos;s LP donation.{' '}
                <a href="#vault" className="text-accent-300 hover:underline">
                  Deposit USDC →
                </a>
              </div>
            )}
          </div>
        ) : null}

        {/* Action button */}
        <div className="mt-5">
          <button
            type="button"
            onClick={txAction.onClick}
            disabled={swapDisabled && !needsErc20Approve && !needsPermit2Approve}
            className="btn-primary w-full justify-center disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isPending || isMining
              ? step === 'approveErc20'
                ? 'Approving…'
                : step === 'approvePermit2'
                  ? 'Setting Permit2…'
                  : 'Swapping…'
              : address
                ? txAction.label
                : 'Connect wallet'}
          </button>
          {txHash ? (
            <a
              href={`${explorerBase}/tx/${txHash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="mt-2 block text-center text-xs text-accent-300 hover:underline"
            >
              View transaction on Arbiscan ↗
            </a>
          ) : null}
        </div>
      </div>
    </section>
  );
}

function Row({
  label,
  value,
  muted,
  highlight,
}: {
  label: string;
  value: string;
  muted?: boolean;
  highlight?: boolean;
}) {
  return (
    <div className="flex items-center justify-between">
      <span className={muted ? 'text-zinc-400' : 'text-zinc-300'}>{label}</span>
      <span
        className={`font-mono ${
          highlight ? 'text-accent-200 font-semibold' : muted ? 'text-zinc-300' : 'text-white'
        }`}
      >
        {value}
      </span>
    </div>
  );
}
