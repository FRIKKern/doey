#!/usr/bin/env bash
# Claude Code hook: Stop — marks pane as IDLE, enforces research reports,
# keeps Watchdog alive, captures worker results, notifies Manager.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

LAST_MSG=$(parse_field "last_assistant_message")
STOP_HOOK_ACTIVE=$(parse_field "stop_hook_active")
[ -z "$STOP_HOOK_ACTIVE" ] && STOP_HOOK_ACTIVE="false"

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# Write IDLE status
cat > "$STATUS_FILE" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: IDLE
TASK:
EOF

# --- Research report enforcement ---
# If this pane has a pending research task but no report, block the stop.
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
# If task AND report both exist, clean up the task marker (research complete)
if [ -f "$TASK_FILE" ] && [ -f "$REPORT_FILE" ]; then
  rm -f "$TASK_FILE"
fi

# --- Watchdog keep-alive ---
# If this is the Watchdog pane, block the stop so it keeps monitoring.
if is_watchdog; then
  # If stop_hook_active is true, this is already a retry — allow some breathing room
  if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    sleep 2
  fi
  echo "You are the Watchdog. Do NOT stop. Continue your monitoring loop — check all worker panes again now." >&2
  exit 2
fi

# --- Result capture for worker panes ---
# Capture structured result data so the Manager can read JSON instead of scraping pane output.
if is_worker; then
  PANE_SAFE_RESULT="pane_${PANE_INDEX}"

  # Capture last 20 lines of pane output
  OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$PANE_INDEX" -p -S -20 2>/dev/null) || OUTPUT=""

  # Determine status based on output
  if echo "$OUTPUT" | grep -qiE '(error|failed|✗|exception)'; then
    RESULT_STATUS="error"
  else
    RESULT_STATUS="done"
  fi

  # Extract pane title (task name) for context
  PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:0.$PANE_INDEX" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE=""

  # JSON-encode the last 5 lines of output safely (prefer jq over python3 for speed)
  LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | jq -Rs '.' 2>/dev/null) || \
    LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
    LAST_OUTPUT='""'

  # Write result file
  cat > "$RUNTIME_DIR/results/${PANE_SAFE_RESULT}.json" <<EOF
{
  "pane": "0.$PANE_INDEX",
  "status": "$RESULT_STATUS",
  "title": "$PANE_TITLE",
  "timestamp": $(date +%s),
  "last_output": $LAST_OUTPUT
}
EOF
fi

# --- Auto-simplify for workers ---
# After a real task completes, send /simplify to review changed code.
# Uses a flag file to prevent infinite loops (simplify -> stop -> simplify -> ...).
if is_worker; then
  SIMPLIFY_FLAG="${RUNTIME_DIR}/status/simplify_done_${PANE_INDEX}.flag"
  if [ -f "$SIMPLIFY_FLAG" ]; then
    # Worker just finished /simplify — remove flag, don't loop
    rm -f "$SIMPLIFY_FLAG"
  else
    # Real task completion — set flag and send /simplify
    touch "$SIMPLIFY_FLAG"
    tmux copy-mode -q -t "$PANE" 2>/dev/null || true
    sleep 1
    tmux send-keys -t "$PANE" "/simplify" Enter
  fi
fi

# --- macOS notification — ONLY for the Manager pane (0.0) ---
# Workers and Watchdog do not notify — only the Manager talks to the user
if is_manager && [ "$STOP_HOOK_ACTIVE" != "true" ] && [ -n "$LAST_MSG" ]; then
  # Filter out UI artifact messages (status bar, permission prompts, etc.)
  if echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯"; then
    : # Skip — this is UI chrome, not a real message
  else
    NOTIFY_BODY="${LAST_MSG:0:150}"
    NOTIFY_BODY="${NOTIFY_BODY//\"/\'}"
    NOTIFY_BODY=$(printf '%s' "$NOTIFY_BODY" | tr '\n' ' ')
    send_notification "Doey — Manager" "$NOTIFY_BODY"
  fi
fi

exit 0
