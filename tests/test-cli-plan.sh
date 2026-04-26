#!/usr/bin/env bash
set -euo pipefail

# Regression tests for the `doey plan` subcommand router.
# Verifies that unknown subcommands and --help do NOT spawn masterplan team
# windows (task 601 Phase 1 fix).

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOEY="${PROJECT_ROOT}/shell/doey.sh"

passes=0
fails=0

assert_pass() {
  printf 'PASS: %s\n' "$1"
  passes=$((passes + 1))
}

assert_fail() {
  printf 'FAIL: %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '      %s\n' "$2"
  fi
  fails=$((fails + 1))
}

run_capture() {
  # Run doey.sh with given args; capture combined stdout+stderr and exit code.
  # Sets globals: out, rc.
  out="$("$DOEY" "$@" 2>&1 || true)"
  rc=$?
}

# ---------------------------------------------------------------------------
# Test 1: `doey plan show 1` does NOT trigger masterplan team creation.
# We assert the output contains no team-spawn signature.
# ---------------------------------------------------------------------------
out="$("$DOEY" plan show 1 2>&1 || true)"
case "$out" in
  *"Creating team:"*|*"Masterplan window created"*|*"add_team_from_def"*)
    assert_fail "doey plan show 1 did not spawn team window" "$out" ;;
  *)
    assert_pass "doey plan show 1 did not spawn team window" ;;
esac

# ---------------------------------------------------------------------------
# Test 2: `doey plan --help` exits 0 and prints "Usage: doey plan".
# ---------------------------------------------------------------------------
set +e
out="$("$DOEY" plan --help 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  case "$out" in
    *"Usage: doey plan"*) assert_pass "doey plan --help exits 0 and prints usage" ;;
    *) assert_fail "doey plan --help missing usage output" "$out" ;;
  esac
else
  assert_fail "doey plan --help exit code is $rc, expected 0" "$out"
fi

# ---------------------------------------------------------------------------
# Test 3: `doey plan -h` exits 0 with usage output.
# ---------------------------------------------------------------------------
set +e
out="$("$DOEY" plan -h 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  case "$out" in
    *"Usage: doey plan"*) assert_pass "doey plan -h exits 0 and prints usage" ;;
    *) assert_fail "doey plan -h missing usage output" "$out" ;;
  esac
else
  assert_fail "doey plan -h exit code is $rc, expected 0" "$out"
fi

# ---------------------------------------------------------------------------
# Test 4: `doey plan` (no args) exits 0 with usage output.
# ---------------------------------------------------------------------------
set +e
out="$("$DOEY" plan 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  case "$out" in
    *"Usage: doey plan"*) assert_pass "doey plan (no args) exits 0 and prints usage" ;;
    *) assert_fail "doey plan (no args) missing usage output" "$out" ;;
  esac
else
  assert_fail "doey plan (no args) exit code is $rc, expected 0" "$out"
fi

# ---------------------------------------------------------------------------
# Test 5: `doey plan --bogus` exits non-zero with "unknown option".
# ---------------------------------------------------------------------------
set +e
out="$("$DOEY" plan --bogus 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *"unknown option"*) assert_pass "doey plan --bogus rejected as unknown option" ;;
    *) assert_fail "doey plan --bogus missing 'unknown option' message" "$out" ;;
  esac
else
  assert_fail "doey plan --bogus exit code 0, expected non-zero" "$out"
fi

# ---------------------------------------------------------------------------
# Test 6: free-form goal path is preserved (read-only verification).
# We do NOT actually run `doey plan "goal text"` because that would spawn a
# real team window. Instead we grep shell/doey.sh to confirm the default-arm
# masterplan goal handler is still present and reachable AFTER the new arms.
# ---------------------------------------------------------------------------
if grep -qE 'goal="\$\{2:-\}"' "${PROJECT_ROOT}/shell/doey.sh" \
   && grep -qE 'doey masterplan' "${PROJECT_ROOT}/shell/doey.sh"; then
  assert_pass "free-form goal default arm preserved in shell/doey.sh"
else
  assert_fail "free-form goal default arm appears to have been removed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== test-cli-plan: ${passes} passed, ${fails} failed ==="
if [ "$fails" -gt 0 ]; then
  exit 1
fi
exit 0
