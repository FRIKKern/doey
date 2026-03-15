#!/usr/bin/env bash
# Stop hook: Write pane status (RESERVED / FINISHED / READY).
# Critical path — must be fast and synchronous.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# --- Determine status ---
if is_reserved; then
  STOP_STATUS="RESERVED"
elif is_worker; then
  STOP_STATUS="FINISHED"
else
  STOP_STATUS="READY"
fi

# --- Research enforcement: block stop if task exists but no report ---
# Must run BEFORE writing status so FINISHED isn't written on a blocked stop.
if is_worker; then
  TASK_FILE="${RUNTIME_DIR}/research/${PANE_SAFE}.task"
  REPORT_FILE="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
  if [ -f "$TASK_FILE" ] && [ ! -f "$REPORT_FILE" ]; then
    echo '{"decision": "block", "reason": "Research task requires a report. Write your report to '"${REPORT_FILE}"' using the Write tool before stopping."}' >&2
    exit 2
  fi
fi

# --- Write status file (atomic: tmp + mv) ---
TMPFILE_STATUS=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_STATUS="$STATUS_FILE"
cat > "$TMPFILE_STATUS" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF
case "$TMPFILE_STATUS" in
  "$STATUS_FILE") ;;
  *) mv "$TMPFILE_STATUS" "$STATUS_FILE" ;;
esac

exit 0
