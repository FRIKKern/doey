#!/usr/bin/env bash
# Stop hook: write pane status (synchronous)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="stop-status"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

# Block workers with unfinished research reports
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

write_pane_status "${RUNTIME_DIR}/status/${PANE_SAFE}.status" "$STOP_STATUS"
[ ! -f "${RUNTIME_DIR}/status/${PANE_SAFE}.status" ] && _log_error "HOOK_ERROR" "Failed to write status file" "pane=$PANE_SAFE status=$STOP_STATUS"

# Dual-write using short DOEY_PANE_ID for new-style lookups
if [ -n "${DOEY_PANE_ID:-}" ]; then
  write_pane_status "${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status" "$STOP_STATUS"
  [ ! -f "${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status" ] && _log_error "HOOK_ERROR" "Failed to write status file" "pane=$DOEY_PANE_ID status=$STOP_STATUS"
  _log "stop-status: ${DOEY_PANE_ID} -> $STOP_STATUS (dual-write)"
fi

type _debug_log >/dev/null 2>&1 && _debug_log state "transition" "from=BUSY" "to=${STOP_STATUS}" "trigger=stop-status"

notify_watchdog "$STOP_STATUS"

# Watchdog self-sustaining loop: after stop, re-trigger a new scan cycle
# The hook IS the loop — no /loop command needed
if is_watchdog; then
  _wd_pane="${DOEY_PANE_ID:-${PANE}}"
  _wd_session="${SESSION:-}"
  [ -z "$_wd_session" ] && _wd_session=$(tmux show-environment DOEY_SESSION 2>/dev/null | cut -d= -f2-) || true
  _wd_target="${_wd_session}:${_wd_pane}"
  (
    sleep 3
    # Guard: only send if watchdog is READY (not already BUSY from another trigger)
    _wd_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if [ -f "$_wd_status_file" ]; then
      _wd_cur=$(head -1 "$_wd_status_file" 2>/dev/null || true)
      case "$_wd_cur" in
        *BUSY*) exit 0 ;;  # Already processing, skip re-trigger
      esac
    fi
    tmux send-keys -t "$_wd_target" "Scan cycle — check workers, report anomalies." Enter 2>/dev/null
  ) &
fi

# Session Manager self-sustaining loop: after stop, re-trigger to check messages/results
if is_session_manager; then
  _sm_pane="0.1"
  _sm_session="${SESSION:-}"
  [ -z "$_sm_session" ] && _sm_session=$(tmux show-environment DOEY_SESSION 2>/dev/null | cut -d= -f2-) || true
  _sm_target="${_sm_session}:${_sm_pane}"
  (
    sleep 3
    # Guard: only send if SM is READY (not already BUSY from another trigger)
    _sm_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if [ -f "$_sm_status_file" ]; then
      _sm_cur=$(head -1 "$_sm_status_file" 2>/dev/null || true)
      case "$_sm_cur" in
        *BUSY*) exit 0 ;;  # Already processing, skip re-trigger
      esac
    fi
    tmux send-keys -t "$_sm_target" "Check for messages and results." Enter 2>/dev/null
  ) &
fi

exit 0
