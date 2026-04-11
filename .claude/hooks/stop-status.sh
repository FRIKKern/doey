#!/usr/bin/env bash
# Stop hook: write pane status (synchronous)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-status"

mkdir -p "${RUNTIME_DIR}/errors" 2>/dev/null || true
trap '_err=$?; printf "[%s] ERR in stop-status at line %s (exit %s)\n" "$(date +%H:%M:%S)" "$LINENO" "$_err" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null; printf "ERROR" > "${RUNTIME_DIR}/panes/${PANE_SAFE}/status" 2>/dev/null; if command -v doey-ctl >/dev/null 2>&1; then _proj="${DOEY_PROJECT_DIR:-}"; [ -z "$_proj" ] && _proj=$(git rev-parse --show-toplevel 2>/dev/null) || true; [ -n "$_proj" ] && (doey event log --type error_crash --source "${PANE_SAFE:-unknown}" --data "stop-status ERR line=${LINENO} exit=${_err}" --project-dir "$_proj" &) 2>/dev/null; fi; exit 0' ERR

# Check for respawn request
_respawning=false
if [ -f "${RUNTIME_DIR}/respawn/${PANE_SAFE}.request" ]; then
  _respawning=true
fi

if is_worker && ! is_reserved; then
  REPORT_FILE="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
  if [ -f "${RUNTIME_DIR}/research/${PANE_SAFE}.task" ] && [ ! -f "$REPORT_FILE" ]; then
    echo '{"decision": "block", "reason": "Research task requires a report. Write your report to '"${REPORT_FILE}"' using the Write tool before stopping."}'
    exit 2
  fi

  # Proof gate: workers must emit PROOF_TYPE before finishing (skip when respawning)
  if [ "$_respawning" != "true" ] && [ "${DOEY_PROOF_EXEMPT:-0}" != "1" ]; then
    _proof_found=""
    # Check 1: file-based proof (written by worker via bash echo > file)
    _proof_file="${RUNTIME_DIR}/proof/${PANE_SAFE}.proof"
    if [ -f "$_proof_file" ]; then
      _proof_found=$(grep '^PROOF_TYPE:' "$_proof_file" | tail -1) || _proof_found=""
    fi
    # Proof must be in the file — terminal scraping removed (structured data only)
    if [ -z "$_proof_found" ]; then
      echo '{"decision": "block", "reason": "Workers must emit PROOF_TYPE: <type> and PROOF: <summary> before stopping. Write proof via: mkdir -p '${RUNTIME_DIR}/proof' && echo PROOF_TYPE:... > '${RUNTIME_DIR}/proof/${PANE_SAFE}.proof'. Or set DOEY_PROOF_EXEMPT=1 for research/docs."}'
      exit 2
    fi
  fi
fi

STOP_STATUS="READY"
is_worker && STOP_STATUS="FINISHED"
is_reserved && STOP_STATUS="RESERVED"
[ "$_respawning" = "true" ] && STOP_STATUS="RESPAWNING"

_log "stop-status: $PANE_SAFE -> $STOP_STATUS"

task_id="${DOEY_TASK_ID:-}"
# Fallback: read task ID persisted by on-prompt-submit
if [ -z "$task_id" ]; then
  task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || task_id=""
fi
subtask_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.subtask_id" 2>/dev/null) || subtask_id=""
# Note: task_id/subtask_id files NOT deleted — needed by async stop hooks

PROJECT_DIR=$(_resolve_project_dir)

_last_task_tags="" _last_task_type="" _last_files=""
if [ "$STOP_STATUS" = "FINISHED" ]; then
  if [ -n "$task_id" ] && [ -n "$PROJECT_DIR" ]; then
    if command -v doey-ctl >/dev/null 2>&1; then
      _tinfo=$(doey-ctl task get --id "$task_id" --project-dir "$PROJECT_DIR" 2>/dev/null) || _tinfo=""
      _last_task_type=$(echo "$_tinfo" | sed -n 's/^Type:[[:space:]]*//p')
      # Tags not in doey-ctl task get output — fall back to file
      _last_task_tags=""
    fi
    if [ -z "$_last_task_type" ]; then
      _taskfile="${PROJECT_DIR}/.doey/tasks/${task_id}.task"
      if [ -f "$_taskfile" ]; then
        _last_task_tags=$(grep "^TASK_TAGS=" "$_taskfile" 2>/dev/null | cut -d= -f2-) || _last_task_tags=""
        _last_task_type=$(grep "^TASK_TYPE=" "$_taskfile" 2>/dev/null | cut -d= -f2-) || _last_task_type=""
      fi
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
  if command -v doey-ctl >/dev/null 2>&1; then
    doey status set "$_sf" "$STOP_STATUS"
  else
    transition_state "$_sf" "$STOP_STATUS"
  fi
  [ ! -f "$_status_file" ] && _log_error "HOOK_ERROR" "Failed to write status file" "pane=$_sf status=$STOP_STATUS"
  [ -n "$task_id" ] && printf 'TASK_ID: %s\n' "$task_id" >> "$_status_file"
  [ "$STOP_STATUS" = "FINISHED" ] && \
    printf 'LAST_TASK_TAGS: %s\nLAST_TASK_TYPE: %s\nLAST_FILES: %s\n' "$_last_task_tags" "$_last_task_type" "$_last_files" >> "$_status_file"
