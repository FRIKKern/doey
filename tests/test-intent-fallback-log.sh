#!/usr/bin/env bash
# tests/test-intent-fallback-log.sh
#
# Dedicated tests for the JSONL logging pipeline in shell/intent-fallback.sh:
#   1. full log schema on a successful call
#   2. --body value redaction
#   3. --token value redaction
#   4. concurrent appenders (no interleaved / corrupted lines)
#   5. 1 MB rotation
#   6. ANTHROPIC_API_KEY leak-guard swap-out
#
# Strategy: install a mock `claude` binary on PATH — `timeout 30 claude ...`
# resolves the binary via exec, so only a real executable shim works (a
# bash function override is invisible past exec). Phase 2 rewrote
# shell/intent-fallback.sh to call the local claude CLI, and http_status
# is now always null in the JSONL log.
#
# Mock claude is controlled via env vars (propagate through exec):
#   MOCK_CLAUDE_FIXTURE — path to a file whose contents become stdout
#   MOCK_CLAUDE_EXIT    — exit code to return (default 0)

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
  [ -n "${2:-}" ] && printf "       %s\n" "$2"
}

# Unique project namespace so parallel runs can't collide.
export PROJECT_NAME="test-intent-log-$$"
LOG_DIR="/tmp/doey/${PROJECT_NAME}"
LOG_FILE="${LOG_DIR}/intent-log.jsonl"

# ── Install mock claude on PATH ─────────────────────────────────────
MOCK_BIN_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t intent-fb-log-mock)
cat > "${MOCK_BIN_DIR}/claude" <<'MOCK'
#!/usr/bin/env bash
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
  rm -rf "$LOG_DIR" 2>/dev/null || true
  mkdir -p "$LOG_DIR"
  unset MOCK_CLAUDE_EXIT
  unset MOCK_CLAUDE_FIXTURE
  unset DOEY_NO_INTENT_FALLBACK
  unset DOEY_INTENT_FALLBACK
  # DOEY_PANE_ID takes precedence over TMUX_PANE inside intent-fallback.sh;
  # unset it so TMUX_PANE is the effective value under test.
  unset DOEY_PANE_ID
  export ANTHROPIC_API_KEY="sk-test-dummy"
  export DOEY_ROLE="team_lead"
  export TMUX_PANE="2.0"
}

# ── Unit 1: full log schema ─────────────────────────────────────────
echo "=== Unit 1: log schema on successful call ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey tsk lst" "Unknown command: tsk" "task|msg|status" "recent")

if [ ! -s "$LOG_FILE" ]; then
  _fail "log file created and non-empty" "expected $LOG_FILE; result=$result"
else
  line=$(tail -n 1 "$LOG_FILE")
  if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    _ok "log line parses as JSON"
  else
    _fail "log line parses as JSON" "line: $line"
  fi

  # Every schema field must exist (typed/command may be empty in rare
  # action modes but for success.json all 12 fields should be present).
  missing=""
  for field in ts pane role project typed err action command latency_ms http_status accepted reason; do
    exists=$(printf '%s' "$line" | jq -e "has(\"$field\")" 2>/dev/null || echo false)
    if [ "$exists" != "true" ]; then
      missing="${missing} ${field}"
    fi
  done
  if [ -z "$missing" ]; then
    _ok "all 12 schema fields present"
  else
    _fail "all 12 schema fields present" "missing:${missing} — line: $line"
  fi

  # Concrete value checks.
  proj=$(printf '%s' "$line" | jq -r '.project')
  if [ "$proj" = "$PROJECT_NAME" ]; then
    _ok "project = \$PROJECT_NAME"
  else
    _fail "project = \$PROJECT_NAME" "got: $proj"
  fi

  pane_val=$(printf '%s' "$line" | jq -r '.pane')
  if [ "$pane_val" = "2.0" ]; then
    _ok "pane = TMUX_PANE value"
  else
    _fail "pane = TMUX_PANE value" "got: $pane_val"
  fi

  role_val=$(printf '%s' "$line" | jq -r '.role')
  if [ "$role_val" = "team_lead" ]; then
    _ok "role = DOEY_ROLE value"
  else
    _fail "role = DOEY_ROLE value" "got: $role_val"
  fi

  # http_status is a REST-era field preserved for backward compat —
  # always JSON null in the CLI path.
  http=$(printf '%s' "$line" | jq -r '.http_status')
  if [ "$http" = "null" ]; then
    _ok "http_status = null (CLI path always null)"
  else
    _fail "http_status = null" "got: $http"
  fi

  accepted=$(printf '%s' "$line" | jq -r '.accepted')
  if [ "$accepted" = "true" ]; then
    _ok "accepted = true"
  else
    _fail "accepted = true" "got: $accepted"
  fi

  action=$(printf '%s' "$line" | jq -r '.action')
  if [ "$action" = "auto_correct" ]; then
    _ok "action = auto_correct (from fixture)"
  else
    _fail "action = auto_correct" "got: $action"
  fi

  reason=$(printf '%s' "$line" | jq -r '.reason')
  if [ -n "$reason" ] && [ "$reason" != "null" ]; then
    _ok "reason is non-empty (from fixture)"
  else
    _fail "reason is non-empty" "got: $reason"
  fi

  latency=$(printf '%s' "$line" | jq -r '.latency_ms')
  case "$latency" in
    ''|*[!0-9]*) _fail "latency_ms numeric" "got: $latency" ;;
    *)           _ok "latency_ms numeric ($latency ms)" ;;
  esac
