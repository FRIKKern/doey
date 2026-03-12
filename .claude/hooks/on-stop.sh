#!/usr/bin/env bash
# Claude Code hook: Stop — state machine (BUSY→FINISHED→READY idle loop),
# research enforcement, Watchdog keep-alive, result capture, notifications.
#
# Worker lifecycle:
#   Task dispatched → BUSY (prompt-submit)
#   Task done       → BUSY (pre-simplify, sends /simplify)
#   /simplify done  → FINISHED (captures results, enters idle loop)
#   Idle heartbeat  → READY (5s sleep loop, fresh timestamps)
#   New task        → BUSY (prompt-submit, after Manager kills+restarts)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

LAST_MSG=$(parse_field "last_assistant_message")
STOP_HOOK_ACTIVE=$(parse_field "stop_hook_active")
[ -z "$STOP_HOOK_ACTIVE" ] && STOP_HOOK_ACTIVE="false"

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
SIMPLIFY_FLAG="${RUNTIME_DIR}/status/simplify_done_${PANE_INDEX}.flag"

# --- Determine stop status ---
# Read current status to distinguish idle loop (FINISHED/READY) from pre-simplify (BUSY)
CURRENT_STATUS=""
if [ -f "$STATUS_FILE" ]; then
  while IFS= read -r line; do
    if [[ "$line" == STATUS:* ]]; then
      CURRENT_STATUS="${line#STATUS: }"
      break
    fi
  done < "$STATUS_FILE"
fi

if is_reserved; then
  STOP_STATUS="RESERVED"
elif is_worker; then
  if [ -f "$SIMPLIFY_FLAG" ]; then
    # Post-simplify: task fully complete → FINISHED
    STOP_STATUS="FINISHED"
  elif [ "$CURRENT_STATUS" = "FINISHED" ] || [ "$CURRENT_STATUS" = "READY" ]; then
    # Idle loop: already done, refresh timestamp → READY
    STOP_STATUS="READY"
  else
    # Pre-simplify: real task just completed → stay BUSY
    STOP_STATUS="BUSY"
  fi
else
  STOP_STATUS="READY"
fi

cat > "$STATUS_FILE" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: ${STOP_STATUS}
TASK:
EOF

# --- Research report enforcement ---
TASK_FILE="${RUNTIME_DIR}/research/${PANE_SAFE}.task"
REPORT_FILE="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
if [ -f "$TASK_FILE" ] && [ ! -f "$REPORT_FILE" ]; then
  RESEARCH_TOPIC=$(cat "$TASK_FILE" 2>/dev/null)
  echo "STOP BLOCKED: You have a pending research task but have not written your report yet." >&2
  echo "" >&2
  echo "Research topic: ${RESEARCH_TOPIC}" >&2
  echo "" >&2
  echo "You MUST write your research report before stopping. Write a structured report to:" >&2
  echo "${REPORT_FILE}" >&2
  echo "" >&2
  echo "Report format (write this exact structure):" >&2
  echo "## Research Report" >&2
  echo "**Topic:** (the research question)" >&2
  echo "**Pane:** (your pane ID)" >&2
  echo "**Time:** (current timestamp)" >&2
  echo "" >&2
  echo "### Findings" >&2
  echo "(your detailed findings — be thorough)" >&2
  echo "" >&2
  echo "### Key Files" >&2
  echo "(list of relevant files with brief descriptions)" >&2
  echo "" >&2
  echo "### Recommendations" >&2
  echo "(actionable recommendations for the Manager)" >&2
  echo "" >&2
  echo "Use the Write tool to create the file at the path above, then you may stop." >&2
  exit 2
fi
if [ -f "$TASK_FILE" ] && [ -f "$REPORT_FILE" ]; then
  rm -f "$TASK_FILE"
fi

# --- Watchdog keep-alive ---
if is_watchdog; then
  if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    sleep 2
  fi
  echo "You are the Watchdog. Do NOT stop. Continue your monitoring loop — check all worker panes again now." >&2
  exit 2
fi

# --- Result capture (only on real task completion, not idle heartbeats) ---
if is_worker && [ "$STOP_STATUS" = "BUSY" ]; then
  PANE_SAFE_RESULT="pane_${PANE_INDEX}"
  OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$PANE_INDEX" -p -S -20 2>/dev/null) || OUTPUT=""

  if echo "$OUTPUT" | grep -qiE '(error|failed|✗|exception)'; then
    RESULT_STATUS="error"
  else
    RESULT_STATUS="done"
  fi

  PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:0.$PANE_INDEX" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE=""
  PANE_TITLE_ESCAPED="${PANE_TITLE//\\/\\\\}"
  PANE_TITLE_ESCAPED="${PANE_TITLE_ESCAPED//\"/\\\"}"

  LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | jq -Rs '.' 2>/dev/null) || \
    LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
    LAST_OUTPUT='""'

  cat > "$RUNTIME_DIR/results/${PANE_SAFE_RESULT}.json" <<EOF
{
  "pane": "0.$PANE_INDEX",
  "status": "$RESULT_STATUS",
  "title": "$PANE_TITLE_ESCAPED",
  "timestamp": $(date +%s),
  "last_output": $LAST_OUTPUT
}
EOF
fi

# --- Simplify + idle loop for workers ---
# Three possible states:
#   BUSY     → real task just finished: capture results above, send /simplify
#   FINISHED → /simplify just finished: clean up flag, enter idle loop
#   READY    → idle heartbeat: stay alive, sleep 5s
if is_worker; then
  if [ "$STOP_STATUS" = "BUSY" ]; then
    # Pre-simplify: set flag and send /simplify
    touch "$SIMPLIFY_FLAG"
    tmux copy-mode -q -t "$PANE" 2>/dev/null || true
    sleep 1
    tmux send-keys -t "$PANE" "/simplify" Enter 2>/dev/null || true
    # Allow this stop — /simplify arrives as new input
    :
  elif [ "$STOP_STATUS" = "FINISHED" ]; then
    # Post-simplify: clean up flag, block stop to enter idle loop
    rm -f "$SIMPLIFY_FLAG"
    echo "Task complete. Run: sleep 5" >&2
    exit 2
  elif [ "$STOP_STATUS" = "READY" ]; then
    # Idle heartbeat: keep alive, status timestamp already refreshed above
    echo "Waiting for tasks. Run: sleep 5" >&2
    exit 2
  fi
fi

# --- macOS notification — ONLY for the Manager pane (0.0) ---
if is_manager && [ "$STOP_HOOK_ACTIVE" != "true" ] && [ -n "$LAST_MSG" ]; then
  if echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯"; then
    : # Skip UI chrome
  else
    NOTIFY_BODY="${LAST_MSG:0:150}"
    NOTIFY_BODY="${NOTIFY_BODY//\"/\'}"
    NOTIFY_BODY=$(printf '%s' "$NOTIFY_BODY" | tr '\n' ' ')
    send_notification "Doey — Manager" "$NOTIFY_BODY"
  fi
fi

exit 0
