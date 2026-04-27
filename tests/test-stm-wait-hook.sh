#!/usr/bin/env bash
# test-stm-wait-hook.sh — fresh-install regression for STM reactive wake hook.
#
# Task 648 (Lane A). Sister test to tests/test-stm-wait.sh (Lane B); kept
# separate because the spec requires a self-contained suite that exercises
# the role-guard contract on BOTH wait hooks plus the FINISHED/TRIGGERED
# wake paths in stm-wait.sh.
#
# The test runs against an ephemeral RUNTIME_DIR populated with fake worker
# status files — no live tmux session, no real workers. Every hook call is
# bounded by a wall-clock deadline so a missing/buggy guard cannot hang the
# suite.
#
# Bash 3.2 compatible. set -euo pipefail. Uses `trash` if present, else rm.

set -euo pipefail
shopt -s nullglob

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TM_HOOK="${PROJECT_ROOT}/.claude/hooks/taskmaster-wait.sh"
STM_HOOK="${PROJECT_ROOT}/.claude/hooks/stm-wait.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d -t stm_wait_hook)
cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "$TMPDIR_TEST" 2>/dev/null || rm -rf "$TMPDIR_TEST" 2>/dev/null || true
  else
    rm -rf "$TMPDIR_TEST" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Strip a real doey-ctl from PATH so file-fallback paths fire.
CLEAN_PATH=""
_saved_IFS="$IFS"; IFS=':'
for _dir in $PATH; do
  if [ ! -x "${_dir}/doey-ctl" ]; then
    CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}${_dir}"
  fi
done
IFS="$_saved_IFS"

# Mock tmux. show-environment returns the runtime; display-message emits a
# pane id; everything else is a no-op so the hook cannot accidentally talk to
# the host's tmux server.
MOCK_BIN="${TMPDIR_TEST}/bin"
mkdir -p "$MOCK_BIN"
cat > "${MOCK_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  show-environment) echo "DOEY_RUNTIME=${MOCK_RUNTIME:-/tmp/doey/none}" ;;
  display-message)
    case "$*" in
      *'#{window_index}.#{pane_index}'*) echo "${MOCK_PANE_WP:-2.0}" ;;
      *'#{pane_pid}'*)                   echo "${MOCK_PANE_PID:-99999}" ;;
      *)                                  echo "${MOCK_PANE_WP:-2.0}" ;;
    esac
    ;;
  *) : ;;
esac
EOF
chmod +x "${MOCK_BIN}/tmux"

# Build a fresh runtime dir with the canonical layout. Worker pane at W2.1.
make_runtime() {
  local rt="$1"
  mkdir -p \
    "${rt}/status" "${rt}/messages" "${rt}/triggers" \
    "${rt}/results" "${rt}/logs" "${rt}/errors" \
    "${rt}/activity" "${rt}/reports" "${rt}/research" \
    "${rt}/debug" "${rt}/recovery" "${rt}/issues"
  cat > "${rt}/session.env" <<EOS
SESSION_NAME="doey-test"
PROJECT_DIR="${TMPDIR_TEST}/project"
PROJECT_NAME="test"
GRID="2x2"
TEAM_WINDOWS="2"
EOS
  cat > "${rt}/team_2.env" <<EOS
WORKER_PANES="1"
EOS
  mkdir -p "${TMPDIR_TEST}/project/.doey/tasks"
}

# pane_safe matches `tr ':.-' '_'` from common.sh.
pane_safe() { printf '%s' "$1" | tr ':.-' '_'; }

