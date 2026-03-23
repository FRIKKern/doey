---
name: doey-settings
description: Open an interactive Settings window with a config editor and live settings panel. Use when you need to "open settings", "configure doey", or "change doey settings".
---

Open the Doey settings window: a split tmux window with a live config panel on the right and a Claude settings-editor agent on the left.

## Instructions

Run the following commands via the Bash tool:

```bash
SESSION_NAME=$(tmux display-message -p '#{session_name}')
PROJECT_DIR=$(grep '^PROJECT_DIR=' /tmp/doey/*/session.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

# Check if Settings window already exists
SETTINGS_WIN=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null | grep ' Settings$' | head -1 | awk '{print $1}')
if [ -n "$SETTINGS_WIN" ]; then
  tmux select-window -t "$SESSION_NAME:$SETTINGS_WIN"
  exit 0
fi

# Create new window named "Settings"
tmux new-window -t "$SESSION_NAME" -n "Settings"
SETTINGS_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

# Left pane (pane 0): run settings panel with live refresh
tmux send-keys -t "$SESSION_NAME:$SETTINGS_WIN.0" "DOEY_SETTINGS_LIVE=1 bash \"${PROJECT_DIR}/shell/settings-panel.sh\"" Enter

# Split right for Claude editor (pane 1)
tmux split-window -h -t "$SESSION_NAME:$SETTINGS_WIN.0"
tmux send-keys -t "$SESSION_NAME:$SETTINGS_WIN.1" "claude --agent settings-editor" Enter

# Focus the right pane (editor)
tmux select-pane -t "$SESSION_NAME:$SETTINGS_WIN.1"
```
