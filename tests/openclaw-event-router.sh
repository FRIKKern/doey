#!/usr/bin/env bash
# tests/openclaw-event-router.sh — verifies shell/openclaw-event-router.sh
# classifies events correctly, builds compact lines within length limits,
# and produces an embed JSON that matches the golden fixture.
set -euo pipefail

_here=$(cd "$(dirname "$0")" && pwd)
_root=$(cd "$_here/.." && pwd)
# shellcheck disable=SC1091
. "$_root/shell/openclaw-event-router.sh"

_pass=0
_fail=0

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] $label"
    _pass=$(( _pass + 1 ))
  else
    echo "[FAIL] $label"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    _fail=$(( _fail + 1 ))
  fi
}

# ── 1. Classification matrix ──────────────────────────────────────────
_assert_eq "classify worker_progress" "compact" "$(oc_classify_event worker_progress)"
_assert_eq "classify worker_busy"     "compact" "$(oc_classify_event worker_busy)"
_assert_eq "classify status_change"   "compact" "$(oc_classify_event status_change)"
_assert_eq "classify boss_event"      "embed"   "$(oc_classify_event boss_event)"
_assert_eq "classify error"           "embed"   "$(oc_classify_event error)"
_assert_eq "classify question"        "embed"   "$(oc_classify_event question)"
_assert_eq "classify lifecycle"       "embed"   "$(oc_classify_event lifecycle)"
_assert_eq "classify unknown→embed"   "embed"   "$(oc_classify_event totally_unknown_kind_xyz)"

# ── 2. Compact builder ────────────────────────────────────────────────
short=$(oc_build_compact 42 worker "ran tests")
_assert_eq "compact basic shape" "[T42·worker] ran tests" "$short"

# Length cap — feed an extremely long summary, expect ≤ 200.
long_summary=$(printf 'x%.0s' $(seq 1 500))
long=$(oc_build_compact 99 worker "$long_summary")
if [ "${#long}" -le 200 ]; then
  echo "[PASS] compact stays ≤ 200 chars (got ${#long})"
  _pass=$(( _pass + 1 ))
else
  echo "[FAIL] compact exceeds 200 chars: ${#long}"
  _fail=$(( _fail + 1 ))
fi

# Prefix sanity.
case "$long" in
  "[T"*) echo "[PASS] compact starts with [T"; _pass=$(( _pass + 1 )) ;;
  *)     echo "[FAIL] compact prefix wrong: $long"; _fail=$(( _fail + 1 )) ;;
esac

# ── 3. Embed builder vs golden ────────────────────────────────────────
golden="$_root/tests/fixtures/openclaw-embed-golden.json"
if [ ! -f "$golden" ]; then
  echo "[FAIL] golden fixture missing: $golden"
  _fail=$(( _fail + 1 ))
else
  actual_json=$(oc_build_embed question 999 boss "Approve commit?" "Files: a.go b.go" 3447003)
  # Canonicalize both via python json.tool (sorted keys, compact form)
  # so cosmetic whitespace differences don't fail the diff.
  golden_canon=$(python3 -c '
import json,sys
with open(sys.argv[1]) as f: print(json.dumps(json.load(f), sort_keys=True))
' "$golden")
  actual_canon=$(printf '%s' "$actual_json" | python3 -c '
import json,sys
print(json.dumps(json.load(sys.stdin), sort_keys=True))
')
  if [ "$golden_canon" = "$actual_canon" ]; then
    echo "[PASS] embed JSON matches golden fixture"
    _pass=$(( _pass + 1 ))
  else
    echo "[FAIL] embed JSON does not match golden fixture"
    echo "        expected: $golden_canon"
    echo "        actual:   $actual_canon"
    _fail=$(( _fail + 1 ))
  fi
fi

# ── 4. Default colors per kind ────────────────────────────────────────
err_json=$(oc_build_embed error 1 worker "boom" "stack")
case "$err_json" in
  *'"color": 15158332'*) echo "[PASS] error default color is red";  _pass=$(( _pass + 1 )) ;;
  *) echo "[FAIL] error default color missing";                     _fail=$(( _fail + 1 )) ;;
esac

life_json=$(oc_build_embed lifecycle 1 boss "started" "")
case "$life_json" in
  *'"color": 3066993'*) echo "[PASS] lifecycle default color is green"; _pass=$(( _pass + 1 )) ;;
  *) echo "[FAIL] lifecycle default color missing";                     _fail=$(( _fail + 1 )) ;;
esac

# ── 5. Self-test entrypoint ───────────────────────────────────────────
selftest=$(oc_event_router_test_self)
_assert_eq "oc_event_router_test_self" "PASS" "$selftest"

echo "─────────────────────"
echo "Passed: $_pass   Failed: $_fail"
[ "$_fail" -eq 0 ]
