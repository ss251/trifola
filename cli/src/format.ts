// Port of the display-formatting helpers in Sources/TrifolaKit/Models.swift
// (fmtUSD / fmtPct / fmtGrouped) — kept byte-for-byte compatible so a number
// this CLI prints reads the same way the macOS app would print it.

/** "$4.50" / "$215" / "$1.5k" — mirrors fmtUSD. */
export function fmtUSD(v: number): string {
  if (v >= 1000) return `$${(v / 1000).toFixed(1)}k`;
  if (v >= 10) return `$${Math.round(v)}`;
  return `$${v.toFixed(2)}`;
}

/** "34%" from a 0..1 fraction — mirrors fmtPct. */
export function fmtPct(v: number): string {
  return `${Math.round(v * 100)}%`;
}

/** "2,691" — full integer with thousands separators. Mirrors fmtGrouped:
 * receipts print exact counts, never a compact "2.7k". */
export function fmtCount(n: number): string {
  return n.toLocaleString("en-US");
}