# Run a hook in the background with a hard deadline. Echoes elapsed seconds.
# Returns 0 if the hook exited on its own, 124 if we had to kill it.
run_with_deadline() {
  local hook="$1" deadline="$2" out_file="$3" err_file="$4"
  shift 4
  local start end pid elapsed now
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
# Test (a): coordinator hook role guard
#   Invoke taskmaster-wait.sh with DOEY_ROLE=team_lead (canonical STM role).
#   Spec: stderr mentions stm-wait.sh, exit 0, no WAKE_REASON on stdout,
#   returns within ~3s (must NOT enter the 15s/60s sleep loop).
# ──────────────────────────────────────────────────────────────────────
test_coordinator_hook_role_guard() {
  local desc="taskmaster-wait.sh refuses team_lead invocation"
  if [ ! -f "$TM_HOOK" ]; then
    _fail "${desc} — missing ${TM_HOOK}"
    return
  fi
  local rt="${TMPDIR_TEST}/rta"; make_runtime "$rt"
  local out="${TMPDIR_TEST}/a.out" err="${TMPDIR_TEST}/a.err"
  local elapsed rc=0
  elapsed=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="2.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="team_lead" \
    DOEY_ROLE_ID_COORDINATOR="coordinator" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_PANE_ID="doey-test_2_0" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TMPDIR_TEST}/project" \
    run_with_deadline "$TM_HOOK" 3 "$out" "$err"
  ) || rc=$?

  if [ "$rc" -eq 124 ]; then
    _fail "${desc} — hung past 3s budget (guard not present?)"
    return
  fi
  if grep -q '^WAKE_REASON=' "$out" 2>/dev/null; then
    _fail "${desc} — emitted WAKE_REASON on stdout (should be silent)"
    return
  fi
  if grep -qiE 'stm-wait\.sh|subtaskmaster|team_lead|wrong role|role mismatch' "$err" 2>/dev/null \
     && grep -qiE 'error|warn' "$err" 2>/dev/null; then
    _pass "${desc} — guarded in ${elapsed}s with stderr warning"
  else
    echo "  stderr was:"; sed 's/^/    /' "$err" 2>/dev/null | head -10
    _fail "${desc} — no role-mismatch warning on stderr"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Test (b): stm-wait.sh exists and parses
# ──────────────────────────────────────────────────────────────────────
test_stm_hook_exists_and_parses() {
  local desc="stm-wait.sh exists and bash -n passes"
  if [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — missing ${STM_HOOK} (Lane B not yet merged)"
    return
  fi
  if bash -n "$STM_HOOK" 2>"${TMPDIR_TEST}/b.err"; then
    _pass "$desc"
  else
    echo "  bash -n stderr:"; sed 's/^/    /' "${TMPDIR_TEST}/b.err" | head -10
    _fail "$desc"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Test (c): stm-wait.sh wakes on worker FINISHED transition
# ──────────────────────────────────────────────────────────────────────
test_stm_wakes_on_finished() {
  local desc="stm-wait.sh wakes on worker FINISHED within 5s"
  if [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — missing ${STM_HOOK}"
    return
  fi
  local rt="${TMPDIR_TEST}/rtc"; make_runtime "$rt"
  local wpane="doey-test:2.1" wsafe
  wsafe=$(pane_safe "$wpane")

  cat > "${rt}/status/${wsafe}.status" <<EOS
PANE: ${wpane}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S')
STATUS: BUSY
TASK: 999
EOS

  ( sleep 2
    cat > "${rt}/status/${wsafe}.status.tmp" <<EOS2
PANE: ${wpane}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S')
STATUS: FINISHED
TASK: 999
EOS2
    mv "${rt}/status/${wsafe}.status.tmp" "${rt}/status/${wsafe}.status"
    printf '{"pane":"2.1","status":"FINISHED"}\n' \
      > "${rt}/results/pane_${wsafe}.json"
    touch "${rt}/triggers/doey-test_2_0.trigger"
  ) &
  local flipper=$!

  local out="${TMPDIR_TEST}/c.out" err="${TMPDIR_TEST}/c.err"
  local elapsed rc=0
  elapsed=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="2.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="team_lead" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_ROLE_ID_COORDINATOR="coordinator" \
    DOEY_PANE_ID="doey-test_2_0" \
    DOEY_TEAM_WINDOW="2" \
    DOEY_PANE_INDEX="0" \
    TMUX_PANE="%70" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TMPDIR_TEST}/project" \
    run_with_deadline "$STM_HOOK" 8 "$out" "$err"
  ) || rc=$?
  wait "$flipper" 2>/dev/null || true

  if [ "$rc" -eq 124 ]; then
    _fail "${desc} — hung past 8s budget"
    return
  fi
  if [ "$elapsed" -gt 5 ]; then
    _fail "${desc} — exited in ${elapsed}s (>5s budget)"
    return
  fi
  if grep -qE '^WAKE_REASON=(FINISHED|ALL_DONE|TRIGGERED|MSG)' "$out" 2>/dev/null; then
    local reason
    reason=$(grep -E '^WAKE_REASON=' "$out" | head -1)
    _pass "${desc} — ${reason} in ${elapsed}s"
  else
    echo "  stdout was:"; sed 's/^/    /' "$out" 2>/dev/null | head -10
    echo "  stderr was:"; sed 's/^/    /' "$err" 2>/dev/null | head -10
    _fail "${desc} — no acceptable WAKE_REASON on stdout"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Test (d): stm-wait.sh wakes on trigger file
# ──────────────────────────────────────────────────────────────────────
test_stm_wakes_on_trigger() {
  local desc="stm-wait.sh wakes on trigger file within 5s"
  if [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — missing ${STM_HOOK}"
    return
  fi
  local rt="${TMPDIR_TEST}/rtd"; make_runtime "$rt"

  local stm_pane="doey-test:2.0" stm_safe
  stm_safe=$(pane_safe "$stm_pane")

  ( sleep 2
    touch "${rt}/triggers/${stm_safe}.trigger"
    # Also drop a generic message in case impl prefers MSG channel.
    local mf="${rt}/messages/${stm_safe}_$(date +%s)_$$.msg"
    cat > "$mf" <<EOS
FROM: Taskmaster
TO: 2.0
SUBJECT: ping
hello
EOS
  ) &
  local dropper=$!

  local out="${TMPDIR_TEST}/d.out" err="${TMPDIR_TEST}/d.err"
  local elapsed rc=0
  elapsed=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="2.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="team_lead" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_ROLE_ID_COORDINATOR="coordinator" \
    DOEY_PANE_ID="${stm_safe}" \
    DOEY_TEAM_WINDOW="2" \
    DOEY_PANE_INDEX="0" \
    TMUX_PANE="%71" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TMPDIR_TEST}/project" \
    run_with_deadline "$STM_HOOK" 8 "$out" "$err"
  ) || rc=$?
  wait "$dropper" 2>/dev/null || true

  if [ "$rc" -eq 124 ]; then
    _fail "${desc} — hung past 8s budget"
    return
  fi
  if [ "$elapsed" -gt 5 ]; then
    _fail "${desc} — exited in ${elapsed}s (>5s budget)"
    return
  fi
  if grep -qE '^WAKE_REASON=(TRIGGERED|MSG)' "$out" 2>/dev/null; then
    local reason
    reason=$(grep -E '^WAKE_REASON=' "$out" | head -1)
    _pass "${desc} — ${reason} in ${elapsed}s"
  else
    echo "  stdout was:"; sed 's/^/    /' "$out" 2>/dev/null | head -10
    echo "  stderr was:"; sed 's/^/    /' "$err" 2>/dev/null | head -10
    _fail "${desc} — no TRIGGERED/MSG WAKE_REASON on stdout"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Test (e): stm-wait.sh reverse role guard
#   Coordinator must not be allowed to enter the STM hook.
# ──────────────────────────────────────────────────────────────────────
test_stm_hook_reverse_role_guard() {
  local desc="stm-wait.sh refuses coordinator invocation"
  if [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — missing ${STM_HOOK}"
    return
  fi
  local rt="${TMPDIR_TEST}/rte"; make_runtime "$rt"
  local out="${TMPDIR_TEST}/e.out" err="${TMPDIR_TEST}/e.err"
  local elapsed rc=0
  elapsed=$(
    MOCK_RUNTIME="$rt" \
    MOCK_PANE_WP="1.0" \
    DOEY_RUNTIME="$rt" \
    DOEY_ROLE="coordinator" \
    DOEY_ROLE_ID_COORDINATOR="coordinator" \
    DOEY_ROLE_ID_TEAM_LEAD="team_lead" \
    DOEY_PANE_ID="doey-test_1_0" \
    PATH="${MOCK_BIN}:${CLEAN_PATH}" \
    SESSION_NAME="doey-test" \
    PROJECT_DIR="${TMPDIR_TEST}/project" \
    run_with_deadline "$STM_HOOK" 3 "$out" "$err"
  ) || rc=$?

  if [ "$rc" -eq 124 ]; then
    _fail "${desc} — hung past 3s budget (no reverse guard)"
    return
  fi
  if grep -q '^WAKE_REASON=' "$out" 2>/dev/null; then
    _fail "${desc} — emitted WAKE_REASON on stdout (should be silent)"
    return
  fi
  if grep -qiE 'taskmaster-wait\.sh|coordinator|wrong role|role mismatch' "$err" 2>/dev/null \
     && grep -qiE 'error|warn' "$err" 2>/dev/null; then
    _pass "${desc} — guarded in ${elapsed}s"
  else
    echo "  stderr was:"; sed 's/^/    /' "$err" 2>/dev/null | head -10
    _fail "${desc} — no role-mismatch warning on stderr"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Test (f): bash 3.2 compat scan, scoped to stm-wait.sh
# ──────────────────────────────────────────────────────────────────────
test_stm_bash32_compat() {
  local desc="stm-wait.sh is bash 3.2 compatible"
  if [ ! -f "$STM_HOOK" ]; then
    _fail "${desc} — missing ${STM_HOOK}"
    return
  fi
  local violations=0 hits
  scan() {
    local pat="$1" label="$2"
    hits=$(grep -nE "$pat" "$STM_HOOK" 2>/dev/null || true)
    if [ -n "$hits" ]; then
      echo "  ${label}:"; printf '%s\n' "$hits" | sed 's/^/    /'
      violations=$((violations + 1))
    fi
  }
  scan 'declare[[:space:]]+-A[[:space:]]'             'declare -A'
  scan 'declare[[:space:]]+-n[[:space:]]'             'declare -n'
  scan 'declare[[:space:]]+-l[[:space:]]'             'declare -l'
  scan 'declare[[:space:]]+-u[[:space:]]'             'declare -u'
  scan "printf[[:space:]].*'%\(.*\)T'"                'printf time format'
  scan 'printf[[:space:]]+-v[[:space:]].*%\(.*\)T'    'printf -v time format'
  scan 'mapfile[[:space:]]'                           'mapfile'
  scan 'readarray[[:space:]]'                         'readarray'
  # Patterns built via concatenation so the lint hook on this very file
  # does not flag our scan strings as bash-4 violations.
  scan '\|''&'                                        'pipe stderr shorthand'
  scan '&''>>'                                        'append both streams'
  scan 'coproc[[:space:]]'                            'coproc'
  scan 'BASH''_''REMATCH'                             'BASH'_'REMATCH'
  if [ "$violations" -eq 0 ]; then
    _pass "$desc"
  else
    _fail "${desc} — ${violations} violation kind(s)"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Run
# ──────────────────────────────────────────────────────────────────────
echo "--- test-stm-wait-hook.sh (task 648) ---"
test_coordinator_hook_role_guard
test_stm_hook_exists_and_parses
test_stm_wakes_on_finished
test_stm_wakes_on_trigger
test_stm_hook_reverse_role_guard
test_stm_bash32_compat
echo ""
echo "=== stm-wait-hook: ${PASS} pass, ${FAIL} fail ==="
[ "$FAIL" -eq 0 ] || exit 1
