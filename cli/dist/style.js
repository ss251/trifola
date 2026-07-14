// Terminal character — colors gated hard: a pipe, NO_COLOR, or a dumb TERM
// gets byte-identical plain output. Styling is presentation only; the card's
// text (and every test that reads it) never changes.
const stdoutStyled = process.stdout.isTTY === true &&
    process.env.NO_COLOR === undefined &&
    process.env.TERM !== "dumb";
const stderrStyled = process.stderr.isTTY === true &&
    process.env.NO_COLOR === undefined &&
    process.env.TERM !== "dumb";
export const styled = stdoutStyled;
export const spinnerEnabled = stderrStyled;
function wrap(open, close) {
    return (s) => (stdoutStyled ? open + s + close : s);
}
// Brand palette — the app's own dark-mode values.
export const teal = wrap("\x1b[38;2;66;153;132m", "\x1b[39m");
export const cream = wrap("\x1b[38;2;239;231;210m", "\x1b[39m");
export const red = wrap("\x1b[38;2;224;102;107m", "\x1b[39m");
export const bold = wrap("\x1b[1m", "\x1b[22m");
export const dim = wrap("\x1b[2m", "\x1b[22m");
// stderr variants for the spinner (independent of stdout's TTY-ness).
export const stderrTeal = (s) => stderrStyled ? "\x1b[38;2;66;153;132m" + s + "\x1b[39m" : s;
export const stderrDim = (s) => stderrStyled ? "\x1b[2m" + s + "\x1b[22m" : s;
