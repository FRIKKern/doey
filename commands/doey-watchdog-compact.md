# Skill: doey-watchdog-compact

Send `/compact` to the Watchdog pane to reduce its token usage.

## Usage
`/doey-watchdog-compact`

## Prompt
You need to send the `/compact` command to the Watchdog pane to free up context.

### Steps

1. Discover the runtime directory and source the session manifest:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   ```

2. Send `/compact` to the Watchdog pane:
   ```bash
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "/compact" Enter
   ```

3. Wait for the compact to finish, then send a resume prompt so the Watchdog continues monitoring:
   ```bash
   sleep 6
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "Resume your watchdog monitoring loop. Continue checking all worker panes every 5 seconds, auto-accepting prompts and sending notifications as before." Enter
   ```

4. Wait a few seconds, then capture the Watchdog pane output to confirm it resumed:
   ```bash
   sleep 5
   tmux capture-pane -t "$SESSION_NAME:0.$WATCHDOG_PANE" -p -S -15
   ```

5. Report success or failure to the user based on the captured output. Look for signs the watchdog is actively monitoring again (e.g., running bash commands, checking panes).
