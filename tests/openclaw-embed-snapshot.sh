#!/usr/bin/env bash
# tests/openclaw-embed-snapshot.sh — golden-fixture snapshot test for the
# Discord embed builder in shell/openclaw-event-router.sh (W4.2 sibling).
#
# Strategy: build an embed via oc_build_embed, canonicalize it and the
# golden fixture with `python3 -m json.tool --sort-keys`, and diff. If the
# library or fixture is not yet present (W4.2 still in flight), poll up to
# 30s, then exit 77 (skip) with a FIXTURE_MISSING message.
set -euo pipefail

_here=$(cd "$(dirname "$0")" && pwd)
_root=$(cd "$_here/.." && pwd)

LIB="$_root/shell/openclaw-event-router.sh"
FIXTURE="$_root/tests/fixtures/openclaw-embed-golden.json"

# Poll-wait up to 30s for both pieces.
_max=30
_n=0
while [ "$_n" -lt "$_max" ]; do
  if [ -f "$LIB" ] && [ -f "$FIXTURE" ]; then
    break
  fi
  sleep 1
  _n=$(( _n + 1 ))
done

if [ ! -f "$LIB" ]; then
  echo "FIXTURE_MISSING: shell/openclaw-event-router.sh not found after ${_max}s — skipping" >&2
  exit 77
fi
if [ ! -f "$FIXTURE" ]; then
  echo "FIXTURE_MISSING: tests/fixtures/openclaw-embed-golden.json not found after ${_max}s — skipping" >&2
  exit 77
fi

# shellcheck source=../shell/openclaw-event-router.sh
source "$LIB"

actual_raw=$(oc_build_embed question 999 boss "Approve commit?" "Files: a.go b.go")

if ! actual_canon=$(printf '%s' "$actual_raw" | python3 -m json.tool --sort-keys 2>&1); then
  echo "[FAIL] oc_build_embed output was not valid JSON" >&2
  echo "--- raw output ---" >&2
  printf '%s\n' "$actual_raw" >&2
  echo "--- python3 stderr ---" >&2
  printf '%s\n' "$actual_canon" >&2
  exit 1
fi

if ! golden_canon=$(python3 -m json.tool --sort-keys < "$FIXTURE" 2>&1); then
  echo "[FAIL] golden fixture is not valid JSON" >&2
  printf '%s\n' "$golden_canon" >&2
  exit 1
fi

if [ "$actual_canon" = "$golden_canon" ]; then
  echo "[PASS] embed matches golden fixture"
  exit 0
fi

echo "[FAIL] embed mismatch vs golden fixture" >&2
echo "--- actual (canonical) ---" >&2
printf '%s\n' "$actual_canon" >&2
echo "--- expected (canonical) ---" >&2
printf '%s\n' "$golden_canon" >&2
echo "--- diff ---" >&2
diff <(printf '%s\n' "$actual_canon") <(printf '%s\n' "$golden_canon") >&2 || true
exit 1
