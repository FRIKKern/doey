#!/usr/bin/env bash
# Notification hook: desktop notification for Taskmaster permission requests,
# plus Boss-aware auto-focus so AskUserQuestion / permission prompts from the
# Boss pane yank the user's active window to the Dashboard (window 0, pane 0.1).
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "on-notification"

MSG=$(parse_field "message")
[ -z "$MSG" ] && MSG="Claude needs your attention"
_MSG_CLEAN=$(printf '%s' "${MSG:0:150}" | tr '\n"' " '")

# ── Boss auto-focus ────────────────────────────────────────────────────────
# When Boss triggers a notification (AskUserQuestion, permission prompt, idle
# wait), switch the user's active tmux window to the Dashboard and fire a
# desktop notification so an unfocused terminal still surfaces the prompt.
#
# Guards:
#   - DOEY_NO_AUTO_FOCUS=1 disables
#   - SESSION_NAME must be set (otherwise tmux target is ambiguous)
#   - Role must be Boss (DOEY_ROLE == $DOEY_ROLE_ID_BOSS, else fall back to
#     WINDOW_INDEX=0 && PANE_INDEX=1)
#   - Already on window 0 → skip window switch but still notify
_is_boss_source() {
  if [ -n "${DOEY_ROLE:-}" ] && [ "${DOEY_ROLE}" = "${DOEY_ROLE_ID_BOSS:-boss}" ]; then
    return 0
  fi
  # Fall back to pane-index detection (boss is always window 0 pane 1)
  [ "${WINDOW_INDEX:-}" = "0" ] && [ "${PANE_INDEX:-}" = "1" ]
}

if [ "${DOEY_NO_AUTO_FOCUS:-0}" != "1" ] && [ -n "${SESSION_NAME:-}" ] && _is_boss_source; then
  if _check_cooldown "boss_focus" 5; then
    _cur_win=$(tmux display-message -p -t "$SESSION_NAME" '#{window_index}' 2>/dev/null) || _cur_win=""
    if [ -n "$_cur_win" ] && [ "$_cur_win" != "0" ]; then
      tmux select-window -t "${SESSION_NAME}:0" 2>/dev/null || true
    fi
    tmux select-pane -t "${SESSION_NAME}:0.1" 2>/dev/null || true
    _send_desktop_notification "Doey — Boss needs input" "$_MSG_CLEAN"
    _log "on-notification: Boss focus switch → ${SESSION_NAME}:0.1 (from window=${_cur_win:-?})"
  fi
  exit 0
fi

# ── Taskmaster permission notification (original behavior) ─────────────────
is_taskmaster || exit 0
_check_cooldown "permission" 30 || exit 0
_send_desktop_notification "Doey — Permission Required" "$_MSG_CLEAN"
_log "on-notification: sent desktop notification for permission request"
exit 0
