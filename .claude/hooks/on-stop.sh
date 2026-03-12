#!/usr/bin/env bash
# Claude Code hook: Stop — write status, capture results, get out of the way.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# --- Watchdog: no keep-alive ---
# The watchdog is allowed to stop between scan cycles.
# /loop (configured in doey.sh) periodically wakes it to resume scanning.

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

# --- Result capture for workers ---
if is_worker; then
  OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$PANE_INDEX" -p -S -80 2>/dev/null) || OUTPUT=""

  # Filter UI noise and detect errors in a single pass
  FILTERED_OUTPUT=""
  RESULT_STATUS="done"
  while IFS= read -r line; do
    [[ "$line" =~ ❯|───|Ctx\ █|bypass\ permissions|shift\+tab|MCP\ server|/doctor ]] && continue
    FILTERED_OUTPUT+="$line"$'\n'
    [[ "$RESULT_STATUS" == "done" ]] && [[ "$line" =~ [Ee]rror|[Ff]ailed|[Ee]xception ]] && RESULT_STATUS="error"
  done <<< "$OUTPUT"

  # Get pane title for identification
  PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:0.$PANE_INDEX" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"

  LAST_OUTPUT=$(jq -Rs '.' <<< "$FILTERED_OUTPUT" 2>/dev/null) || \
    LAST_OUTPUT=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$FILTERED_OUTPUT" 2>/dev/null) || \
    LAST_OUTPUT='""'

  TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

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

  # Write human-readable inbox message for the manager
  SAFE_TITLE=$(printf '%s' "$PANE_TITLE" | tr -cd '[:alnum:]._-')
  SAFE_TIME=$(echo "${NOW##*T}" | tr ':+' '-p')
  INBOX_FILE="$RUNTIME_DIR/inbox/${NOW%%T*}_${SAFE_TIME}_pane${PANE_INDEX}_${SAFE_TITLE}.md"
  TMPFILE_INBOX=$(mktemp "${RUNTIME_DIR}/inbox/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_INBOX="$INBOX_FILE"
  cat > "$TMPFILE_INBOX" <<INBOX
# Worker 0.${PANE_INDEX} — ${PANE_TITLE} — ${RESULT_STATUS}

${FILTERED_OUTPUT}
INBOX
  [[ "$TMPFILE_INBOX" != "$INBOX_FILE" ]] && mv "$TMPFILE_INBOX" "$INBOX_FILE"
fi

# --- macOS notification for Manager ---
if is_manager; then
  LAST_MSG=$(parse_field "last_assistant_message")
  if [ -n "$LAST_MSG" ]; then
    if ! echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯"; then
      NOTIFY_BODY=$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")
      send_notification "Doey — Manager" "$NOTIFY_BODY"
    fi
  fi
fi

exit 0
