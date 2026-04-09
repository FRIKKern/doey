#!/usr/bin/env bash
# tests/test-intent-fallback.sh — Unit tests for shell/intent-fallback.sh
#
# Strategy: install a mock `claude` binary in a temp dir and prepend it
# to $PATH, so the function-under-test (which invokes `claude` via
# `timeout 30 claude ...`) hits our shim instead of the real binary.
#
# The mock is a PATH script (not a shell function) because the real
# implementation invokes `timeout 30 claude ...` — `timeout` execs
# `claude` as a subprocess, bypassing any shell-function override.
#
# The mock reads two env vars (which DO propagate through exec):
#   MOCK_CLAUDE_FIXTURE — path to a file whose contents become stdout
#   MOCK_CLAUDE_EXIT    — exit code to return (default 0)
#
# NOTE: intent-fallback.sh sets `set -uo pipefail`. This file must also
# be compatible with -u.

set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures/intent-fallback"

_ok() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  printf "  ok %s\n" "$1"
}
_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  printf "  FAIL %s\n" "$1"
  [ -n "${2:-}" ] && printf "      %s\n" "$2"
}

# Isolate log state in a unique temp project namespace so parallel runs
# can't step on each other.
export PROJECT_NAME="test-intent-fallback-$$"
LOG_DIR="/tmp/doey/${PROJECT_NAME}"
LOG_FILE="${LOG_DIR}/intent-log.jsonl"

# ── Install mock claude on PATH ─────────────────────────────────────
MOCK_BIN_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t intent-fb-mock)
cat > "${MOCK_BIN_DIR}/claude" <<'MOCK'
#!/usr/bin/env bash
# Mock claude CLI. Reads MOCK_CLAUDE_FIXTURE / MOCK_CLAUDE_EXIT via env.
exit_code="${MOCK_CLAUDE_EXIT:-0}"
if [ "$exit_code" != "0" ]; then
  exit "$exit_code"
fi
fixture="${MOCK_CLAUDE_FIXTURE:-}"
if [ -n "$fixture" ] && [ -f "$fixture" ]; then
  cat "$fixture"
fi
exit 0
MOCK
chmod +x "${MOCK_BIN_DIR}/claude"
export PATH="${MOCK_BIN_DIR}:${PATH}"

trap 'rm -rf "$LOG_DIR" "$MOCK_BIN_DIR"' EXIT

# shellcheck source=../shell/intent-fallback.sh
source "${REPO_ROOT}/shell/intent-fallback.sh"

_reset() {
  rm -f "$LOG_FILE" 2>/dev/null || true
  unset MOCK_CLAUDE_EXIT
  unset MOCK_CLAUDE_FIXTURE
  unset DOEY_NO_INTENT_FALLBACK
  unset DOEY_INTENT_FALLBACK
  export ANTHROPIC_API_KEY="sk-test-dummy"
}

# ── Case 1: successful auto_correct ─────────────────────────────────
echo "=== Case 1: successful auto_correct ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey ls" "command not found: dooy" "ls|status|run" "prev: doey up")
if [ -n "$result" ] && printf '%s' "$result" | jq -e '.action == "auto_correct"' >/dev/null 2>&1; then
  if printf '%s' "$result" | jq -e '.command == "doey ls"' >/dev/null 2>&1; then
    _ok "returns valid JSON with auto_correct action and command field"
  else
    _fail "returns auto_correct with .command field" "got: $result"
  fi
else
  _fail "returns valid auto_correct JSON" "got: $result"
fi

# ── Case 2: DOEY_INTENT_FALLBACK=0 positive opt-out ─────────────────
echo ""
echo "=== Case 2: DOEY_INTENT_FALLBACK=0 short-circuits ==="
_reset
export DOEY_INTENT_FALLBACK=0
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey ls" "command not found" "ls|status" "")
if [ -z "$result" ]; then
  _ok "DOEY_INTENT_FALLBACK=0 short-circuits to empty string"
else
  _fail "DOEY_INTENT_FALLBACK=0 → empty output" "got: $result"
fi

# ── Case 3: DOEY_NO_INTENT_FALLBACK=1 negative kill switch ──────────
echo ""
echo "=== Case 3: DOEY_NO_INTENT_FALLBACK=1 ==="
_reset
export DOEY_NO_INTENT_FALLBACK=1
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey ls" "command not found" "ls|status" "")
if [ -z "$result" ]; then
  _ok "DOEY_NO_INTENT_FALLBACK=1 returns empty"
else
  _fail "kill switch → empty output" "got: $result"
fi

# ── Case 4: claude exits non-zero (simulates timeout / auth / net) ──
echo ""
echo "=== Case 4: claude exits non-zero (simulates timeout) ==="
_reset
export MOCK_CLAUDE_EXIT=124
result=$(intent_fallback "doey ls" "command not found" "ls|status" "")
if [ -z "$result" ]; then
  _ok "claude exit 124 → empty output"
else
  _fail "claude nonzero → empty" "got: $result"
fi

# ── Case 5: claude returns JSON with no .result field ───────────────
echo ""
echo "=== Case 5: claude JSON without .result (error body) ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/http401.json"
result=$(intent_fallback "doey ls" "command not found" "ls|status" "")
if [ -z "$result" ]; then
  _ok "JSON with no .result → empty output"
else
  _fail "no .result → empty" "got: $result"
fi

# ── Case 6: malformed top-level JSON ────────────────────────────────
echo ""
echo "=== Case 6: malformed response body ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/malformed.txt"
result=$(intent_fallback "doey ls" "command not found" "ls|status" "")
if [ -z "$result" ]; then
  _ok "malformed JSON → empty output"
else
  _fail "malformed → empty" "got: $result"
fi

# ── Case 7: log entry redaction ─────────────────────────────────────
echo ""
echo "=== Case 7: log redaction of --body/--token/--key/--password ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
typed_raw="doey run --body secretbody --token t0k3n --key abc123 --password hunter2 rest"
result=$(intent_fallback "$typed_raw" "bad args" "run" "")

if [ -z "$result" ]; then
  _fail "success call returned a payload" "result was empty; claude mock or sourcing broken"
elif [ ! -s "$LOG_FILE" ]; then
  _fail "log file was created and non-empty" "expected $LOG_FILE"
else
  line=$(tail -n 1 "$LOG_FILE")
  logged_typed=$(printf '%s' "$line" | jq -r '.typed // ""' 2>/dev/null)
  if [ -z "$logged_typed" ]; then
    _fail "log line has .typed field" "line: $line"
  elif printf '%s' "$logged_typed" | grep -qE 'secretbody|t0k3n|abc123|hunter2'; then
    _fail "log redacted all sensitive values" "got: $logged_typed"
  elif ! printf '%s' "$logged_typed" | grep -q '\*\*\*'; then
    _fail "log contains *** redaction markers" "got: $logged_typed"
  else
    _ok "log entry redacts --body/--token/--key/--password values"
  fi

  # Extra guard: latency_ms field must exist and be a number.
  latency=$(printf '%s' "$line" | jq -r '.latency_ms // "missing"' 2>/dev/null)
  case "$latency" in
    ''|*[!0-9]*) _fail "log has numeric latency_ms" "got: $latency" ;;
    *)           _ok "log has numeric latency_ms field ($latency ms)" ;;
  esac
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
printf "  %d/%d passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
