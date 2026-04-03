#!/usr/bin/env bash
set -euo pipefail
# Test: on-prompt-submit.sh never blocks workers (fail-open guard)
# Verifies fix for tasks #134, #136, #156

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${SCRIPT_DIR}/.claude/hooks/on-prompt-submit.sh"
PASS=0; FAIL=0

# --- Set up isolated test environment ---
TEST_TMP=$(mktemp -d)
MOCK_BIN="${TEST_TMP}/bin"
TEST_RUNTIME="${TEST_TMP}/runtime"
mkdir -p "$MOCK_BIN" "${TEST_RUNTIME}"/{status,logs,errors,lifecycle,activity,research,reports,results,messages,debug}
touch "${TEST_RUNTIME}/.dirs_created"

# session.env so get_taskmaster_pane returns "1.0" (core team = window 1)
printf 'TASKMASTER_PANE=1.0\n' > "${TEST_RUNTIME}/session.env"

# Mock tmux — returns controlled pane identity
cat > "${MOCK_BIN}/tmux" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  show-environment) echo "DOEY_RUNTIME=${MOCK_RUNTIME}" ;;
  display-message)  echo "${MOCK_PANE}" ;;
  *) ;;
esac
EOF
chmod +x "${MOCK_BIN}/tmux"

# Build PATH excluding real doey-ctl — forces hook to use file-based write_pane_status
CLEAN_PATH=""
_saved_IFS="$IFS"; IFS=':'
for _dir in $PATH; do
  if [ ! -x "${_dir}/doey-ctl" ]; then
    CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}${_dir}"
  fi
done
IFS="$_saved_IFS"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

# --- Test runner ---
run_test() {
  local desc="$1" mock_pane="$2" expect_exit="${3:-0}" prompt="${4:-Task #158 Subtask 3: do work}"
  local check_busy="${5:-}"
  local actual_exit=0

  # Derive pane_safe (session:window.pane → session_window_pane)
  local pane_safe="${mock_pane//[-:.]/_}"
  # Clear prior status file so we can detect fresh writes
  rm -f "${TEST_RUNTIME}/status/${pane_safe}.status"

  MOCK_PANE="$mock_pane" \
  MOCK_RUNTIME="$TEST_RUNTIME" \
  TMUX_PANE="%99" \
  PATH="${MOCK_BIN}:${CLEAN_PATH}" \
  INPUT="{\"prompt\":\"${prompt}\"}" \
    bash "$HOOK" >/dev/null 2>/dev/null || actual_exit=$?

  if [ "$actual_exit" -eq "$expect_exit" ]; then
    echo "PASS: ${desc} (exit=${actual_exit})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${desc} (exit=${actual_exit}, expected ${expect_exit})"
    FAIL=$((FAIL + 1))
  fi

  # Verify BUSY status was written when requested
  if [ "$check_busy" = "busy" ]; then
    if grep -q 'STATUS: BUSY' "${TEST_RUNTIME}/status/${pane_safe}.status" 2>/dev/null; then
      echo "PASS: ${desc} — BUSY status written"
      PASS=$((PASS + 1))
    else
      echo "FAIL: ${desc} — BUSY status NOT written"
      FAIL=$((FAIL + 1))
    fi
  fi
}

echo "--- on-prompt-submit.sh Worker Fail-Open Tests ---"

# Workers must always exit 0 (allowed) — with task reference + verify BUSY set
run_test "Worker W2.1 with task ref"  "doey-test:2.1" 0 "Task #158 Subtask 3: do work" busy
run_test "Worker W2.2 with task ref"  "doey-test:2.2" 0 "Task #158 Subtask 3: do work" busy
run_test "Worker W3.1 with task ref"  "doey-test:3.1" 0 "Task #158 Subtask 3: do work" busy
run_test "Worker W5.3 with task ref"  "doey-test:5.3" 0 "Task #158 Subtask 3: do work" busy
run_test "Worker W10.4 with task ref" "doey-test:10.4" 0 "Task #158 Subtask 3: do work" busy

# Workers pass even WITHOUT task reference (fail-open) + BUSY still set
run_test "Worker W2.1 no task ref" "doey-test:2.1" 0 "hello world" busy
run_test "Worker W3.2 no task ref" "doey-test:3.2" 0 "just chatting" busy
run_test "Worker W4.1 empty prompt" "doey-test:4.1" 0 "" busy

# Subtaskmaster (pane 0 in worker window) — still passes hook
run_test "Subtaskmaster W2.0" "doey-test:2.0" 0

# Boss (W0.1) — not affected by worker guard, passes through normally
run_test "Boss W0.1" "doey-test:0.1" 0

# Taskmaster (W1.0) — core team, not affected by worker guard
run_test "Taskmaster W1.0" "doey-test:1.0" 0

# No TMUX_PANE — hook exits 0 immediately (baseline safety)
actual_exit=0
INPUT='{"prompt":"test"}' bash "$HOOK" >/dev/null 2>/dev/null || actual_exit=$?
if [ "$actual_exit" -eq 0 ]; then
  echo "PASS: No TMUX_PANE exits 0 (exit=0)"
  PASS=$((PASS + 1))
else
  echo "FAIL: No TMUX_PANE exits 0 (exit=${actual_exit}, expected 0)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Hook Worker Accept: ${PASS} pass, ${FAIL} fail ==="
[ "$FAIL" -eq 0 ] || exit 1
