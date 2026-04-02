#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "on-prompt-submit"

PROMPT=$(parse_field "prompt")
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

case "$PROMPT" in
  /compact*)
    if command -v doey-ctl >/dev/null 2>&1; then
      doey-ctl status set "$PANE_SAFE" "READY"
    else
      write_pane_status "$STATUS_FILE" "READY"
    fi
    notify_taskmaster "READY" "compact"; exit 0 ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*) exit 0 ;;
esac

# Block workers without task assignment (Task Accountability)
if is_worker && ! is_reserved; then
  _task_id_file="${RUNTIME_DIR}/status/${PANE_SAFE}.task_id"
  _has_task=""
  # Primary: check pre-written task_id file
  if [ -f "$_task_id_file" ] && [ -s "$_task_id_file" ]; then
    _has_task="true"
  fi
  # Fallback: check prompt for Task #N pattern
  if [ -z "$_has_task" ]; then
    _prompt_task=$(printf '%s' "$PROMPT" | grep -oE 'Task #[0-9]+' | head -1) || _prompt_task=""
    [ -n "$_prompt_task" ] && _has_task="true"
  fi
  if [ -z "$_has_task" ]; then
    _log "BLOCKED: no task assigned to pane ${PANE_SAFE}"
    printf '{"decision":"block","message":"No task assigned to this pane. Dispatch via Subtaskmaster."}\n'
    exit 2
  fi
fi

if command -v doey-ctl >/dev/null 2>&1; then
  doey-ctl status set "$PANE_SAFE" "BUSY"
else
  write_pane_status "$STATUS_FILE" "BUSY" "${PROMPT:0:80}"
fi
type _debug_log >/dev/null 2>&1 && _debug_log state "transition" "from=READY" "to=BUSY" "trigger=prompt-submit"
if [ -n "${DOEY_PANE_ID:-}" ]; then
  if command -v doey-ctl >/dev/null 2>&1; then
    doey-ctl status set "${DOEY_PANE_ID}" "BUSY"
  else
    write_pane_status "${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status" "BUSY" "${PROMPT:0:80}"
  fi
fi

# Activity logging
_prompt_safe=$(printf '%s' "${PROMPT:0:120}" | tr '"\\' '__')
write_activity "status_change" '{"status":"BUSY"}'
write_activity "task_assigned" "{\"task\":\"${_prompt_safe}\"}"

notify_taskmaster "BUSY" "${PROMPT:0:60}"
_log "task started: $(echo "$PROMPT" | head -c 80)"

# Persist task ID for stop hooks — file-first, regex fallback
if is_worker; then
  _task_id_file="${RUNTIME_DIR}/status/${PANE_SAFE}.task_id"
  _task_num=""
  # Primary: read from pre-written task_id file (set by dispatch)
  if [ -f "$_task_id_file" ] && [ -s "$_task_id_file" ]; then
    _task_num=$(head -1 "$_task_id_file" | tr -cd '0-9')
  fi
  # Fallback: extract Task #N from prompt text
  if [ -z "$_task_num" ]; then
    _task_num=$(printf '%s' "$PROMPT" | grep -oE 'Task #[0-9]+' | head -1 | sed 's/Task #//') || _task_num=""
    # Write to file so stop hooks find it
    if [ -n "$_task_num" ]; then
      printf '%s\n' "$_task_num" > "$_task_id_file"
      _log "task_id persisted via fallback: ${_task_num}"
    fi
  fi
  if [ -n "$_task_num" ]; then
    tmux set-environment -t "$SESSION_NAME" "DOEY_TASK_ID_${PANE_SAFE}" "$_task_num" 2>/dev/null || true
    _log "task_id: ${_task_num}"
    # Extract subtask number if present
    _subtask_num=$(printf '%s' "$PROMPT" | grep -oEi '(Subtask|subtask:)[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+' | tail -1) || _subtask_num=""
    if [ -n "$_subtask_num" ]; then
      printf '%s\n' "$_subtask_num" > "${RUNTIME_DIR}/status/${PANE_SAFE}.subtask_id"
      tmux set-environment -t "$SESSION_NAME" "DOEY_SUBTASK_ID_${PANE_SAFE}" "$_subtask_num" 2>/dev/null || true
      _log "subtask_id: ${_subtask_num}"
    fi
  fi
fi

if is_taskmaster; then
  touch "${RUNTIME_DIR}/status/taskmaster_trigger" 2>/dev/null || true
  touch "${RUNTIME_DIR}/triggers/${PANE_SAFE}.trigger" 2>/dev/null || true
fi

if is_worker && [ "$PANE_INDEX" -gt 0 ]; then
  collapsed="${RUNTIME_DIR}/status/col_$(( (PANE_INDEX - 1) / 2 )).collapsed"
  if [ -f "$collapsed" ]; then
    tmux resize-pane -t "${PANE}" -x 80 2>/dev/null || true
    rm -f "$collapsed"
  fi
fi

exit 0
