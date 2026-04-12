#!/usr/bin/env bash
# Test: .claude/hooks/stop-enforce-ask-user-question.sh — 11 cases A-K
# Coverage: shadow pass, block exit 2, tool_use short-circuit, role gate,
# re-entry, missing transcript, retry cap, off mode, counter reset, fullwidth
# normalization, Planner sidecar fallback detection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${SCRIPT_DIR}/.claude/hooks/stop-enforce-ask-user-question.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_BIN="${TEST_TMP}/bin"
TEST_RUNTIME="${TEST_TMP}/runtime"
TEST_PROJECT="${TEST_TMP}/project"
mkdir -p "$MOCK_BIN" "${TEST_RUNTIME}"/{status,logs,errors,lifecycle,activity,research,reports,results,messages} "$TEST_PROJECT/.doey"
touch "${TEST_RUNTIME}/.dirs_created"
printf 'TASKMASTER_PANE=1.0\n' > "${TEST_RUNTIME}/session.env"

# Mock tmux — returns controlled pane identity from MOCK_PANE / MOCK_RUNTIME
cat > "${MOCK_BIN}/tmux" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  show-environment) echo "DOEY_RUNTIME=${MOCK_RUNTIME}" ;;
  display-message)  echo "${MOCK_PANE}" ;;
  *) ;;
esac
EOF
chmod +x "${MOCK_BIN}/tmux"

# Build PATH excluding real doey-ctl so common.sh takes the file-based paths
CLEAN_PATH=""
_saved_IFS="$IFS"; IFS=':'
for _dir in $PATH; do
  if [ ! -x "${_dir}/doey-ctl" ]; then
    CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}${_dir}"
  fi
done
IFS="$_saved_IFS"

VIOLATIONS_LOG="${TEST_PROJECT}/.doey/violations/ask-user-question.jsonl"

# pane_safe helper — mirrors tr ':.-' '_'
pane_safe_of() { printf '%s' "$1" | tr ':.-' '_'; }

# Build an assistant-text transcript JSONL file.
make_transcript_text() {
  local path="$1" text="$2"
  jq -nc --arg t "$text" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}' > "$path"
}

# Build an assistant-tool_use transcript JSONL file.
make_transcript_tool_use() {
  local path="$1"
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"AskUserQuestion", input:{}}]}}' > "$path"
}

# Reset per-case state
reset_state() {
  rm -rf "${TEST_PROJECT}/.doey/violations"
  rm -f  "${TEST_RUNTIME}/status/"enforce-retry-*.count
  mkdir -p "${TEST_PROJECT}/.doey/violations"
  : > "${VIOLATIONS_LOG}"
  rm -f "${TEST_RUNTIME}/status/"*.team_role
}

# Run the hook with controlled environment. Arguments are key=value pairs.
# Required: MOCK_PANE, INPUT. Optional: DOEY_ENFORCE_QUESTIONS, DOEY_TEAM_ROLE.
# Returns exit code in $RC, captures stdout to $OUT, stderr to $ERR.
run_hook() {
  local mock_pane="$1" input="$2" mode="${3:-shadow}" team_role="${4:-}" pre_counter="${5:-}"
  local pane_safe; pane_safe=$(pane_safe_of "$mock_pane")

  if [ -n "$pre_counter" ]; then
    printf '%s' "$pre_counter" > "${TEST_RUNTIME}/status/enforce-retry-${pane_safe}.count"
  fi

  OUT_FILE="${TEST_TMP}/out.$$"
  ERR_FILE="${TEST_TMP}/err.$$"
  RC=0

  MOCK_PANE="$mock_pane" \
  MOCK_RUNTIME="$TEST_RUNTIME" \
  TMUX_PANE="%99" \
  DOEY_PROJECT_DIR="$TEST_PROJECT" \
  DOEY_ENFORCE_QUESTIONS="$mode" \
  DOEY_TEAM_ROLE="$team_role" \
  INPUT="$input" \
  PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    bash "$HOOK" > "$OUT_FILE" 2> "$ERR_FILE" || RC=$?

  OUT=$(cat "$OUT_FILE" 2>/dev/null || true)
  ERR=$(cat "$ERR_FILE" 2>/dev/null || true)
  PANE_SAFE_RESULT="$pane_safe"
  rm -f "$OUT_FILE" "$ERR_FILE"
}

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$1" "$2"; }

