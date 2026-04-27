#!/usr/bin/env bash
# test-stm-wait.sh — Subtaskmaster reactive wait hook (task 648, Lane B).
#
# Verifies:
#   1. stm-wait.sh exits within 5s when a worker in the same team window
#      transitions to FINISHED.
#   2. stm-wait.sh exits when a message lands in the STM's inbox.
#   3. taskmaster-wait.sh emits a role-mismatch warning when invoked by an
#      STM (role=team_lead), and stays silent when invoked by the coordinator.
#
# Bash 3.2 compatible. No real tmux required — pane/runtime are mocked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STM_HOOK="${SCRIPT_DIR}/.claude/hooks/stm-wait.sh"
TM_HOOK="${SCRIPT_DIR}/.claude/hooks/taskmaster-wait.sh"

PASS=0; FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- one-time scaffolding -------------------------------------------------
TEST_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t stm_wait)
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_BIN="${TEST_TMP}/bin"
mkdir -p "$MOCK_BIN"

# Mock tmux — controlled by env vars set per-invocation. Returns the caller
# pane on display-message and emits the runtime on show-environment.
cat > "${MOCK_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  show-environment)
    echo "DOEY_RUNTIME=${MOCK_RUNTIME:-/tmp/doey/none}"
    ;;
  display-message)
    # Return whatever the test injected (window.pane or PID-style)
    case "$*" in
      *'#{window_index}.#{pane_index}'*) echo "${MOCK_PANE_WP:-2.0}" ;;
      *'#{pane_pid}'*)                   echo "${MOCK_PANE_PID:-99999}" ;;
      *)                                  echo "${MOCK_PANE_WP:-2.0}" ;;
    esac
    ;;
  copy-mode|send-keys|kill-pane|set-environment)
    : # no-op
    ;;
  *) : ;;
esac
EOF
chmod +x "${MOCK_BIN}/tmux"

# Strip real doey-ctl from PATH so the hook takes the file-based fallback.
CLEAN_PATH=""
_saved_IFS="$IFS"; IFS=':'
for _dir in $PATH; do
  if [ ! -x "${_dir}/doey-ctl" ]; then
    CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}${_dir}"
  fi
done
IFS="$_saved_IFS"

# Build a fresh runtime per test so state never leaks between cases.
make_runtime() {
  local rt="$1"
  mkdir -p "${rt}/status" "${rt}/messages" "${rt}/triggers" \
           "${rt}/results"  "${rt}/logs"     "${rt}/errors"   \
           "${rt}/activity" "${rt}/reports"  "${rt}/research" \
           "${rt}/debug"    "${rt}/recovery" "${rt}/issues"
  cat > "${rt}/session.env" <<EOS
SESSION_NAME="doey-test"
PROJECT_DIR="${TEST_TMP}/project"
PROJECT_NAME="test"
GRID="2x2"
TEAM_WINDOWS="2"
EOS
  mkdir -p "${TEST_TMP}/project/.doey/tasks"
  # Team window 2 owns worker pane 1 (W2.1). STM lives at W2.0.
  cat > "${rt}/team_2.env" <<EOS
WORKER_PANES="1"
EOS
  touch "${rt}/.dirs_created"
}

# Run a hook in the background with a wall-clock deadline. Echoes the elapsed
# seconds, exits 0 if the hook returned before deadline, 124 if we had to kill it.
run_with_deadline() {
  local hook="$1" deadline="$2" out_file="$3" err_file="$4"
  shift 4
  local start now end pid elapsed
  start=$(date +%s)
  ( "$@" bash "$hook" >"$out_file" 2>"$err_file" ) &
  pid=$!
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      end=$(date +%s); elapsed=$((end - start))
      echo "$elapsed"
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      end=$(date +%s); elapsed=$((end - start))
      echo "$elapsed"
      return 124
    fi
    sleep 1
  done
}

# ──────────────────────────────────────────────────────────────────────
# Test 1: STM wakes on worker FINISHED within 5 seconds
# ──────────────────────────────────────────────────────────────────────
test_finished_wake() {
  local desc="STM wakes on worker FINISHED within 5s"
  if [ ! -x "$STM_HOOK" ] && [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — stm-wait.sh missing at ${STM_HOOK}"
    return
  fi
  local rt="${TEST_TMP}/rt1"
  make_runtime "$rt"

  # Pre-write the worker (W2.1) status file in BUSY state.
  local wsafe="doey-test_2_1"
  cat > "${rt}/status/${wsafe}.status" <<EOS
STATUS: BUSY
ROLE: worker
PANE: 2.1
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S')
EOS

  # Flip worker to FINISHED ~1.5s after the hook starts so we exercise the
  # event-driven path (inotify or poll). Done in a background subshell.
  ( sleep 2
    cat > "${rt}/status/${wsafe}.status" <<EOS
STATUS: FINISHED
ROLE: worker
PANE: 2.1
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S')
EOS
    # Some implementations emit a result file as the canonical signal —
    # write one too so either trigger satisfies the wait.
    printf '{"pane":"2.1","status":"FINISHED"}\n' \
      > "${rt}/results/pane_${wsafe}.json"
    # Trigger file is another supported wake path.
    touch "${rt}/triggers/doey-test_2_0.trigger"
  ) &
  local flipper=$!

  local out="${TEST_TMP}/t1.out" err="${TEST_TMP}/t1.err"
  local elapsed rc=0
  elapsed=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="2.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="team_lead" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_PANE_ID="doey-test_2_0" \
    TMUX_PANE="%70" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TEST_TMP}/project" \
    run_with_deadline "$STM_HOOK" 8 "$out" "$err"
  ) || rc=$?

  wait "$flipper" 2>/dev/null || true

  if [ "$rc" -eq 124 ]; then
    _fail "${desc} — hung past 8s"
    return
  fi
  if [ "$elapsed" -gt 5 ]; then
    _fail "${desc} — exited but took ${elapsed}s (>5s budget)"
    return
  fi
  _pass "${desc} — exited in ${elapsed}s"
}

