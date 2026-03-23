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

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
TMP=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null)
if [ -z "$TMP" ] || [ ! -f "$TMP" ]; then
  echo "[WARN] mktemp failed in $(basename "$0") — writing non-atomically" >> "${RUNTIME_DIR}/doey-warnings.log" 2>/dev/null
  TMP="$STATUS_FILE"
fi
cat > "$TMP" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF
[ "$TMP" != "$STATUS_FILE" ] && mv "$TMP" "$STATUS_FILE"

# Dual-write using short DOEY_PANE_ID for new-style lookups
if [ -n "${DOEY_PANE_ID:-}" ]; then
  ID_STATUS_FILE="${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status"
  TMP2=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null)
  if [ -z "$TMP2" ] || [ ! -f "$TMP2" ]; then
    TMP2="$ID_STATUS_FILE"
  fi
  cat > "$TMP2" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF
  [ "$TMP2" != "$ID_STATUS_FILE" ] && mv "$TMP2" "$ID_STATUS_FILE"
  _log "stop-status: ${DOEY_PANE_ID} -> $STOP_STATUS (dual-write)"
fi

exit 0
