#!/usr/bin/env bash
# Claude Code hook: updates worker status files in the team runtime directory.
# Called on UserPromptSubmit and Stop events.

set -euo pipefail

# Read JSON from stdin
INPUT=$(cat)

# Bail silently if not in tmux
if [ -z "${TMUX_PANE:-}" ] || ! tmux display-message -t "${TMUX_PANE}" -p '' >/dev/null 2>&1; then
  exit 0
fi

# Get runtime dir — bail if not set
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

# Get pane identity
# IMPORTANT: Use -t "$TMUX_PANE" to resolve THIS pane's identity, not the client's focused pane.
# Without -t, tmux display-message returns info for whichever pane the user is viewing (usually 0.0),
# which caused ALL workers to think they were the Manager and spam notifications.
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_SAFE=${PANE//[:.]/_}

# Ensure status dir exists
mkdir -p "${RUNTIME_DIR}/status"
mkdir -p "${RUNTIME_DIR}/research"
mkdir -p "${RUNTIME_DIR}/reports"

# Parse hook event name
if command -v jq >/dev/null 2>&1; then
  EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null) || EVENT=""
  PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null) || PROMPT=""
  LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null) || LAST_MSG=""
  STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || STOP_HOOK_ACTIVE="false"
else
  EVENT=$(echo "$INPUT" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null) || EVENT=""
  PROMPT=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"prompt"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null) || PROMPT=""
  LAST_MSG=$(echo "$INPUT" | grep -o '"last_assistant_message"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"last_assistant_message"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null) || LAST_MSG=""
  STOP_HOOK_ACTIVE=$(echo "$INPUT" | grep -o '"stop_hook_active"[[:space:]]*:[[:space:]]*[a-z]*' | sed 's/.*:[[:space:]]*//' 2>/dev/null) || STOP_HOOK_ACTIVE="false"
fi

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
NOW=$(date -Iseconds)

case "$EVENT" in
  UserPromptSubmit)
    # Truncate prompt to first 80 chars for the TASK field
    TASK="${PROMPT:0:80}"
    cat > "$STATUS_FILE" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: WORKING
TASK: $TASK
EOF
    ;;
  Stop)
    # Extract pane identity components for use throughout Stop handler
    SESSION_NAME="${PANE%%:*}"
    PANE_INDEX="${PANE##*.}"

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
    # Read WATCHDOG_PANE from the session manifest to identify ourselves.
    if [ -f "${RUNTIME_DIR}/session.env" ]; then
      WATCHDOG_PANE_INDEX=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" | cut -d= -f2)
      if [ "$PANE_INDEX" = "$WATCHDOG_PANE_INDEX" ]; then
        # If stop_hook_active is true, this is already a retry — allow some breathing room
        if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
          sleep 2
        fi
        echo "You are the Watchdog. Do NOT stop. Continue your monitoring loop — check all worker panes again now." >&2
        exit 2
      fi
    fi

    # --- Result capture for worker panes ---
    # Capture structured result data so the Manager can read JSON instead of scraping pane output.
    # Skip Manager (pane 0.0) and Watchdog.
    WINDOW_AND_PANE_FOR_RESULT="${PANE#*:}"
    IS_WORKER=true
    if [ "$WINDOW_AND_PANE_FOR_RESULT" = "0.0" ]; then
      IS_WORKER=false
    elif [ -f "${RUNTIME_DIR}/session.env" ] && [ "${PANE_INDEX}" = "$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)" ]; then
      IS_WORKER=false
    fi

    if [ "$IS_WORKER" = true ]; then
      PANE_SAFE_RESULT="pane_${PANE_INDEX}"
      mkdir -p "$RUNTIME_DIR/results"

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

      # JSON-encode the last 5 lines of output safely
      LAST_OUTPUT=$(echo "$OUTPUT" | tail -5 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || LAST_OUTPUT='""'

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

    # Send macOS notification — ONLY for the Manager pane (0.0)
    # Workers and Watchdog do not notify — only the Manager talks to the user
    WINDOW_AND_PANE="${PANE#*:}"
    if [ "$WINDOW_AND_PANE" = "0.0" ] && [ "$STOP_HOOK_ACTIVE" != "true" ] && [ -n "$LAST_MSG" ]; then
      # Filter out UI artifact messages (status bar, permission prompts, etc.)
      if echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯"; then
        : # Skip — this is UI chrome, not a real message
      else
        NOTIFY_BODY="${LAST_MSG:0:150}"
        NOTIFY_BODY="${NOTIFY_BODY//\"/\'}"
        NOTIFY_BODY=$(printf '%s' "$NOTIFY_BODY" | tr '\n' ' ')
        osascript -e "display notification \"${NOTIFY_BODY}\" with title \"Doey — Manager\" sound name \"Ping\"" &
      fi
    fi
    ;;
  *)
    # Unknown event — do nothing
    ;;
esac

exit 0