# ──────────────────────────────────────────────────────────────────────
# Test 2: STM wakes on inbox message within 5 seconds
# ──────────────────────────────────────────────────────────────────────
test_message_wake() {
  local desc="STM wakes on inbox message within 5s"
  if [ ! -x "$STM_HOOK" ] && [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — stm-wait.sh missing at ${STM_HOOK}"
    return
  fi
  local rt="${TEST_TMP}/rt2"
  make_runtime "$rt"

  # Drop the message ~1.5s after the hook starts.
  ( sleep 2
    local mf="${rt}/messages/doey-test_2_0_$(date +%s)_$$.msg"
    cat > "$mf" <<EOS
FROM: ${DOEY_ROLE_COORDINATOR:-Taskmaster}
TO: 2.0
SUBJECT: commit_request_ack
ACK from coordinator.
EOS
  ) &
  local dropper=$!

  local out="${TEST_TMP}/t2.out" err="${TEST_TMP}/t2.err"
  local elapsed rc=0
  elapsed=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="2.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="team_lead" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_PANE_ID="doey-test_2_0" \
    TMUX_PANE="%71" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TEST_TMP}/project" \
    run_with_deadline "$STM_HOOK" 8 "$out" "$err"
  ) || rc=$?

  wait "$dropper" 2>/dev/null || true

  if [ "$rc" -eq 124 ]; then
    _fail "${desc} — hung past 8s"
    return
  fi
  if [ "$elapsed" -gt 5 ]; then
    _fail "${desc} — exited but took ${elapsed}s (>5s budget)"
    return
  fi
  _pass "${desc} — exited in ${elapsed}s"
}

# ──────────────────────────────────────────────────────────────────────
# Test 3: role-mismatch guard on coordinator wait hook
# ──────────────────────────────────────────────────────────────────────
test_role_mismatch_warning() {
  if [ ! -f "$TM_HOOK" ]; then
    _fail "Role guard — taskmaster-wait.sh missing at ${TM_HOOK}"
    return
  fi
  local rt="${TEST_TMP}/rt3"
  make_runtime "$rt"

  # 3a: STM (team_lead) invokes coordinator hook → must warn + exit 0 fast.
  local out_a="${TEST_TMP}/t3a.out" err_a="${TEST_TMP}/t3a.err"
  local elapsed_a rc_a=0
  elapsed_a=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="2.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="team_lead" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_ROLE_ID_COORDINATOR="coordinator" \
    DOEY_PANE_ID="doey-test_2_0" \
    TMUX_PANE="%72" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TEST_TMP}/project" \
    run_with_deadline "$TM_HOOK" 8 "$out_a" "$err_a"
  ) || rc_a=$?

  if [ "$rc_a" -eq 124 ]; then
    _fail "Role guard 3a — STM invocation hung (no guard)"
  else
    if grep -qiE 'subtaskmaster|stm|stm-wait|wrong role|role mismatch' \
         "$err_a" 2>/dev/null; then
      _pass "Role guard 3a — STM invocation emits warning (elapsed=${elapsed_a}s)"
    else
      echo "  stderr was:"; sed 's/^/    /' "$err_a" 2>/dev/null | head -10
      _fail "Role guard 3a — STM invocation produced no role-mismatch warning"
    fi
  fi

  # 3b: coordinator invokes coordinator hook → must NOT emit role-mismatch.
  # Use a fresh runtime so prior state can't poison it. Coordinator pane is
  # 1.0 (Core Team window). The full wait cycle would block ~60s, so we
  # only need to assert the early portion is silent on the role channel:
  # run with a 3s budget and inspect stderr.
  local rt2="${TEST_TMP}/rt3b"
  make_runtime "$rt2"
  local out_b="${TEST_TMP}/t3b.out" err_b="${TEST_TMP}/t3b.err"
  local rc_b=0 _ignored
  _ignored=$(
    MOCK_RUNTIME="$rt2" \
    MOCK_PANE_WP="1.0" \
    DOEY_RUNTIME="$rt2" \
    DOEY_ROLE="coordinator" \
    DOEY_ROLE_ID_COORDINATOR="coordinator" \
    DOEY_PANE_ID="doey-test_1_0" \
    TMUX_PANE="%73" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TEST_TMP}/project" \
    run_with_deadline "$TM_HOOK" 3 "$out_b" "$err_b"
  ) || rc_b=$?

  if grep -qiE 'subtaskmaster|stm-wait|wrong role|role mismatch' \
       "$err_b" 2>/dev/null; then
    echo "  stderr was:"; sed 's/^/    /' "$err_b" 2>/dev/null | head -10
    _fail "Role guard 3b — coordinator invocation incorrectly warned"
  else
    _pass "Role guard 3b — coordinator invocation stays silent on role channel"
  fi
}

# --- run all tests --------------------------------------------------------
echo "--- stm-wait.sh tests (task 648) ---"
test_finished_wake
test_message_wake
test_role_mismatch_warning

echo ""
echo "=== stm-wait: ${PASS} pass, ${FAIL} fail ==="
[ "$FAIL" -eq 0 ] || exit 1
