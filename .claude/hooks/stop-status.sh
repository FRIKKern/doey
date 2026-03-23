#!/usr/bin/env bash
# Stop hook: write pane status (synchronous)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

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

_write_status() {
  local target="$1" tmp
  tmp=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null)
  if [ -z "$tmp" ] || [ ! -f "$tmp" ]; then tmp="$target"; fi
  cat > "$tmp" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF
  [ "$tmp" != "$target" ] && mv "$tmp" "$target"
}

_write_status "${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# Dual-write using short DOEY_PANE_ID for new-style lookups
if [ -n "${DOEY_PANE_ID:-}" ]; then
  _write_status "${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status"
  _log "stop-status: ${DOEY_PANE_ID} -> $STOP_STATUS (dual-write)"
fi

exit 0
