#!/usr/bin/env bash
# Notification hook: desktop notification for Taskmaster permission requests
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "on-notification"

is_taskmaster || exit 0

MSG=$(parse_field "message")
[ -z "$MSG" ] && MSG="Taskmaster needs your attention"
_check_cooldown "permission" 30 || exit 0

_send_desktop_notification "Doey — Permission Required" "$(printf '%s' "${MSG:0:150}" | tr '\n"' " '")"
_log "on-notification: sent desktop notification for permission request"
exit 0
