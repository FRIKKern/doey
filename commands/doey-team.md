# Skill: doey-team

View the full team of Claude instances and their pane layout.

## Usage
`/doey-team`

## Prompt
You are showing the team overview of all Claude Code instances in TMUX.

### Steps

1. **Discover runtime and identity:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

2. **List all panes:**
   ```bash
   tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} | PID: #{pane_pid} | #{pane_width}x#{pane_height} | #{pane_current_command}'
   ```

3. **Read status and reservation files:**
   ```bash
   for f in "${RUNTIME_DIR}/status/"*.status; do [ -f "$f" ] && cat "$f" && echo "---"; done
   for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
     PANE_SAFE=${pane//[:.]/_}; RF="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
     [ -f "$RF" ] && { EXPIRY=$(head -1 "$RF"); [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ]; } && echo "$pane: RESERVED"
   done
   ```

4. **Check unread messages per pane:**
   ```bash
   for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
     PANE_SAFE=${pane//[:.]/_}
     COUNT=$(ls "${RUNTIME_DIR}/messages/${PANE_SAFE}_"*.msg 2>/dev/null | wc -l)
     echo "$pane: $COUNT unread"
   done
   ```

5. **Present formatted table:** Pane ID, Status (RESERVED shown with lock icon), Current task, Unread count, mark YOUR pane with `<-- you`.
