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

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
TMP=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || TMP="$STATUS_FILE"
cat > "$TMP" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF
[ "$TMP" != "$STATUS_FILE" ] && mv "$TMP" "$STATUS_FILE"

exit 0
