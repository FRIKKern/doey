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

exit 0
