# trifola CLI

One line, nothing to install:

```bash
npx trifola
```

(Or straight from the clone, zero dependencies: `node cli/dist/trifola.js`.)

By default, it prints a one-screen, anonymized finding card for your local
Claude Code corpus: dead-skill counts, estimated prompt tax, and re-sent
context priced at API-equivalent rates. These estimates are not your plan bill.

## Options

```text
--json       Print the finding as machine-readable JSON.
--list-dead  Print never-fired skill IDs, one per line, for local pruning.
--help, -h   Print usage and exit.
```

Set `CLAUDE_CONFIG_DIR` to inspect a Claude Code config directory other than
`~/.claude`.

## Privacy

The CLI reads local files only. It opens no network connections, uploads
nothing, has no account, and sends no telemetry. `--list-dead` can print real
local skill names, so review that output before sharing it.

The macOS app has additional, documented network-capable features; this privacy
statement applies specifically to the npm CLI.

## License

MIT. See [LICENSE](LICENSE).
