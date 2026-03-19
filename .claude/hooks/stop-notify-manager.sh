#!/usr/bin/env bash
# Stop hook: notify Window Manager when a worker finishes (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

is_worker || exit 0

MGR_PANE="$SESSION_NAME:$WINDOW_INDEX.0"
tmux display-message -t "$MGR_PANE" -p '#{pane_pid}' >/dev/null 2>&1 || exit 0

PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="W${PANE_INDEX}"

# Read status from result JSON (written by stop-results.sh)
RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
STATUS="done"
if [ -f "$RESULT_FILE" ]; then
  STATUS=$(jq -r '.status // "done"' "$RESULT_FILE" 2>/dev/null) \
    || STATUS=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('status','done'))" < "$RESULT_FILE" 2>/dev/null) \
    || STATUS="done"
fi

MSG="Worker ${PANE_TITLE} finished (${STATUS})"
LAST_MSG=$(parse_field "last_assistant_message")
[ -n "$LAST_MSG" ] && MSG="${MSG}: $(sanitize_message "$LAST_MSG" 100)"

send_to_pane "$MGR_PANE" "$MSG"

exit 0
