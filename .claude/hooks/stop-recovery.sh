#!/usr/bin/env bash
# Stop hook (async): classify worker errors and auto-retry transient failures
# Runs AFTER stop-results.sh (which writes the result JSON) and BEFORE stop-notify.sh.
# On transient error: retries once by respawning the worker.
# On permanent error or retry exhausted: lets stop-notify.sh handle escalation.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-recovery"

# Only act on workers
is_worker || exit 0

# --- Read current status ---
_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
_cur_status=""
if [ -f "$_status_file" ]; then
  _cur_status=$(grep '^STATUS:' "$_status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //') || _cur_status=""
fi

# Only act on ERROR or error-status results
_result_file="${RUNTIME_DIR}/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
_result_status=""
if [ -f "$_result_file" ]; then
  if command -v jq >/dev/null 2>&1; then
    _result_status=$(jq -r '.status // "done"' "$_result_file" 2>/dev/null) || _result_status=""
  elif command -v python3 >/dev/null 2>&1; then
    _result_status=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','done'))" "$_result_file" 2>/dev/null) || _result_status=""
  fi
fi

# Exit early if no error detected
case "$_cur_status" in *ERROR*) ;; *)
  case "$_result_status" in error) ;; *) exit 0 ;; esac
;; esac

_log "stop-recovery: error detected for ${PANE_SAFE} (status=${_cur_status}, result=${_result_status})"

# --- Recovery log helper ---
mkdir -p "${RUNTIME_DIR}/issues" "${RUNTIME_DIR}/recovery" 2>/dev/null || true

_recovery_log() {
  local error_type="$1" action="$2" details="$3"
  printf '%s | %s | %s | %s | %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$PANE_SAFE" "$error_type" "$action" "$details" \
    >> "${RUNTIME_DIR}/issues/recovery.log" 2>/dev/null
}

# --- Gather error context ---
_last_msg=$(parse_field "last_assistant_message") || _last_msg=""
_last_output=""
if [ -f "$_result_file" ]; then
  if command -v jq >/dev/null 2>&1; then
    _last_output=$(jq -r '.last_output // ""' "$_result_file" 2>/dev/null) || _last_output=""
  fi
fi
_error_text="${_last_msg} ${_last_output}"

# --- Error Classification ---
_error_type="permanent"

# Transient patterns: API/network/context issues that may resolve on retry
case "$_error_text" in
  *overloaded*|*"rate limit"*|*"rate_limit"*|*503*|*529*|*"service unavailable"*)
    _error_type="transient" ;;
  *ECONNRESET*|*ETIMEDOUT*|*"network error"*|*"connection refused"*|*"fetch failed"*)
    _error_type="transient" ;;
  *timeout*|*SIGKILL*|*"timed out"*)
    _error_type="transient" ;;
  *"context window"*|*"token limit"*|*"too long"*|*"max.*tokens"*)
    _error_type="transient" ;;
  *InputValidationError*)
    _error_type="transient" ;;
esac

# Zero tool calls with error = likely process crash (transient)
_tool_count="0"
if [ -f "$_result_file" ]; then
  if command -v jq >/dev/null 2>&1; then
    _tool_count=$(jq -r '.tool_calls // 0' "$_result_file" 2>/dev/null) || _tool_count="0"
  fi
fi
if [ "$_tool_count" = "0" ] && [ "$_result_status" = "error" ]; then
  _error_type="transient"
fi

# Permanent overrides: these should never be retried
case "$_error_text" in
  *"blocked by hook"*|*"on-pre-tool-use"*|*"hook block"*)
    _error_type="permanent" ;;
  *"authentication"*|*"unauthorized"*|*"403"*|*"401"*)
    _error_type="permanent" ;;
  *"No such file"*|*ENOENT*)
    _error_type="permanent" ;;
  *EACCES*|*"permission denied"*)
    _error_type="permanent" ;;
esac

_log "stop-recovery: classified ${PANE_SAFE} error as ${_error_type}"

# --- Retry counter ---
_retry_file="${RUNTIME_DIR}/recovery/${PANE_SAFE}.retry_count"
_retry_count=$(cat "$_retry_file" 2>/dev/null) || _retry_count=0

