#!/usr/bin/env bash
# secret-scan.sh — fail the build if any personal identifier or private path leaks
# into the public tree. Run before every push; wired into CI.
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
)

# Absolute home paths are banned EXCEPT the synthetic /Users/dev/... demo set.
HOMEPATH_RE='(/Users/|/home/)'
HOMEPATH_ALLOW='/Users/dev/'

EXCLUDES=(--binary-files=without-match -I
  --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist --exclude-dir=.swiftpm
  --exclude=secret-scan.sh)

fail=0

for pat in "${PATTERNS[@]}"; do
  hits=$(grep -rnE "${EXCLUDES[@]}" -- "$pat" "$ROOT" 2>/dev/null | grep -vE '(^|/)(LICENSE|CREDITS)([:/]|$)')
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
