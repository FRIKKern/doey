#!/usr/bin/env bash
# Stop hook: Capture worker results and write inbox message.
# Runs async — allowed to be slower.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

# Only workers produce results
is_worker || exit 0

TMPFILE_RESULT="" TMPFILE_INBOX=""
trap '[[ -n "${TMPFILE_RESULT:-}" ]] && rm -f "$TMPFILE_RESULT" 2>/dev/null; [[ -n "${TMPFILE_INBOX:-}" ]] && rm -f "$TMPFILE_INBOX" 2>/dev/null' EXIT

OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$PANE_INDEX" -p -S -80 2>/dev/null) || OUTPUT=""

# Filter UI noise and detect errors in a single pass
FILTERED_OUTPUT=""
RESULT_STATUS="done"
while IFS= read -r line; do
  [[ "$line" =~ ❯|───|Ctx\ █|bypass\ permissions|shift\+tab|MCP\ server|/doctor ]] && continue
  FILTERED_OUTPUT+="$line"$'\n'
  [[ "$RESULT_STATUS" == "done" ]] && [[ "$line" =~ (^|[[:space:]])(error|Error|ERROR|failed|Failed|FAILED|exception|Exception|EXCEPTION)([[:space:]]|:|$) ]] && RESULT_STATUS="error"
done <<< "$OUTPUT"

# Get pane title for identification
PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:0.$PANE_INDEX" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"

LAST_OUTPUT=$(jq -Rs '.' <<< "$FILTERED_OUTPUT" 2>/dev/null) || \
  LAST_OUTPUT=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$FILTERED_OUTPUT" 2>/dev/null) || \
  LAST_OUTPUT='""'

TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

# --- Write result JSON ---
TMPFILE_RESULT=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_RESULT=""
if [[ -z "$TMPFILE_RESULT" ]]; then
  # Fallback: direct write if mktemp fails (full disk, missing dir, etc.)
  TMPFILE_RESULT="$RUNTIME_DIR/results/pane_${PANE_INDEX}.json"
fi
cat > "$TMPFILE_RESULT" <<EOF
{
  "pane": "0.$PANE_INDEX",
  "title": $TITLE_JSON,
  "status": "$RESULT_STATUS",
  "timestamp": $(date +%s),
  "last_output": $LAST_OUTPUT
}
EOF
[[ "$TMPFILE_RESULT" != *"pane_${PANE_INDEX}.json" ]] && mv "$TMPFILE_RESULT" "$RUNTIME_DIR/results/pane_${PANE_INDEX}.json"
TMPFILE_RESULT=""

# --- Write human-readable inbox message for the manager ---
SAFE_TITLE=$(printf '%s' "$PANE_TITLE" | tr -cd '[:alnum:]._-')
SAFE_TIME=$(echo "${NOW##*T}" | tr ':+' '-p')
INBOX_FILE="$RUNTIME_DIR/inbox/${NOW%%T*}_${SAFE_TIME}_pane${PANE_INDEX}_${SAFE_TITLE}.md"
TMPFILE_INBOX=$(mktemp "${RUNTIME_DIR}/inbox/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_INBOX="$INBOX_FILE"
cat > "$TMPFILE_INBOX" <<INBOX
# Worker 0.${PANE_INDEX} — ${PANE_TITLE} — ${RESULT_STATUS}

${FILTERED_OUTPUT}
INBOX
[[ "$TMPFILE_INBOX" != "$INBOX_FILE" ]] && mv "$TMPFILE_INBOX" "$INBOX_FILE"
TMPFILE_INBOX=""

exit 0