# --- Handle permanent errors or exhausted retries ---
if [ "$_error_type" = "permanent" ] || [ "$_retry_count" -ge 1 ]; then
  _reason="permanent error"
  [ "$_retry_count" -ge 1 ] && _reason="retry exhausted (${_retry_count}/1)"
  _recovery_log "$_error_type" "escalate" "${_reason}"
  _log "stop-recovery: escalating ${PANE_SAFE} — ${_reason}"

  # Clean up recovery state
  rm -f "${RUNTIME_DIR}/recovery/${PANE_SAFE}.recovering" 2>/dev/null || true
  rm -f "$_retry_file" 2>/dev/null || true

  # Log recovery event to task system
  PROJECT_DIR=$(_resolve_project_dir)
  _task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || _task_id=""
  if [ -n "$_task_id" ] && [ -n "$PROJECT_DIR" ] && [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
    (
      source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
      _task_file="${PROJECT_DIR}/.doey/tasks/${_task_id}.task"
      [ -f "$_task_file" ] && task_add_recovery_event "$_task_file" "escalate" "$PANE_SAFE" "subtaskmaster" "Error type: ${_error_type}. ${_reason}."
    ) 2>/dev/null || true
  fi

  exit 0  # Let stop-notify.sh send the error notification
fi

# --- Auto-retry transient error ---
_log "stop-recovery: auto-retrying transient error for ${PANE_SAFE} (attempt $((_retry_count + 1))/1)"
_recovery_log "$_error_type" "retry" "attempt $((_retry_count + 1))"

# Increment retry counter
_retry_count=$((_retry_count + 1))
printf '%s\n' "$_retry_count" > "$_retry_file"

# Write recovery marker (stop-notify.sh checks this to skip notification)
printf 'RECOVERING\nERROR_TYPE: %s\nTIMESTAMP: %s\n' "$_error_type" "$(date +%s)" \
  > "${RUNTIME_DIR}/recovery/${PANE_SAFE}.recovering"

# Log recovery event to task system
PROJECT_DIR=$(_resolve_project_dir)
_task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || _task_id=""
if [ -n "$_task_id" ] && [ -n "$PROJECT_DIR" ] && [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
  (
    source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
    _task_file="${PROJECT_DIR}/.doey/tasks/${_task_id}.task"
    [ -f "$_task_file" ] && task_add_recovery_event "$_task_file" "auto_retry" "$PANE_SAFE" "$PANE_SAFE" "Transient ${_error_type} error, respawning worker"
  ) 2>/dev/null || true
fi

# Transition ERROR -> READY
transition_state "$PANE_SAFE" "READY" 2>/dev/null || true

# Emit recovery event
if command -v doey-ctl >/dev/null 2>&1; then
  (doey event log --type worker_recovery --source "$PANE_SAFE" \
    --message "Auto-retry: ${_error_type} error" \
    --project-dir "${PROJECT_DIR:-}" &) 2>/dev/null
fi

# --- Relaunch worker ---
# Read saved launch command
_launch_cmd=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.launch_cmd" 2>/dev/null) || _launch_cmd=""
if [ -z "$_launch_cmd" ]; then
  _launch_cmd="claude --dangerously-skip-permissions --model opus"
  [ -f "${RUNTIME_DIR}/doey-settings.json" ] && \
    _launch_cmd="${_launch_cmd} --settings \"${RUNTIME_DIR}/doey-settings.json\""
fi

# Kill existing Claude process in pane
_pane_pid=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null) || _pane_pid=""
if [ -n "$_pane_pid" ]; then
  _child=$(pgrep -P "$_pane_pid" 2>/dev/null | head -1) || _child=""
  if [ -n "$_child" ]; then
    kill "$_child" 2>/dev/null || true
    sleep 0.5
    _child=$(pgrep -P "$_pane_pid" 2>/dev/null | head -1) || _child=""
    [ -n "$_child" ] && kill -9 "$_child" 2>/dev/null || true
  fi
fi

sleep 1

# Verify pane still exists before relaunching
if ! tmux display-message -t "$PANE" -p '#{pane_pid}' >/dev/null 2>&1; then
  _log "stop-recovery: pane ${PANE} no longer exists — aborting relaunch"
  _recovery_log "$_error_type" "abort" "pane gone"
  rm -f "${RUNTIME_DIR}/recovery/${PANE_SAFE}.recovering" 2>/dev/null || true
  exit 0
fi

# Ensure doey_send_command is available
if ! type doey_send_command >/dev/null 2>&1; then
  for _try in \
    "$(cd "$(dirname "$0")/../../shell" 2>/dev/null && pwd)/doey-send.sh" \
    "$HOME/.local/bin/doey-send.sh"; do
    if [ -f "$_try" ]; then source "$_try"; break; fi
  done
fi

if type doey_send_command >/dev/null 2>&1; then
  doey_send_command "$PANE" "$_launch_cmd"
  _log "stop-recovery: relaunched ${PANE_SAFE} with saved launch command"
  _recovery_log "$_error_type" "relaunched" "command sent"
else
  _log_error "RECOVERY" "doey_send_command not available — cannot relaunch" "pane=$PANE_SAFE"
  _recovery_log "$_error_type" "failed" "doey_send_command not found"
  rm -f "${RUNTIME_DIR}/recovery/${PANE_SAFE}.recovering" 2>/dev/null || true
fi

type _debug_log >/dev/null 2>&1 && _debug_log lifecycle "recovery" "pane=$PANE_SAFE" "error_type=$_error_type" "retry=$_retry_count"

exit 0
