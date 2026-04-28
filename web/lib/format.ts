import { formatUnits } from 'viem';

export const shortAddress = (a?: string) =>
  a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '';

export const fmtUnits = (
  v: bigint | undefined,
  decimals: number,
  maxFrac = 4,
): string => {
  if (v === undefined) return '—';
  const s = formatUnits(v, decimals);
  const [i, f = ''] = s.split('.');
  const intPart = Number(i).toLocaleString('en-US');
  if (!f) return intPart;
  const frac = f.slice(0, maxFrac).replace(/0+$/, '');
  return frac ? `${intPart}.${frac}` : intPart;
};

export const fmtCompact = (v: bigint | undefined, decimals: number): string => {
  if (v === undefined) return '—';
  const n = Number(formatUnits(v, decimals));
  if (!isFinite(n)) return '—';
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(2)}K`;
  return n.toFixed(2);
};

/**
 * Convert a Uniswap v4 sqrtPriceX96 into a human-readable price of token1
 * per token0, adjusted for token decimals. Returns NaN on bad input.
 */
export const sqrtPriceX96ToPrice = (
  sqrtPriceX96: bigint | undefined,
  decimals0: number,
  decimals1: number,
): number => {
  if (!sqrtPriceX96 || sqrtPriceX96 === 0n) return NaN;
  // (sqrt / 2^96)^2 → token1 / token0 in raw atomic units.
  // Use a high-precision intermediate via Number on the ratio of squares.
  const Q96 = 2n ** 96n;
  // Scale to keep precision: numerator * 1e18 / denominator
  const num = sqrtPriceX96 * sqrtPriceX96;
  const den = Q96 * Q96;
  const scaled = Number((num * 10n ** 18n) / den) / 1e18;
  return scaled * 10 ** (decimals0 - decimals1);
};

export const fmtPrice = (p: number, maxFrac = 2): string => {
  if (!Number.isFinite(p)) return '—';
  if (p === 0) return '0';
  const abs = Math.abs(p);
  if (abs >= 1) return p.toLocaleString('en-US', { maximumFractionDigits: maxFrac });
  // sub-1 — show enough precision
  return p.toLocaleString('en-US', { maximumFractionDigits: 6 });
};

export const fmtBps = (bps: bigint | number | undefined): string => {
  if (bps === undefined) return '—';
  const n = typeof bps === 'bigint' ? Number(bps) : bps;
  if (!Number.isFinite(n)) return '—';
  const sign = n > 0 ? '+' : '';
  return `${sign}${n.toFixed(0)} bps`;
};

export const fmtCountdown = (target: bigint | number | undefined): string => {
  if (!target) return '—';
  const t = typeof target === 'bigint' ? Number(target) : target;
  const now = Math.floor(Date.now() / 1000);
  const delta = t - now;
  if (delta <= 0) return 'expired';
  if (delta < 60) return `${delta}s`;
  if (delta < 3600) return `${Math.floor(delta / 60)}m ${delta % 60}s`;
  if (delta < 86400) {
    const h = Math.floor(delta / 3600);
    const m = Math.floor((delta % 3600) / 60);
    return `${h}h ${m}m`;
  }
  const d = Math.floor(delta / 86400);
  const h = Math.floor((delta % 86400) / 3600);
  return `${d}d ${h}h`;
};
