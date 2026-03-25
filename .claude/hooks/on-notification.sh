#!/usr/bin/env bash
# Notification hook: send desktop notification when Session Manager needs user attention.
# Fires on Notification events (including PermissionRequest).
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="on-notification"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

# Only notify for Session Manager — that's the pane the user interacts with
is_session_manager || exit 0

# Extract notification message
MSG=$(parse_field "message")
[ -z "$MSG" ] && MSG="Session Manager needs your attention"

# 30-second cooldown to avoid notification spam
if [ -n "${RUNTIME_DIR:-}" ]; then
  cooldown_file="${RUNTIME_DIR}/status/notif_cooldown_permission"
  last_sent=$(cat "$cooldown_file" 2>/dev/null) || last_sent=0
  now=$(date +%s)
  [ "$((now - last_sent))" -lt 30 ] && exit 0
  echo "$now" > "$cooldown_file" 2>/dev/null || true
fi

# Send desktop notification (bypass send_notification's is_session_manager check
# since we already verified that above, and bypass its 60s cooldown — we use our own)
TITLE="Doey — Permission Required"
BODY=$(printf '%s' "${MSG:0:150}" | tr '\n"' " '")

if command -v osascript >/dev/null 2>&1; then
  osascript - "$TITLE" "$BODY" <<'APPLESCRIPT' 2>/dev/null &
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name "Ping"
end run
APPLESCRIPT
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$TITLE" "$BODY" 2>/dev/null &
fi

_log "on-notification: sent desktop notification for permission request"
exit 0
