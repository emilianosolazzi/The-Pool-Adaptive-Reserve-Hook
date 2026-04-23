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
