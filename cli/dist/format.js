// Port of the display-formatting helpers in Sources/TrifolaKit/Models.swift
// (fmtUSD / fmtPct / fmtGrouped) — kept byte-for-byte compatible so a number
// this CLI prints reads the same way the macOS app would print it.
/** "$4.50" / "$215" / "$1.5k" — mirrors fmtUSD. */
export function fmtUSD(v) {
    if (v >= 1000)
        return `$${(v / 1000).toFixed(1)}k`;
    if (v >= 10)
        return `$${Math.round(v)}`;
    return `$${v.toFixed(2)}`;
}
/** Preserve tiny per-session estimates that ordinary cents formatting hides. */
export function fmtTinyUSD(v) {
    if (v === 0 || Math.abs(v) >= 0.01)
        return fmtUSD(v);
    return `$${v.toFixed(6).replace(/0+$/, "").replace(/\.$/, "")}`;
}
/** "34%" from a 0..1 fraction — mirrors fmtPct. */
export function fmtPct(v) {
    return `${Math.round(v * 100)}%`;
}
/** "2,691" — full integer with thousands separators. Mirrors fmtGrouped:
 * receipts print exact counts, never a compact "2.7k". */
export function fmtCount(n) {
    return n.toLocaleString("en-US");
}
/** "950" / "1.5k" / "2.5M" / "12.6B" — mirrors Swift fmtTokens. */
export function fmtTokens(n) {
    if (n >= 1_000_000_000)
        return `${(n / 1_000_000_000).toFixed(1)}B`;
    if (n >= 1_000_000)
        return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000)
        return `${(n / 1_000).toFixed(1)}k`;
    return Math.trunc(n).toString();
}
