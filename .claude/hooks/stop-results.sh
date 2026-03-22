#!/usr/bin/env bash
# Stop hook: capture worker results and write completion event (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

is_worker || exit 0

# Ensure tasks directory exists for crash-recovery prompt storage
mkdir -p "$RUNTIME_DIR/tasks" 2>/dev/null || true

RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE=""
trap '[ -n "${TMPFILE:-}" ] && rm -f "$TMPFILE" 2>/dev/null' EXIT

OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -80 2>/dev/null) || OUTPUT=""

# Count tool calls from captured output
TOOL_COUNT=0
while IFS= read -r line; do
  case "$line" in
    *"Read("*|*"Edit("*|*"Write("*|*"Bash("*|*"Grep("*|*"Glob("*|*"Agent("*) TOOL_COUNT=$((TOOL_COUNT + 1)) ;;
  esac
done <<< "$OUTPUT"

# Get files changed by this worker via git
PROJECT_DIR=$(tmux show-environment DOEY_TEAM_DIR 2>/dev/null | cut -d= -f2-) || PROJECT_DIR=""
FILES_LIST=""
if [ -n "$PROJECT_DIR" ]; then
  FILES_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only HEAD 2>/dev/null | head -20) || FILES_LIST=""
fi
FILES_JSON="[]"
if [ -n "$FILES_LIST" ]; then
  FILES_JSON=$(echo "$FILES_LIST" | jq -R '.' | jq -s '.' 2>/dev/null) || FILES_JSON="[]"
fi

FILTERED=""
STATUS="done"
while IFS= read -r line; do
  # UI chrome filters — update if Claude Code output format changes
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

PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"
LAST_JSON=$(jq -Rs '.' <<< "$FILTERED" 2>/dev/null) || \
  LAST_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$FILTERED" 2>/dev/null) || \
  LAST_JSON='""'
TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null) || TMPFILE="$RESULT_FILE"
cat > "$TMPFILE" <<EOF
{
  "pane": "$WINDOW_INDEX.$PANE_INDEX",
  "title": $TITLE_JSON,
  "status": "$STATUS",
  "timestamp": $(date +%s),
  "files_changed": $FILES_JSON,
  "tool_calls": $TOOL_COUNT,
  "last_output": $LAST_JSON
}
EOF
[ "$TMPFILE" != "$RESULT_FILE" ] && mv "$TMPFILE" "$RESULT_FILE"
TMPFILE=""

# Completion event for watchdog
COMPLETION="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION}.tmp" "$COMPLETION"

# Wake watchdog
touch "${RUNTIME_DIR}/status/watchdog_trigger_W${WINDOW_INDEX}" 2>/dev/null || true

exit 0
