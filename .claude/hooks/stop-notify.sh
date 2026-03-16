#!/usr/bin/env bash
# Stop hook: Send macOS notification for Session Manager.
# Runs async.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

# Only the Session Manager (Dashboard window 0, pane 0.4) gets notifications
is_session_manager || exit 0

LAST_MSG=$(parse_field "last_assistant_message")
if [ -n "$LAST_MSG" ]; then
  if ! echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯"; then
    NOTIFY_BODY=$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")
    send_notification "Doey — Session Manager" "$NOTIFY_BODY"
  fi
fi

exit 0
