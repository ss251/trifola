// The scan used to be a silent blank pause. Now it's a trefoil: three dots,
// one lobe lit at a time, with a live transcript count — on stderr, so stdout
// (the card, --json, pipes) stays byte-clean. No TTY on stderr → total no-op.
import { spinnerEnabled, stderrTeal, stderrDim } from "./style.js";
const FRAMES = ["◒", "◐", "◓", "◑"];
const TICK_MS = 120;
const noopSpinner = { update() { }, done() { } };
export function spin(initial) {
    if (!spinnerEnabled)
        return noopSpinner;
    let text = initial;
    let frame = 0;
    const err = process.stderr;
    const draw = () => {
        const glyph = stderrTeal(FRAMES[frame % FRAMES.length]);
        err.write(`\r\x1b[2K${glyph} ${stderrDim(text)}`);
    };
    err.write("\x1b[?25l");
    draw();
    const timer = setInterval(() => {
        frame += 1;
        draw();
    }, TICK_MS);
    timer.unref?.();
    const restore = () => {
        err.write("\r\x1b[2K\x1b[?25h");
    };
    const onSigint = () => {
        restore();
        process.exit(130);
    };
    process.once("SIGINT", onSigint);
    return {
        update(next) {
            text = next;
        },
        done() {
            clearInterval(timer);
            process.removeListener("SIGINT", onSigint);
            restore();
        },
    };
}
