// The scan used to be a silent blank pause. Now it's a trefoil: three dots,
// one lobe lit at a time, with a live transcript count — on stderr, so stdout
// (the card, --json, pipes) stays byte-clean. No TTY on stderr → total no-op.

import { spinnerEnabled, stderrTeal, stderrDim } from "./style.js";

const LOBES = [0, 1, 2, 1] as const;
const TICK_MS = 140;

export interface Spinner {
  update(text: string): void;
  done(): void;
}

const noopSpinner: Spinner = { update() {}, done() {} };

export function spin(initial: string): Spinner {
  if (!spinnerEnabled) return noopSpinner;

  let text = initial;
  let frame = 0;
  const err = process.stderr;

  const draw = (): void => {
    const lit = LOBES[frame % LOBES.length];
    const dots = [0, 1, 2]
      .map((i) => (i === lit ? stderrTeal("●") : stderrDim("∙")))
      .join("");
    err.write(`\r\x1b[2K${dots} ${stderrDim(text)}`);
  };

  err.write("\x1b[?25l");
  draw();
  const timer = setInterval(() => {
    frame += 1;
    draw();
  }, TICK_MS);
  timer.unref?.();

  const restore = (): void => {
    err.write("\r\x1b[2K\x1b[?25h");
  };
  const onSigint = (): void => {
    restore();
    process.exit(130);
  };
  process.once("SIGINT", onSigint);

  return {
    update(next: string) {
      text = next;
    },
    done() {
      clearInterval(timer);
      process.removeListener("SIGINT", onSigint);
      restore();
    },
  };
}
