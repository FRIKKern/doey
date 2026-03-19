#!/usr/bin/env bash
# Stop hook: Capture worker results and write completion event.
# Runs async — allowed to be slower.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

# Only workers produce results
is_worker || exit 0

PANE_ADDR="$SESSION_NAME:$WINDOW_INDEX.$PANE_INDEX"
RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE_RESULT=""
trap '[ -n "${TMPFILE_RESULT:-}" ] && rm -f "$TMPFILE_RESULT" 2>/dev/null' EXIT

OUTPUT=$(tmux capture-pane -t "$PANE_ADDR" -p -S -80 2>/dev/null) || OUTPUT=""

# Filter UI noise and detect errors in a single pass
FILTERED_OUTPUT=""
RESULT_STATUS="done"
while IFS= read -r line; do
  case "$line" in
    *"❯"*|*"───"*|*"Ctx █"*|*"bypass permissions"*|*"shift+tab"*|*"MCP server"*|*/doctor*) continue ;;
  esac
  FILTERED_OUTPUT="${FILTERED_OUTPUT}${line}${NL}"
  if [ "$RESULT_STATUS" = "done" ]; then
    case "$line" in
      *[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*) RESULT_STATUS="error" ;;
    esac
  fi
done <<< "$OUTPUT"

PANE_TITLE=$(tmux display-message -t "$PANE_ADDR" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"

LAST_OUTPUT=$(jq -Rs '.' <<< "$FILTERED_OUTPUT" 2>/dev/null) || \
  LAST_OUTPUT=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$FILTERED_OUTPUT" 2>/dev/null) || \
  LAST_OUTPUT='""'

TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

# --- Write result JSON (atomic: tmp + mv) ---
TMPFILE_RESULT=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_RESULT="$RESULT_FILE"
cat > "$TMPFILE_RESULT" <<EOF
{
  "pane": "$WINDOW_INDEX.$PANE_INDEX",
  "title": $TITLE_JSON,
  "status": "$RESULT_STATUS",
  "timestamp": $(date +%s),
  "last_output": $LAST_OUTPUT
}
EOF
[ "$TMPFILE_RESULT" != "$RESULT_FILE" ] && mv "$TMPFILE_RESULT" "$RESULT_FILE"
TMPFILE_RESULT=""

# --- Write completion event for watchdog ---
COMPLETION_FILE="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION_FILE}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$RESULT_STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION_FILE}.tmp" "$COMPLETION_FILE"

# --- Wake watchdog immediately (event-driven instead of 30s poll) ---
touch "${RUNTIME_DIR}/status/watchdog_trigger_W${WINDOW_INDEX}" 2>/dev/null || true

exit 0
