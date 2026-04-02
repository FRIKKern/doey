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
    # Write to SQLite store
    _project_dir=$(_resolve_project_dir)
    if command -v doey-ctl >/dev/null 2>&1 && [ -n "${_project_dir:-}" ]; then
      doey-ctl db-status set --pane-id "$PANE_SAFE" --window-id "W${WINDOW_INDEX}" \
        --role "${DOEY_ROLE:-worker}" --status "READY" --dir "$_project_dir" 2>/dev/null || true
    fi
    notify_taskmaster "READY" "compact"; exit 0 ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*) exit 0 ;;
esac

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

# Write to SQLite store
_project_dir=$(_resolve_project_dir)
if command -v doey-ctl >/dev/null 2>&1 && [ -n "${_project_dir:-}" ]; then
  doey-ctl db-status set --pane-id "$PANE_SAFE" --window-id "W${WINDOW_INDEX}" \
    --role "${DOEY_ROLE:-worker}" --status "BUSY" --dir "$_project_dir" 2>/dev/null || true
fi

# Activity logging
_prompt_safe=$(printf '%s' "${PROMPT:0:120}" | tr '"\\' '__')
write_activity "status_change" '{"status":"BUSY"}'
write_activity "task_assigned" "{\"task\":\"${_prompt_safe}\"}"

notify_taskmaster "BUSY" "${PROMPT:0:60}"
_log "task started: $(echo "$PROMPT" | head -c 80)"

# Persist task ID for stop hooks — extract Task #N from dispatch prompts
if is_worker; then
  _task_num=$(printf '%s' "$PROMPT" | grep -oE 'Task #[0-9]+' | head -1 | sed 's/Task #//') || _task_num=""
  if [ -n "$_task_num" ]; then
    printf '%s\n' "$_task_num" > "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id"
    _log "task_id persisted: ${_task_num}"
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
