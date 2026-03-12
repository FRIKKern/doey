# Skill: doey-stop

Stop the current Doey session immediately.

## Usage
`/doey-stop`

## Prompt
You are stopping the current Doey session. Do NOT ask for confirmation — stop immediately.

### Steps

1. **Discover runtime and stop:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   for pane_id in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_id}'); do
     pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)
     [ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null
   done
   sleep 2
   tmux kill-session -t "$SESSION_NAME"
   ```

2. **Clean up:** `rm -rf "$RUNTIME_DIR"`

### Rules
- **Never ask for confirmation** — execute immediately
- Kill Claude processes first, then tmux session, then clean up runtime
- This terminates your own session
