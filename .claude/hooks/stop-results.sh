#!/usr/bin/env bash
# Stop hook: capture worker results and write completion event (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

is_worker || exit 0

PANE_ADDR="$SESSION_NAME:$WINDOW_INDEX.$PANE_INDEX"
RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE=""
trap '[ -n "${TMPFILE:-}" ] && rm -f "$TMPFILE" 2>/dev/null' EXIT

OUTPUT=$(tmux capture-pane -t "$PANE_ADDR" -p -S -80 2>/dev/null) || OUTPUT=""

# Filter UI noise and detect errors in one pass
FILTERED=""
STATUS="done"
while IFS= read -r line; do
  case "$line" in
    *"❯"*|*"───"*|*"Ctx █"*|*"bypass permissions"*|*"shift+tab"*|*"MCP server"*|*/doctor*) continue ;;
  esac
  FILTERED="${FILTERED}${line}${NL}"
  if [ "$STATUS" = "done" ]; then
    case "$line" in
      *[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*) STATUS="error" ;;
    esac
  fi
done <<< "$OUTPUT"

PANE_TITLE=$(tmux display-message -t "$PANE_ADDR" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"
LAST_JSON=$(jq -Rs '.' <<< "$FILTERED" 2>/dev/null) || \
  LAST_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$FILTERED" 2>/dev/null) || \
  LAST_JSON='""'
TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

# Write result JSON (atomic: tmp + mv)
TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null) || TMPFILE="$RESULT_FILE"
cat > "$TMPFILE" <<EOF
{
  "pane": "$WINDOW_INDEX.$PANE_INDEX",
  "title": $TITLE_JSON,
  "status": "$STATUS",
  "timestamp": $(date +%s),
  "last_output": $LAST_JSON
}
EOF
[ "$TMPFILE" != "$RESULT_FILE" ] && mv "$TMPFILE" "$RESULT_FILE"
TMPFILE=""

# Write completion event for watchdog
COMPLETION="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION}.tmp" "$COMPLETION"

# Wake watchdog (event-driven instead of 30s poll)
touch "${RUNTIME_DIR}/status/watchdog_trigger_W${WINDOW_INDEX}" 2>/dev/null || true

exit 0
