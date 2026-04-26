#!/usr/bin/env bash
# Regression test for task #626: hook-path resilience.
# Asserts every hook command in .claude/settings.json uses the fallback wrapper
# referencing both $CLAUDE_PROJECT_DIR/.claude/hooks/ and $HOME/.claude/doey/repo-path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
fail=0
total=0

[ -f "$SETTINGS" ] || { echo "FAIL: $SETTINGS missing"; exit 1; }

# Extract every command line; check each contains both required substrings.
while IFS= read -r line; do
  total=$((total + 1))
  if ! echo "$line" | grep -q 'CLAUDE_PROJECT_DIR/.claude/hooks/'; then
    echo "FAIL (no CLAUDE_PROJECT_DIR primary): $line"
    fail=$((fail + 1))
  fi
  if ! echo "$line" | grep -q 'HOME/.claude/doey/repo-path'; then
    echo "FAIL (no repo-path fallback): $line"
    fail=$((fail + 1))
  fi
done < <(grep '"command":' "$SETTINGS")

if [ "$total" -eq 0 ]; then
  echo "FAIL: no command entries found in $SETTINGS"
  exit 1
fi

if [ "$fail" -gt 0 ]; then
  echo "$fail failures across $total commands"
  exit 1
fi

echo "PASS: $total commands, all use the fallback wrapper"
