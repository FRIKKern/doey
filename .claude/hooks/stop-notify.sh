#!/usr/bin/env bash
# Stop hook: desktop notification for Session Manager. Async.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

is_session_manager || exit 0

LAST_MSG=$(parse_field "last_assistant_message")
[ -z "$LAST_MSG" ] && exit 0
echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯" && exit 0

BODY=$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")
send_notification "Doey — Session Manager" "$BODY"

exit 0
