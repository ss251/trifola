#!/usr/bin/env bash
# secret-scan.sh — personal-PII/private-path lint for the public tree.
# This is not a credential scanner. Run before every push; wired into CI.
#
# Scans the whole repo except .git and this script itself. Exits non-zero on any hit.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"

# Personal identifiers, private hostnames, and every private project name from the
# source repo. `ss251` is allowed only inside LICENSE / credits; everything else is banned.
PATTERNS=(
  'thescoho'
  'devcube'
  'saileshs-macbook'
  '\brally\b'
  'crypto-income-system'
  'aztec-bounty'
  'slack-hackathon'
  'reddit-hackathon'
  'okx-ai-genesis'
  '\bforeman\b'
  'magic-cabinet'
  '\bfable\b'
  '\bFable\b'
  'MissionControl'
  'ClaudeMissionControl'
  'com\.thescoho'
  # v1 scope — the user's personal/private tooling must be genericized out of the
  # public tree. The probe registry ships GENERIC defaults only (claude, skills,
  # mcp-servers, hooks, plugins). These names must not appear anywhere in Sources.
  'pxpipe'
  'gbrain'
  'openclaw'
  '\blavish\b'
  '\bcmux\b'
  'browser-use'
  'browserUse'
  'CloudBrowser'
  'PxpipeScreen'
  # personal demo/seed markers (author's tools, crypto/video skills, projects) —
  # the render seed data must use generic software names only.
  'agent-reach'
  '\btermgrid\b'
  'hyperframes'
  '\bsolidity\b'
  '\bethskills\b'
  # more seed markers — crypto / hackathon / client / personal conventions
  'crypto-sweep'
  'magiccabinet'
  'on-chain'
  'onchain'
  'opencli'
  'AGENT_STATE'
  'zerodev'
  '\bcctp\b'
  'uxmaxx'
  'multihopper'
  'superteam'
  '\bokx\b'
  'funded-wallet'
  'reddit-agent'
)

# Absolute home paths are banned EXCEPT the synthetic /Users/dev/... demo set.
HOMEPATH_RE='(/Users/|/home/)'
HOMEPATH_ALLOW='/Users/dev/'

EXCLUDES=(--binary-files=without-match -I
  --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist --exclude-dir=.swiftpm
  --exclude-dir=node_modules --exclude=secret-scan.sh
  # Local handoff reports are gitignored and never enter the public tree.
  --exclude='REPORT-*.md'
  # External desktop-tool state written into the cwd; gitignored, so it can
  # never enter the public tree — excluded to keep the local gate signal clean.
  --exclude-dir=.hatch-pet
  # Local launch-video working dirs + agent work orders: never committed (gitignored),
  # and they legitimately quote the banned strings as instructions about the banlist.
  --exclude-dir=brag-output --exclude-dir=brag-output-codex --exclude-dir=handoffs)

fail=0

for pat in "${PATTERNS[@]}"; do
  hits=$(grep -rniE "${EXCLUDES[@]}" -- "$pat" "$ROOT" 2>/dev/null | grep -vE '(^|/)(LICENSE|CREDITS)([:/]|$)')
  # claude-fable-5 is a public Anthropic model: its catalog IDs and pricing
  # comments are legitimate product content, not doctrine leakage.
  case "$pat" in
    *fable*|*Fable*) hits=$(printf '%s' "$hits" | grep -viE 'claude-fable|fable 5 —|fable 5 and' || true) ;;
  esac
  if [ -n "$hits" ]; then
    echo "❌ banned pattern: $pat"
    echo "$hits"
    fail=1
  fi
done

# Home paths, minus the allowed synthetic prefix.
homehits=$(grep -rnE "${EXCLUDES[@]}" -- "$HOMEPATH_RE" "$ROOT" 2>/dev/null | grep -vE "$HOMEPATH_ALLOW")
if [ -n "$homehits" ]; then
  echo "❌ absolute home path (only $HOMEPATH_ALLOW is allowed):"
  echo "$homehits"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✅ secret-scan clean — no personal identifiers or private paths found."
fi
exit "$fail"