assert_exit() {
  local desc="$1" want="$2"
  if [ "$RC" = "$want" ]; then pass "$desc exit=$want"
  else fail "$desc" "exit=$RC want=$want (stderr=${ERR:0:120})"
  fi
}

assert_log_has() {
  local desc="$1" needle="$2"
  if grep -q "$needle" "$VIOLATIONS_LOG" 2>/dev/null; then pass "$desc log contains '$needle'"
  else fail "$desc" "needle '$needle' missing from $(cat "$VIOLATIONS_LOG" 2>/dev/null || echo '<empty>')"
  fi
}

assert_no_log() {
  local desc="$1"
  if [ ! -s "$VIOLATIONS_LOG" ]; then pass "$desc log empty"
  else fail "$desc" "log should be empty, got: $(cat "$VIOLATIONS_LOG")"
  fi
}

assert_counter_absent() {
  local desc="$1" ps="$2"
  if [ ! -f "${TEST_RUNTIME}/status/enforce-retry-${ps}.count" ]; then pass "$desc counter cleared"
  else fail "$desc" "counter still exists: $(cat "${TEST_RUNTIME}/status/enforce-retry-${ps}.count")"
  fi
}

assert_counter_value() {
  local desc="$1" ps="$2" want="$3"
  local got; got=$(cat "${TEST_RUNTIME}/status/enforce-retry-${ps}.count" 2>/dev/null || echo "")
  if [ "$got" = "$want" ]; then pass "$desc counter=$want"
  else fail "$desc" "counter=$got want=$want"
  fi
}

echo "=== stop-enforce-ask-user-question.sh test harness ==="

# ---- Case A: shadow mode, Boss role, violation → exit 0 + log mode=shadow ----
echo "[A] shadow compliance pass — Boss ends with 'Should I proceed?'"
reset_state
T="${TEST_TMP}/trans_A.jsonl"; make_transcript_text "$T" "Should I proceed?"
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sA\",\"stop_hook_active\":false}" shadow
assert_exit "A" 0
assert_log_has "A" '"mode":"shadow"'
assert_log_has "A" '"role":"boss"'

# ---- Case B: block mode, Boss, violation → exit 2 + BLOCKED reason ----
echo "[B] block mode blocks — Boss ends with 'Do you want to ship?'"
reset_state
T="${TEST_TMP}/trans_B.jsonl"; make_transcript_text "$T" "Do you want to ship?"
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sB\",\"stop_hook_active\":false}" block
assert_exit "B" 2
if printf '%s' "$ERR" | grep -q 'BLOCKED:'; then pass "B stderr has BLOCKED stanza"
else fail "B" "stderr=$ERR"
fi
if printf '%s' "$OUT" | grep -q '"decision":"block"'; then pass "B stdout has decision=block JSON"
else fail "B" "stdout=$OUT"
fi
assert_log_has "B" '"mode":"block"'
assert_counter_value "B" "$PANE_SAFE_RESULT" "1"

# ---- Case C: compliant — last assistant has tool_use AskUserQuestion → exit 0 ----
echo "[C] compliant short-circuit — tool_use AskUserQuestion present"
reset_state
T="${TEST_TMP}/trans_C.jsonl"; make_transcript_tool_use "$T"
# Seed counter to confirm compliant path clears it
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sC\",\"stop_hook_active\":false}" block "" "2"
assert_exit "C" 0
assert_no_log "C"
assert_counter_absent "C" "$PANE_SAFE_RESULT"

