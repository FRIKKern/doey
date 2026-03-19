#!/usr/bin/env bash
# Stop hook: notify Session Manager when a Window Manager finishes. Async.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

is_manager || exit 0

# Only notify if this manager was BUSY (avoids notification loops)
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
[ -f "$STATUS_FILE" ] || exit 0
_cur=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
[ "${_cur#STATUS: }" = "BUSY" ] || exit 0

SM_PANE=$(get_sm_pane)
tmux display-message -t "$SESSION_NAME:${SM_PANE}" -p '#{pane_pid}' >/dev/null 2>&1 || exit 0

LAST_MSG=$(parse_field "last_assistant_message")
SUMMARY=$(sanitize_message "$LAST_MSG" 150)
[ -z "$SUMMARY" ] && SUMMARY="(no summary)"

send_to_pane "$SESSION_NAME:${SM_PANE}" "Team ${WINDOW_INDEX} Manager finished: ${SUMMARY}"

exit 0
