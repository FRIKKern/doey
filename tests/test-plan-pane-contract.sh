#!/usr/bin/env bash
# test-plan-pane-contract.sh — smoke test for the plan-pane validator.
#
# Asserts:
#   1. shell/check-plan-pane-contract.sh exists and is executable.
#   2. Validator exits 0 when run against the canonical six fixtures.
#   3. Validator emits well-formed JSON in --json mode.
#   4. Validator exits non-zero on a synthesised drift (missing plan.md).
#   5. Skip-when-no-runtime path works (no live runtime → still exits 0).
#
# See docs/plan-pane-contract.md.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
VALIDATOR="$REPO_DIR/shell/check-plan-pane-contract.sh"
FIXTURES_DIR="$REPO_DIR/tui/internal/planview/testdata/fixtures"

passed=0
failed=0

_pass() {
  printf '  ok  %s\n' "$1"
  passed=$((passed + 1))
}

_fail() {
  printf '  FAIL  %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then
    printf '         %s\n' "$2" >&2
  fi
  failed=$((failed + 1))
}

# ── 1: validator exists and is executable ────────────────────────────

if [ -x "$VALIDATOR" ]; then
  _pass "validator is executable: $VALIDATOR"
else
  _fail "validator missing or not executable" "$VALIDATOR"
  printf '\nFAIL: %d test(s) failed\n' "$failed" >&2
  exit 1
fi

# ── 2: fixture sweep passes ──────────────────────────────────────────

if bash "$VALIDATOR" --fixtures-dir "$FIXTURES_DIR" --runtime-dir "/nonexistent-runtime-$$" --quiet >/dev/null 2>&1; then
  _pass "validator exits 0 against the six fixtures"
else
  _fail "validator failed against fixtures" "expected pass — Worker A's fixtures may still be in flight"
fi

# ── 3: --json mode emits a single object ─────────────────────────────

json_out="$(bash "$VALIDATOR" --fixtures-dir "$FIXTURES_DIR" --runtime-dir "/nonexistent-runtime-$$" --json 2>/dev/null || true)"
if printf '%s' "$json_out" | grep -qE '^\{.*"ok":(true|false).*\}$'; then
  _pass "--json emits a single JSON object with .ok"
else
  _fail "--json output not well-formed" "$json_out"
fi

# ── 4: drift detection ───────────────────────────────────────────────

drift_dir="$(mktemp -d)"
trap 'rm -rf "$drift_dir"' EXIT
mkdir -p "$drift_dir/draft"  # only one scenario, missing the rest
if bash "$VALIDATOR" --fixtures-dir "$drift_dir" --runtime-dir "/nonexistent-runtime-$$" --quiet >/dev/null 2>&1; then
  _fail "validator passed on a drift fixture set" "expected non-zero exit"
else
  _pass "validator exits non-zero on missing scenarios"
fi

# ── 5: skip-when-no-runtime path ─────────────────────────────────────

# When fixtures pass and runtime is empty, exit must still be 0.
runtime_empty="$(mktemp -d)"
trap 'rm -rf "$drift_dir" "$runtime_empty"' EXIT
if bash "$VALIDATOR" --fixtures-dir "$FIXTURES_DIR" --runtime-dir "$runtime_empty" --quiet >/dev/null 2>&1; then
  _pass "validator skips live checks when runtime is empty"
else
  _fail "validator failed with empty runtime" "fixtures may be incomplete; not a runtime-skip regression on its own"
fi

# ── report ───────────────────────────────────────────────────────────

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'PASS: %d/%d tests\n' "$passed" "$((passed + failed))"
  exit 0
else
  printf 'FAIL: %d/%d tests passed\n' "$passed" "$((passed + failed))" >&2
  exit 1
fi
