#!/usr/bin/env bash
# Claude Code hook: UserPromptSubmit — marks pane as WORKING
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

PROMPT=$(parse_field "prompt")
TASK="${PROMPT:0:80}"

cat > "${RUNTIME_DIR}/status/${PANE_SAFE}.status" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: WORKING
TASK: $TASK
EOF

# Auto-reserve pane for 60 seconds when human types
# (Only for workers — Manager and Watchdog don't get reserved)
# Don't downgrade a permanent or longer reservation to 60s
if is_worker && ! is_reserved; then
  reserve_pane 60
fi

exit 0
