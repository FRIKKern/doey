#!/usr/bin/env bash
# Claude Code hook: UserPromptSubmit — updates pane status
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

PROMPT=$(parse_field "prompt")
TASK="${PROMPT:0:80}"

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# Maintenance commands: don't change status (except /compact → READY)
case "$PROMPT" in
  /compact*)
    # After compact, context is clean → READY
    cat > "$STATUS_FILE" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: READY
TASK:
EOF
    exit 0
    ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*)
    # Internal commands — don't change status
    exit 0
    ;;
esac

NEW_STATUS="BUSY"

cat > "$STATUS_FILE" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: $NEW_STATUS
TASK: $TASK
EOF

exit 0