fi

# ── Unit 2: --body redaction ────────────────────────────────────────
echo ""
echo "=== Unit 2: --body value redacted ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey msg send --body secretpayload --to 1.0" "bad args" "msg" "")

if [ ! -s "$LOG_FILE" ]; then
  _fail "log file was written" "result=$result"
else
  line=$(tail -n 1 "$LOG_FILE")
  logged=$(printf '%s' "$line" | jq -r '.typed // ""' 2>/dev/null)
  if printf '%s' "$logged" | grep -q 'secretpayload'; then
    _fail "--body value scrubbed from .typed" "got: $logged"
  elif printf '%s' "$logged" | grep -q '\*\*\*'; then
    _ok "--body value replaced with *** in .typed"
  else
    _fail "*** marker present after redaction" "got: $logged"
  fi
fi

# ── Unit 3: --token redaction ───────────────────────────────────────
echo ""
echo "=== Unit 3: --token value redacted ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey auth --token abc123xyz999 --verbose" "bad" "auth" "")

if [ ! -s "$LOG_FILE" ]; then
  _fail "log file was written" "result=$result"
else
  line=$(tail -n 1 "$LOG_FILE")
  logged=$(printf '%s' "$line" | jq -r '.typed // ""' 2>/dev/null)
  if printf '%s' "$logged" | grep -q 'abc123xyz999'; then
    _fail "--token value scrubbed from .typed" "got: $logged"
  elif printf '%s' "$logged" | grep -q '\*\*\*'; then
    _ok "--token value replaced with *** in .typed"
  else
    _fail "*** marker present after redaction" "got: $logged"
  fi
fi

# ── Unit 4: concurrent appenders ────────────────────────────────────
echo ""
echo "=== Unit 4: 5 concurrent appenders ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"

# Fire 5 in parallel. Same-process subshells inherit PATH and sourced
# function definitions; the PATH mock works across subshells.
for i in 1 2 3 4 5; do
  ( intent_fallback "cmd$i" "err$i" "schema" "ctx$i" >/dev/null ) &
done
wait

if [ ! -f "$LOG_FILE" ]; then
  _fail "log file exists after concurrent run" ""
else
  n=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ "$n" = "5" ]; then
    _ok "exactly 5 lines written (no loss)"
  else
    _fail "exactly 5 lines written" "got: $n"
  fi

  # Every line must be valid JSON (no interleaving).
  all_valid=1
  bad_line=""
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    if ! printf '%s' "$ln" | jq -e . >/dev/null 2>&1; then
      all_valid=0
      bad_line="$ln"
      break
    fi
  done < "$LOG_FILE"
  if [ "$all_valid" = "1" ]; then
    _ok "every line parses as JSON (no interleaving)"
  else
    _fail "every line parses as JSON" "first bad: $bad_line"
  fi

  # Verify the lock directory was cleaned up.
  if [ -d "${LOG_FILE}.lock" ]; then
    _fail "lockdir cleaned up" "stuck at ${LOG_FILE}.lock"
  else
    _ok "lockdir cleaned up"
  fi
fi

# ── Unit 5: rotation at 1 MB ────────────────────────────────────────
echo ""
echo "=== Unit 5: rotation when size > 1 MB ==="
_reset
# Pre-fill to ~1025 KB so the next call trips the 1 MB threshold.
dd if=/dev/zero of="$LOG_FILE" bs=1024 count=1025 2>/dev/null
pre_size=$(wc -c < "$LOG_FILE" | tr -d '[:space:]')

export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
result=$(intent_fallback "doey ls" "err" "ls" "")

if [ -f "${LOG_FILE}.1" ]; then
  _ok "intent-log.jsonl.1 created by rotation"
else
  _fail "intent-log.jsonl.1 created by rotation" "pre_size=$pre_size"
fi

if [ -f "$LOG_FILE" ]; then
  new_size=$(wc -c < "$LOG_FILE" | tr -d '[:space:]')
  # Fresh file after rotation should be just one JSON line (~few hundred bytes).
  if [ "$new_size" -lt 10000 ]; then
    _ok "current log file reset to fresh size ($new_size bytes)"
  else
    _fail "current log file reset" "size: $new_size"
  fi
else
  _fail "current log file recreated for fresh append" ""
fi

# ── Unit 6: API key leak guard ──────────────────────────────────────
echo ""
echo "=== Unit 6: API key leak guard fires ==="
_reset
export MOCK_CLAUDE_FIXTURE="${FIXTURES}/success.json"
# Set a distinctive key and embed it RAW in the typed command. The
# redaction regex only matches --flag forms, so the key would otherwise
# land in the log — the belt-and-braces guard must catch it.
export ANTHROPIC_API_KEY="sk-ant-TOTALLYSECRETLEAK12345"
result=$(intent_fallback "doey run weird ${ANTHROPIC_API_KEY} inside" "err" "run" "")

line=$(tail -n 1 "$LOG_FILE" 2>/dev/null || echo "")
if printf '%s' "$line" | grep -q "sk-ant-TOTALLYSECRETLEAK12345"; then
  _fail "API key NOT present in log line" "line: $line"
else
  _ok "API key NOT present in log line"
fi

if printf '%s' "$line" | grep -q 'api_key_leak_prevented'; then
  _ok "leak guard wrote error marker in place of real line"
else
  _fail "leak guard wrote error marker" "line: $line"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
printf "  %d/%d passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
