// The trefoil-aperture brand mark, rendered as truecolor half-blocks.
// Computed, not hand-drawn: three cream lobes, a dark core, a teal pupil —
// the same geometry as the app icon. Only ever printed in styled mode.
const CREAM = [239, 231, 210];
const CORE = [22, 23, 18];
const TEAL = [66, 153, 132];
const W = 26;
const H = 14; // pixels; two per output row via ▀
// Painted in order — later circles cover earlier ones (core over lobes, pupil over core).
const SHAPES = [
    { cx: 13, cy: 3.9, r: 3.9, color: CREAM },
    { cx: 8.3, cy: 9.5, r: 3.9, color: CREAM },
    { cx: 17.7, cy: 9.5, r: 3.9, color: CREAM },
    { cx: 13, cy: 7.4, r: 2.9, color: CORE },
    { cx: 13, cy: 7.4, r: 1.5, color: TEAL },
];
function pixel(x, y) {
    let hit = null;
    for (const c of SHAPES) {
        const dx = x + 0.5 - c.cx;
        const dy = y + 0.5 - c.cy;
        if (dx * dx + dy * dy <= c.r * c.r)
            hit = c.color;
    }
    return hit;
}
const fg = ([r, g, b]) => `\x1b[38;2;${r};${g};${b}m`;
const bg = ([r, g, b]) => `\x1b[48;2;${r};${g};${b}m`;
const RESET = "\x1b[0m";
/** The mark as terminal art — H/2 rows of half-block cells, transparent ground. */
export function renderMark(indent = "") {
    const rows = [];
    for (let y = 0; y < H; y += 2) {
        let row = indent;
        for (let x = 0; x < W; x += 1) {
            const top = pixel(x, y);
            const bot = pixel(x, y + 1);
            if (!top && !bot)
                row += " ";
            else if (top && bot)
                row += `${fg(top)}${bg(bot)}▀${RESET}`;
            else if (top)
                row += `${fg(top)}▀${RESET}`;
            else
                row += `${fg(bot)}▄${RESET}`;
        }
        rows.push(row.replace(/ +$/, ""));
    }
    return rows.join("\n");
}
