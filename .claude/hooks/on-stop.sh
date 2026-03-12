#!/usr/bin/env bash
# Claude Code hook: Stop — write status, capture results, get out of the way.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# --- Watchdog keep-alive ---
if is_watchdog; then
  echo "Continue monitoring." >&2
  exit 2
fi

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
  OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$PANE_INDEX" -p -S -20 2>/dev/null) || OUTPUT=""

  if echo "$OUTPUT" | grep -qiE '(error|failed|exception)'; then
    RESULT_STATUS="error"
  else
    RESULT_STATUS="done"
  fi

  LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | jq -Rs '.' 2>/dev/null) || \
    LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
    LAST_OUTPUT='""'

  cat > "$RUNTIME_DIR/results/pane_${PANE_INDEX}.json" <<EOF
{
  "pane": "0.$PANE_INDEX",
  "status": "$RESULT_STATUS",
  "timestamp": $(date +%s),
  "last_output": $LAST_OUTPUT
}
EOF
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
