#!/usr/bin/env bash
# Stop hook: Notify the Window Manager when a worker finishes.
# Runs async.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

# Only workers notify
is_worker || exit 0

# Window Manager is always pane 0 of the worker's team window
MGR_PANE="$SESSION_NAME:$WINDOW_INDEX.0"

# Verify the Manager pane exists
tmux display-message -t "$MGR_PANE" -p '#{pane_pid}' >/dev/null 2>&1 || exit 0

# Get worker identity from pane title
PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:$WINDOW_INDEX.$PANE_INDEX" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="W${PANE_INDEX}"

# Get result status from result JSON (written by stop-results.sh, which runs before us)
RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
STATUS="done"
if [ -f "$RESULT_FILE" ]; then
  STATUS=$(jq -r '.status // "done"' "$RESULT_FILE" 2>/dev/null) \
    || STATUS=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('status','done'))" < "$RESULT_FILE" 2>/dev/null) \
    || STATUS="done"
fi

# Build notification message
MSG="Worker ${PANE_TITLE} finished (${STATUS})"
LAST_MSG=$(parse_field "last_assistant_message")
[ -n "$LAST_MSG" ] && MSG="${MSG}: $(sanitize_message "$LAST_MSG" 100)"

# Send to Window Manager
send_to_pane "$MGR_PANE" "$MSG"

exit 0