done

# Strip runtime fields from status files (no longer relevant after stop)
for _sf in "$PANE_SAFE" "${DOEY_PANE_ID:-}"; do
  [ -z "$_sf" ] && continue
  _status_file="${RUNTIME_DIR}/status/${_sf}.status"
  if [ -f "$_status_file" ]; then
    grep -v '^TOOL: \|^ACTIVITY: \|^SINCE: \|^LAST_ACTIVITY: ' "$_status_file" > "${_status_file}.tmp" 2>/dev/null || cp "$_status_file" "${_status_file}.tmp"
    mv "${_status_file}.tmp" "$_status_file"
  fi
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
      # Auto-update subtask status (Task Accountability)
      if [ -n "$subtask_id" ]; then
        doey_task_update_subtask "$PROJECT_DIR" "$task_id" "$subtask_id" "done"
      fi
    ) 2>/dev/null || true
    # Sync to DB via doey-ctl (file update above is the fallback)
    if command -v doey-ctl >/dev/null 2>&1; then
      doey-ctl task update --id "$task_id" --status done --project-dir "$PROJECT_DIR" 2>/dev/null || true
      if [ -n "$subtask_id" ]; then
        doey-ctl task subtask update --task-id "$task_id" --subtask-id "$subtask_id" \
          --status done --worker "${PANE_SAFE:-}" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      fi
      doey-ctl task log add --task-id "$task_id" --type "completion" \
        --author "${PANE_SAFE:-worker}" --title "Worker completed task" \
        --project-dir "$PROJECT_DIR" 2>/dev/null || true
    fi
  fi
fi

type _debug_log >/dev/null 2>&1 && _debug_log state "transition" "from=BUSY" "to=${STOP_STATUS}" "trigger=stop-status"
write_activity "status_change" "{\"status\":\"${STOP_STATUS}\"}"

# Emit task lifecycle events (fire-and-forget, non-blocking)
if [ -n "$task_id" ] && command -v doey-ctl >/dev/null 2>&1; then
  case "$STOP_STATUS" in
    FINISHED)
      (doey event log --type task_completed --source "$PANE_SAFE" --task-id "$task_id" --message "Worker finished task" &) 2>/dev/null
      ;;
    ERROR)
      (doey event log --type task_failed --source "$PANE_SAFE" --task-id "$task_id" --message "Worker encountered error" &) 2>/dev/null
      ;;
    RESPAWNING)
      (doey event log --type worker_respawning --source "$PANE_SAFE" --task-id "$task_id" --message "Worker respawning" &) 2>/dev/null
      ;;
  esac
fi

# --- Stats emits (task #521 Phase 2) — additive, silent-fail, non-blocking ---
_dur_ms=""
_start_ms_file="${RUNTIME_DIR}/status/${PANE_SAFE}.busy_started_ms"
if [ -f "$_start_ms_file" ]; then
  _start_ms=$(cat "$_start_ms_file" 2>/dev/null) || _start_ms=""
  if [ -n "$_start_ms" ]; then
    _now_ms=$(_ms_now 2>/dev/null) || _now_ms=""
    if [ -n "$_now_ms" ]; then
      _dur_ms=$(( _now_ms - _start_ms ))
      [ "$_dur_ms" -lt 0 ] && _dur_ms=""
    fi
  fi
fi
if command -v doey-stats-emit.sh >/dev/null 2>&1; then
  case "$STOP_STATUS" in
    FINISHED)
      (doey-stats-emit.sh task task_completed "status=completed" "task_id=${task_id}" "duration_ms=${_dur_ms}" "exit_code=0" &) 2>/dev/null || true
      ;;
    ERROR)
      (doey-stats-emit.sh task task_failed "status=failed" "task_id=${task_id}" "exit_code=1" &) 2>/dev/null || true
      ;;
  esac
fi
unset _dur_ms _start_ms_file _start_ms _now_ms

if ! is_taskmaster; then
  notify_taskmaster "$STOP_STATUS"
fi

if is_taskmaster; then
  # Taskmaster self-trigger: re-wake after cooldown if not already busy
  (
    sleep 3
    _taskmaster_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if command -v doey-ctl >/dev/null 2>&1; then
      _tm_cur=$(doey status get "$PANE_SAFE")
    else
      _tm_cur=$(grep '^STATUS: ' "$_taskmaster_status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //' || true)
    fi
    case "$_tm_cur" in
      *BUSY*) exit 0 ;;
    esac
    touch "${RUNTIME_DIR}/status/taskmaster_trigger" 2>/dev/null || true
    touch "${RUNTIME_DIR}/triggers/${PANE_SAFE}.trigger" 2>/dev/null || true
  ) &
fi

exit 0
