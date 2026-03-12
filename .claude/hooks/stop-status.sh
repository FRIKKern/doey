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

# --- Write status file ---
cat > "$STATUS_FILE" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF

exit 0
