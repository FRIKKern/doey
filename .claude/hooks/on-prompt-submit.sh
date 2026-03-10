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

exit 0
