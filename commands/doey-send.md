# Skill: doey-send

Send a message to another Claude instance in TMUX.

## Usage
`/doey-send`

## Prompt
You are sending a message to another Claude Code instance in a TMUX pane.

### Steps

1. **Discover runtime and list panes:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
   MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

2. Ask which pane and what message (if not specified).

3. **Write message file:**
   ```bash
   TIMESTAMP=$(gdate +%s%N 2>/dev/null || echo "$(date +%s)$$")
   cat > "${RUNTIME_DIR}/messages/${TARGET_PANE//[:.]/_}_${TIMESTAMP}.msg" <<EOF
   FROM: $MY_PANE
   TO: $TARGET_PANE
   TIME: $(date -Iseconds)
   ---
   $MESSAGE
   EOF
   # Delivery handled by Watchdog (checks idle state before sending)
   ```

4. Confirm to the user that the message was queued for delivery.
