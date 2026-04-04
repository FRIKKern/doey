#!/usr/bin/env bash
set -uo pipefail
# Click handler for ⚙ Settings button — opens/focuses Settings window.

session="${1:-}"; [ -z "$session" ] && exit 0
RUNTIME_DIR=$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
[ -z "$PROJECT_DIR" ] && exit 0

settings_win=$(tmux list-windows -t "$session" -F '#{window_index} #{window_name}' 2>/dev/null \
  | awk '/ Settings$/{print $1; exit}')
if [ -n "$settings_win" ]; then tmux select-window -t "$session:$settings_win"; exit 0; fi

source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true

tmux new-window -t "$session" -n "Settings"
settings_win=$(tmux display-message -t "$session" -p '#{window_index}')
doey_send_command "$session:${settings_win}.0" "DOEY_SETTINGS_LIVE=1 bash \"\$HOME/.local/bin/settings-panel.sh\""
tmux split-window -h -t "$session:${settings_win}.0"
doey_send_command "$session:${settings_win}.1" "claude --agent settings-editor"
tmux select-pane -t "$session:${settings_win}.1"
