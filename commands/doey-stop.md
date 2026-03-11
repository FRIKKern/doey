# Skill: doey-stop

Stop the current Doey session gracefully.

## Usage
`/doey-stop`

## Prompt

You are stopping the current Doey session.

### Steps

1. **Discover runtime context:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   ```

2. **Confirm with the user:** Ask "Stop the Doey session '$SESSION_NAME'? This will kill all workers and the Manager."

3. **On confirmation, stop the session:**
   ```bash
   # Kill all Claude processes in all panes
   for pane_id in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_id}'); do
     pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)
     [ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null
   done
   sleep 2

   # Kill the tmux session
   tmux kill-session -t "$SESSION_NAME"
   ```

4. **Clean up runtime directory:**
   ```bash
   rm -rf "$RUNTIME_DIR"
   ```

### Rules
- Always confirm before stopping
- Kill Claude processes first, then kill the tmux session
- Clean up the runtime directory
- This command will terminate your own session — the last command you run is the kill
