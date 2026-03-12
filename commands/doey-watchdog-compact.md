# Skill: doey-watchdog-compact

Send `/compact` to the Watchdog pane to reduce its token usage.

## Usage
`/doey-watchdog-compact`

## Prompt
Send `/compact` to the Watchdog and resume its monitoring loop.

### Steps

1. **Discover runtime:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   ```

2. **Send compact:**
   ```bash
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "/compact" Enter
   ```

3. **Resume monitoring:**
   ```bash
   sleep 6
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "Resume your watchdog monitoring loop. Continue checking all worker panes every 5 seconds, auto-accepting prompts and sending notifications as before." Enter
   ```

4. **Verify:**
   ```bash
   sleep 5
   tmux capture-pane -t "$SESSION_NAME:0.$WATCHDOG_PANE" -p -S -15
   ```

5. Report success/failure based on captured output.
