#!/usr/bin/env bash
set -uo pipefail
# Click handler for the ⚙ Settings button in the tmux status bar.
# Opens (or focuses) the Settings window for the current session.
# Called from a tmux mouse binding — receives session name as $1.

session="${1:-}"
[ -z "$session" ] && exit 0

RUNTIME_DIR=$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
[ -z "$PROJECT_DIR" ] && exit 0

# If Settings window already exists, just focus it
settings_win=$(tmux list-windows -t "$session" -F '#{window_index} #{window_name}' 2>/dev/null \
  | awk '/ Settings$/{print $1; exit}')
if [ -n "$settings_win" ]; then
  tmux select-window -t "$session:$settings_win"
  exit 0
fi

# Create new Settings window
tmux new-window -t "$session" -n "Settings"
settings_win=$(tmux display-message -t "$session" -p '#{window_index}')

# Split: left = live settings panel, right = config editor (Claude)
# Pane 0 starts the settings panel, then split-right creates pane 1 for Claude
tmux send-keys -t "$session:${settings_win}.0" \
  "DOEY_SETTINGS_LIVE=1 bash \"${PROJECT_DIR}/shell/settings-panel.sh\"" Enter
tmux split-window -h -t "$session:${settings_win}.0"
tmux send-keys -t "$session:${settings_win}.1" \
  "claude --agent settings-editor" Enter
tmux select-pane -t "$session:${settings_win}.1"
