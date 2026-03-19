#!/usr/bin/env bash
# Stop hook: role-based notifications (async)
#   Worker          -> notify Window Manager pane
#   Window Manager  -> notify Session Manager pane
#   Session Manager -> send desktop notification
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

# --- Worker -> Window Manager ---
if is_worker; then
  MGR_PANE="$SESSION_NAME:$WINDOW_INDEX.0"
  tmux display-message -t "$MGR_PANE" -p '#{pane_pid}' >/dev/null 2>&1 || exit 0

  PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="W${PANE_INDEX}"

  # Read status from result JSON (written by stop-results.sh)
  RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
  STATUS="done"
  if [ -f "$RESULT_FILE" ]; then
    STATUS=$(jq -r '.status // "done"' "$RESULT_FILE" 2>/dev/null) \
      || STATUS=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('status','done'))" < "$RESULT_FILE" 2>/dev/null) \
      || STATUS="done"
  fi

  MSG="Worker ${PANE_TITLE} finished (${STATUS})"
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -n "$LAST_MSG" ] && MSG="${MSG}: $(sanitize_message "$LAST_MSG" 100)"

  send_to_pane "$MGR_PANE" "$MSG"
  exit 0
fi

# --- Window Manager -> Session Manager ---
if is_manager; then
  # Only notify if manager was BUSY (avoids notification loops)
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  [ -f "$STATUS_FILE" ] || exit 0
  _cur=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
  [ "${_cur#STATUS: }" = "BUSY" ] || exit 0

  SM_PANE=$(get_sm_pane)
  tmux display-message -t "$SESSION_NAME:${SM_PANE}" -p '#{pane_pid}' >/dev/null 2>&1 || exit 0

  SUMMARY=$(sanitize_message "$(parse_field "last_assistant_message")" 150)
  [ -z "$SUMMARY" ] && SUMMARY="(no summary)"

  send_to_pane "$SESSION_NAME:${SM_PANE}" "Team ${WINDOW_INDEX} Manager finished: ${SUMMARY}"
  exit 0
fi

# --- Session Manager -> desktop notification ---
if is_session_manager; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯" && exit 0

  send_notification "Doey — Session Manager" "$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")"
  exit 0
fi

exit 0
