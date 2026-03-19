#!/usr/bin/env bash
# Stop hook: Write pane status (RESERVED / FINISHED / READY).
# Critical path — must be fast and synchronous.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# --- Research enforcement: block stop if task exists but no report ---
# Must run BEFORE writing status, otherwise FINISHED is written then exit 2 leaves stale status.
# Skip reserved workers — humans using reserved panes shouldn't be blocked.
if is_worker && ! is_reserved; then
  TASK_FILE="${RUNTIME_DIR}/research/${PANE_SAFE}.task"
  REPORT_FILE="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
  if [ -f "$TASK_FILE" ] && [ ! -f "$REPORT_FILE" ]; then
    echo '{"decision": "block", "reason": "Research task requires a report. Write your report to '"${REPORT_FILE}"' using the Write tool before stopping."}'
    exit 2
  fi
fi

# --- Determine status ---
STOP_STATUS="READY"
is_worker && STOP_STATUS="FINISHED"
is_reserved && STOP_STATUS="RESERVED"

# --- Write status file (atomic: tmp + mv) ---
TMPFILE_STATUS=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_STATUS="$STATUS_FILE"
cat > "$TMPFILE_STATUS" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF
[ "$TMPFILE_STATUS" != "$STATUS_FILE" ] && mv "$TMPFILE_STATUS" "$STATUS_FILE"

exit 0
