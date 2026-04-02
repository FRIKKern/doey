#!/usr/bin/env bash
# Stop hook: write pane status (synchronous)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-status"

if is_worker && ! is_reserved; then
  REPORT_FILE="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
  if [ -f "${RUNTIME_DIR}/research/${PANE_SAFE}.task" ] && [ ! -f "$REPORT_FILE" ]; then
    echo '{"decision": "block", "reason": "Research task requires a report. Write your report to '"${REPORT_FILE}"' using the Write tool before stopping."}'
    exit 2
  fi
fi

STOP_STATUS="READY"
is_worker && STOP_STATUS="FINISHED"
is_reserved && STOP_STATUS="RESERVED"

_log "stop-status: $PANE_SAFE -> $STOP_STATUS"

task_id="${DOEY_TASK_ID:-}"
# Fallback: read task ID persisted by on-prompt-submit
if [ -z "$task_id" ]; then
  task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || task_id=""
fi

PROJECT_DIR=$(_resolve_project_dir)

_last_task_tags="" _last_task_type="" _last_files=""
if [ "$STOP_STATUS" = "FINISHED" ]; then
  if [ -n "$task_id" ] && [ -n "$PROJECT_DIR" ]; then
    _taskfile="${PROJECT_DIR}/.doey/tasks/${task_id}.task"
    if [ -f "$_taskfile" ]; then
      _last_task_tags=$(grep "^TASK_TAGS=" "$_taskfile" 2>/dev/null | cut -d= -f2-) || _last_task_tags=""
      _last_task_type=$(grep "^TASK_TYPE=" "$_taskfile" 2>/dev/null | cut -d= -f2-) || _last_task_type=""
    fi
  fi
  _result_file="${RUNTIME_DIR}/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
  if [ -f "$_result_file" ]; then
    _last_files=$(sed -n '/"files_changed"/,/]/p' "$_result_file" 2>/dev/null \
      | grep '"' | sed 's/.*"\(.*\)".*/\1/' | tr '\n' '|' | sed 's/|$//') || _last_files=""
  fi
  [ -z "$_last_files" ] && _last_files=$(timeout 2 git diff --name-only HEAD 2>/dev/null | head -20 | tr '\n' '|' | sed 's/|$//') || _last_files=""
fi

for _sf in "$PANE_SAFE" "${DOEY_PANE_ID:-}"; do
  [ -z "$_sf" ] && continue
  _status_file="${RUNTIME_DIR}/status/${_sf}.status"
  write_pane_status "$_status_file" "$STOP_STATUS"
  [ ! -f "$_status_file" ] && _log_error "HOOK_ERROR" "Failed to write status file" "pane=$_sf status=$STOP_STATUS"
  [ -n "$task_id" ] && printf 'TASK_ID: %s\n' "$task_id" >> "$_status_file"
  [ "$STOP_STATUS" = "FINISHED" ] && \
    printf 'LAST_TASK_TAGS: %s\nLAST_TASK_TYPE: %s\nLAST_FILES: %s\n' "$_last_task_tags" "$_last_task_type" "$_last_files" >> "$_status_file"
done

rm -f "${RUNTIME_DIR}/status/${PANE_SAFE}.heartbeat" 2>/dev/null || true
{ [ -n "${DOEY_PANE_ID:-}" ] && rm -f "${RUNTIME_DIR}/status/${DOEY_PANE_ID//[-:.]/_}.heartbeat" 2>/dev/null; } || true

if [ -n "$task_id" ] && [ -n "$PROJECT_DIR" ] && [ -d "${PROJECT_DIR}/.doey/tasks" ]; then
  _persistent_status="${PROJECT_DIR}/.doey/tasks/${task_id}.status"
  printf '%s\n' "$STOP_STATUS" > "$_persistent_status" 2>/dev/null || true

  # Update .task file status on worker completion
  if [ "$STOP_STATUS" = "FINISHED" ] && [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
    (
      source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
      task_update_status "$PROJECT_DIR" "$task_id" "done"
    ) 2>/dev/null || true
  fi
fi

type _debug_log >/dev/null 2>&1 && _debug_log state "transition" "from=BUSY" "to=${STOP_STATUS}" "trigger=stop-status"
write_activity "status_change" "{\"status\":\"${STOP_STATUS}\"}"

notify_taskmaster "$STOP_STATUS"

if is_taskmaster; then
  (
    sleep 3
    _taskmaster_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if [ -f "$_taskmaster_status_file" ]; then
      case "$(head -1 "$_taskmaster_status_file" 2>/dev/null || true)" in
        *BUSY*) exit 0 ;;
      esac
    fi
    touch "${RUNTIME_DIR}/status/taskmaster_trigger" 2>/dev/null || true
    touch "${RUNTIME_DIR}/triggers/${PANE_SAFE}.trigger" 2>/dev/null || true
  ) &
fi

exit 0
