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

  # Filter UI noise from captured output
  FILTERED_OUTPUT=$(echo "$OUTPUT" | grep -vE '❯|───|Ctx █|bypass permissions|shift\+tab|MCP server|/doctor' | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }') || FILTERED_OUTPUT=""

  if echo "$FILTERED_OUTPUT" | grep -qiE '(error|failed|exception)'; then
    RESULT_STATUS="error"
  else
    RESULT_STATUS="done"
  fi

  # Get pane title for identification
  PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:0.$PANE_INDEX" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"

  LAST_OUTPUT=$(echo "$FILTERED_OUTPUT" | jq -Rs '.' 2>/dev/null) || \
    LAST_OUTPUT=$(echo "$FILTERED_OUTPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
    LAST_OUTPUT='""'

  TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

  cat > "$RUNTIME_DIR/results/pane_${PANE_INDEX}.json" <<EOF
{
  "pane": "0.$PANE_INDEX",
  "title": $TITLE_JSON,
  "status": "$RESULT_STATUS",
  "timestamp": $(date +%s),
  "last_output": $LAST_OUTPUT
}
EOF

  # Write human-readable inbox message for the manager
  mkdir -p "$RUNTIME_DIR/inbox"
  cat > "$RUNTIME_DIR/inbox/$(date +%s)_pane${PANE_INDEX}_${PANE_TITLE}.md" <<INBOX
# Worker 0.${PANE_INDEX} — ${PANE_TITLE} — ${RESULT_STATUS}

${FILTERED_OUTPUT}
INBOX
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
