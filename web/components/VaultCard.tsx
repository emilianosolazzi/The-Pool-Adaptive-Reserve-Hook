'use client';

import { useMemo, useState } from 'react';
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { arbitrumSepolia } from 'wagmi/chains';
import { erc20Abi, vaultAbi } from '@/lib/abis';
import { fmtUnits } from '@/lib/format';
import { type Deployment } from '@/lib/deployments';
import { maxUint256, parseUnits, type Address } from 'viem';

type Tab = 'deposit' | 'withdraw';

const WITHDRAW_BUFFER_BPS = 500n;
const BPS_DENOMINATOR = 10_000n;

export function VaultCard({ deployment, chainId }: { deployment: Deployment; chainId: number }) {
  const { address } = useAccount();
  const [tab, setTab] = useState<Tab>('deposit');
  const [amount, setAmount] = useState('');

  const vault = deployment.vault as Address | undefined;
  const asset = deployment.asset as Address | undefined;
  const dec = deployment.assetDecimals;
  const ready = Boolean(vault && asset);
  const txExplorerBase =
    chainId === arbitrumSepolia.id ? 'https://sepolia.arbiscan.io' : 'https://arbiscan.io';

  const { data: wallet, refetch: refetchWallet } = useReadContracts({
    contracts:
      ready && address
        ? ([
            { address: asset!, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId },
            { address: asset!, abi: erc20Abi, functionName: 'allowance', args: [address, vault!], chainId },
            { address: vault!, abi: vaultAbi, functionName: 'balanceOf', args: [address], chainId },
            { address: vault!, abi: vaultAbi, functionName: 'previewRedeem', args: [0n], chainId },
          ] as const)
        : [],
    query: { enabled: ready && Boolean(address), refetchInterval: 15_000 },
  });

  const assetBalance = wallet?.[0]?.result as bigint | undefined;
  const allowance = wallet?.[1]?.result as bigint | undefined;
  const shares = wallet?.[2]?.result as bigint | undefined;

  const { data: rawShareDecimals } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'decimals',
    chainId,
    query: { enabled: Boolean(vault), refetchInterval: 60_000 },
  });

  const shareDecimals = rawShareDecimals as number | undefined;

  const parsed = useMemo(() => {
    if (!amount) return 0n;
    try {
      if (tab === 'withdraw') {
        if (shareDecimals === undefined) return 0n;
        return parseUnits(amount, shareDecimals);
      }
      return parseUnits(amount, dec);
    } catch {
      return 0n;
    }
  }, [amount, dec, shareDecimals, tab]);

  const conservativeMaxShares = useMemo(() => {
    if (shares === undefined || shares <= 0n) return 0n;
    const buffered = shares * (BPS_DENOMINATOR - WITHDRAW_BUFFER_BPS) / BPS_DENOMINATOR;
    return buffered > 0n ? buffered : shares;
  }, [shares]);

  const { data: conservativeRedeemPreview } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'previewRedeem',
    args: conservativeMaxShares > 0n ? [conservativeMaxShares] : undefined,
    chainId,
    query: { enabled: Boolean(vault && conservativeMaxShares > 0n), refetchInterval: 15_000 },
  });

  const { data: inputRedeemPreview } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'previewRedeem',
    args: tab === 'withdraw' && parsed > 0n ? [parsed] : undefined,
    chainId,
    query: { enabled: Boolean(vault && tab === 'withdraw' && parsed > 0n), refetchInterval: 15_000 },
  });

  const needsApproval =
    tab === 'deposit' && parsed > 0n && (allowance ?? 0n) < parsed;

  const exceedsConservativeWithdraw =
    tab === 'withdraw' && conservativeMaxShares > 0n && parsed > conservativeMaxShares;

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  if (isSuccess && !isPending) {
    // one-shot refresh
    queueMicrotask(() => {
      refetchWallet();
      reset();
      setAmount('');
    });
  }

  const onApprove = () => {
    if (!asset || !vault) return;
    writeContract({
      address: asset,
      abi: erc20Abi,
      functionName: 'approve',
      args: [vault, maxUint256],
    });
  };

  const onSubmit = () => {
    if (!vault || !address || parsed <= 0n) return;
    if (tab === 'deposit') {
      writeContract({
        address: vault,
        abi: vaultAbi,
        functionName: 'deposit',
        args: [parsed, address],
      });
    } else {
      writeContract({
        address: vault,
        abi: vaultAbi,
        functionName: 'redeem',
        args: [parsed, address, address],
      });
    }
  };

  const onMax = () => {
    if (tab === 'deposit' && assetBalance !== undefined) {
      setAmount(fmtUnits(assetBalance, dec, dec));
    } else if (tab === 'withdraw' && conservativeMaxShares > 0n && shareDecimals !== undefined) {
      setAmount(fmtUnits(conservativeMaxShares, shareDecimals, shareDecimals));
    }
  };

  const disabled =
    !ready ||
    !address ||
    parsed <= 0n ||
    isPending ||
    isMining ||
    (tab === 'withdraw' && shareDecimals === undefined) ||
    (tab === 'deposit' && assetBalance !== undefined && parsed > assetBalance) ||
    (tab === 'withdraw' && shares !== undefined && parsed > shares) ||
    exceedsConservativeWithdraw;

  return (
    <div className="card shadow-glow">
      <div className="flex items-center justify-between border-b border-white/5 p-5">
        <div>
          <div className="stat-label">Vault</div>
          <div className="mt-1 text-lg font-semibold text-white">
            {deployment.pairSymbol} · deposit {deployment.assetSymbol}
          </div>
        </div>
        <div className="flex rounded-xl border border-white/10 bg-ink-800/70 p-1 text-xs">
          {(['deposit', 'withdraw'] as const).map((t) => (
            <button
              key={t}
              onClick={() => {
                setTab(t);
                setAmount('');
              }}
              className={`rounded-lg px-3 py-1.5 capitalize transition ${
                tab === t
                  ? 'bg-accent-500 text-ink-950 font-semibold'
                  : 'text-zinc-400 hover:text-white'
              }`}
            >
              {t}
            </button>
          ))}
        </div>
      </div>

      {!ready ? (
        <div className="p-6 text-sm text-zinc-400">
          Vault address is not configured for this chain. Set{' '}
          <code className="rounded bg-white/5 px-1.5 py-0.5 font-mono">
            NEXT_PUBLIC_VAULT_ARB_ONE
          </code>{' '}
          in Vercel environment variables and redeploy.
        </div>
      ) : (
        <div className="space-y-4 p-5">
          <div className="flex items-center justify-between text-xs text-zinc-500">
            <span>{tab === 'deposit' ? 'Amount' : 'Shares'}</span>
            <span>
              {tab === 'deposit'
                ? `Balance: ${fmtUnits(assetBalance, dec, 4)} ${deployment.assetSymbol}`
                : `Shares: ${shareDecimals === undefined ? '—' : fmtUnits(shares, shareDecimals, 6)}`}
            </span>
          </div>

          <div className="relative">
            <input
              className="input pr-16"
              placeholder="0.0"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
            />
            <button
              onClick={onMax}
              className="absolute right-2 top-1/2 -translate-y-1/2 rounded-md border border-white/10 bg-white/5 px-2 py-1 text-[11px] font-semibold text-zinc-300 hover:bg-white/10"
            >
              MAX
            </button>
          </div>

          {tab === 'withdraw' && shares !== undefined && shares > 0n && (
            <div className="space-y-1 rounded-lg border border-white/5 bg-ink-800/40 px-3 py-2 text-xs text-zinc-400">
              <div>
                Conservative max -&gt; ~{fmtUnits(conservativeRedeemPreview as bigint | undefined, dec, 4)}{' '}
                {deployment.assetSymbol}
              </div>
              {parsed > 0n && (
                <div>
                  This redeem -&gt; ~{fmtUnits(inputRedeemPreview as bigint | undefined, dec, 4)}{' '}
                  {deployment.assetSymbol}
                </div>
              )}
              {exceedsConservativeWithdraw && (
                <div className="text-amber-300">
                  Use MAX to leave a 5% execution buffer.
                </div>
              )}
            </div>
          )}

          {!address ? (
            <div className="rounded-lg border border-white/10 bg-white/5 px-3 py-3 text-center text-sm text-zinc-400">
              Connect a wallet to {tab}.
            </div>
          ) : needsApproval ? (
            <button onClick={onApprove} disabled={isPending || isMining} className="btn-primary w-full">
              {isPending || isMining ? 'Approving…' : `Approve ${deployment.assetSymbol}`}
            </button>
          ) : (
            <button onClick={onSubmit} disabled={disabled} className="btn-primary w-full">
              {isPending || isMining
                ? tab === 'deposit'
                  ? 'Depositing…'
                  : 'Redeeming…'
                : tab === 'deposit'
                  ? `Deposit ${deployment.assetSymbol}`
                  : 'Redeem shares'}
            </button>
          )}

          {txHash && (
            <a
              href={`${txExplorerBase}/tx/${txHash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="block text-center text-xs text-accent-400 hover:underline"
            >
              View transaction ↗
            </a>
          )}

          <div className="pt-1 text-[11px] text-zinc-600">
            Deposits mint ERC-4626 shares. Share price rises as hook fees accrue;
            anyone can call compound() to harvest into the active range.
          </div>
        </div>
      )}
    </div>
  );
}
