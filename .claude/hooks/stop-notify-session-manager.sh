#!/usr/bin/env bash
# Stop hook: Notify Session Manager when a Window Manager finishes.
# Runs async.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

# Only managers notify the Session Manager
is_manager || exit 0

# Only notify if the manager was actually BUSY (had a real task).
# Skip if status file says READY or doesn't exist — avoids notification loops
# when a manager goes idle without ever receiving work.
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
if [ -f "$STATUS_FILE" ]; then
  _cur_status=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
  _cur_status="${_cur_status#STATUS: }"
  case "$_cur_status" in
    BUSY) ;;  # Was working — proceed with notification
    *) exit 0 ;;  # READY/FINISHED/etc — no real work done, skip
  esac
else
  exit 0  # No status file — never received a task
fi

# Find Session Manager pane (Dashboard window 0)
SM_PANE=$(get_sm_pane)

# Check SM pane is alive — fail silently if not
tmux display-message -t "$SESSION_NAME:${SM_PANE}" -p '#{pane_pid}' >/dev/null 2>&1 || exit 0

# Build summary from last assistant message (sanitize before truncating)
LAST_MSG=$(parse_field "last_assistant_message")
SUMMARY=$(sanitize_message "$LAST_MSG" 150)
[ -z "$SUMMARY" ] && SUMMARY="(no summary)"

MSG="Team ${WINDOW_INDEX} Manager finished: ${SUMMARY}"

# Send to Session Manager
send_to_pane "$SESSION_NAME:${SM_PANE}" "$MSG"

exit 0