# ---- Case D: wrong role early-exit — plain Worker ----
echo "[D] wrong-role early-exit — worker pane"
reset_state
T="${TEST_TMP}/trans_D.jsonl"; make_transcript_text "$T" "Should I proceed?"
# W3.1 is a worker (not manager pane 0, not boss)
run_hook "doey-test:3.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sD\",\"stop_hook_active\":false}" shadow
assert_exit "D" 0
assert_no_log "D"

# ---- Case E: stop_hook_active=true early-exit ----
echo "[E] re-entry early-exit — stop_hook_active=true"
reset_state
T="${TEST_TMP}/trans_E.jsonl"; make_transcript_text "$T" "Should I proceed?"
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sE\",\"stop_hook_active\":true}" shadow
assert_exit "E" 0
assert_no_log "E"

# ---- Case F: missing transcript path early-exit ----
echo "[F] missing transcript early-exit"
reset_state
run_hook "doey-test:0.1" '{"transcript_path":"","session_id":"sF","stop_hook_active":false}' shadow
assert_exit "F" 0
assert_no_log "F"

# ---- Case G: block mode retry cap — 3rd attempt downgrades to warn ----
echo "[G] retry cap — 3rd consecutive becomes mode=warn, counter cleared, exit 0"
reset_state
T="${TEST_TMP}/trans_G.jsonl"; make_transcript_text "$T" "Should I ship it?"
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sG\",\"stop_hook_active\":false}" block "" "2"
assert_exit "G" 0
assert_log_has "G" '"mode":"warn"'
assert_counter_absent "G" "$PANE_SAFE_RESULT"

# ---- Case H: off mode early-exit ----
echo "[H] off mode early-exit"
reset_state
T="${TEST_TMP}/trans_H.jsonl"; make_transcript_text "$T" "Should I proceed?"
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sH\",\"stop_hook_active\":false}" off
assert_exit "H" 0
assert_no_log "H"

# ---- Case I: counter reset on clean turn (no violation) ----
echo "[I] counter reset on clean turn"
reset_state
T="${TEST_TMP}/trans_I.jsonl"; make_transcript_text "$T" "All good. Task complete."
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sI\",\"stop_hook_active\":false}" block "" "1"
assert_exit "I" 0
assert_no_log "I"
assert_counter_absent "I" "$PANE_SAFE_RESULT"

# ---- Case J: Unicode fullwidth ？ triggers Condition A ----
echo "[J] fullwidth ？ normalization"
reset_state
T="${TEST_TMP}/trans_J.jsonl"; make_transcript_text "$T" "Should I proceed？"
run_hook "doey-test:0.1" "{\"transcript_path\":\"${T}\",\"session_id\":\"sJ\",\"stop_hook_active\":false}" shadow
assert_exit "J" 0
assert_log_has "J" '"mode":"shadow"'
assert_log_has "J" '"role":"boss"'

# ---- Case K: Planner detection via sidecar fallback ----
echo "[K] Planner sidecar fallback — no DOEY_TEAM_ROLE env, .team_role file present"
reset_state
T="${TEST_TMP}/trans_K.jsonl"; make_transcript_text "$T" "Would you like option A?"
# Masterplan window 3, manager pane 0 → is_boss=false. Drop sidecar file for is_planner fallback.
PS_K=$(pane_safe_of "doey-test:3.0")
printf 'planner' > "${TEST_RUNTIME}/status/${PS_K}.team_role"
# DOEY_TEAM_ROLE env explicitly empty to force sidecar read path
run_hook "doey-test:3.0" "{\"transcript_path\":\"${T}\",\"session_id\":\"sK\",\"stop_hook_active\":false}" shadow ""
assert_exit "K" 0
assert_log_has "K" '"mode":"shadow"'
assert_log_has "K" '"role":"planner"'

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
