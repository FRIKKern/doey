---
name: doey-settings
description: Open an interactive Settings window with a config editor and live settings panel. Use when you need to "open settings", "configure doey", or "change doey settings".
---

Split window: live config panel (left) + settings-editor agent (right). Reuses existing Settings window if present.

```bash
SESSION_NAME=$(tmux display-message -p '#{session_name}')
# Reuse existing Settings window if present
SETTINGS_WIN=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_name}' 2>/dev/null | grep ' Settings$' | head -1 | awk '{print $1}')
if [ -n "$SETTINGS_WIN" ]; then tmux select-window -t "$SESSION_NAME:$SETTINGS_WIN"; exit 0; fi
tmux new-window -t "$SESSION_NAME" -n "Settings"
SETTINGS_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')
tmux send-keys -t "$SESSION_NAME:$SETTINGS_WIN.0" "DOEY_SETTINGS_LIVE=1 bash \"\$HOME/.local/bin/settings-panel.sh\"" Enter
tmux split-window -h -t "$SESSION_NAME:$SETTINGS_WIN.0"
tmux send-keys -t "$SESSION_NAME:$SETTINGS_WIN.1" "claude --dangerously-skip-permissions --agent settings-editor" Enter
tmux select-pane -t "$SESSION_NAME:$SETTINGS_WIN.1"
```
