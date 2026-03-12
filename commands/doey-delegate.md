# Skill: doey-delegate

Delegate a task to another Claude instance by sending it a prompt.

## Usage
`/doey-delegate`

## Prompt
You are delegating a task to another Claude Code instance in a TMUX pane.

### Steps

1. **Discover runtime and list panes:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

2. **Check reservation before delegating:**
   ```bash
   PANE_SAFE=${TARGET_PANE//[:.]/_}
   RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
   if [ -f "$RESERVE_FILE" ]; then
     EXPIRY=$(head -1 "$RESERVE_FILE")
     [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ] && echo "Pane reserved — pick another"
   fi
   ```

3. **Ask the user** which pane and what task (if not specified).

4. **Rename and send task:**
   ```bash
   tmux send-keys -t "$TARGET_PANE" "/rename short-task-name" Enter
   sleep 1
   ```
   For short prompts: `tmux send-keys -t "$TARGET_PANE" "$TASK_PROMPT" Enter`

   For long/special-char prompts:
   ```bash
   TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
   cat > "$TASKFILE" << 'TASK'
   $TASK_PROMPT
   TASK
   tmux load-buffer "$TASKFILE"
   tmux paste-buffer -t "$TARGET_PANE"
   sleep 0.5
   tmux send-keys -t "$TARGET_PANE" Enter
   rm "$TASKFILE"
   ```

5. Confirm task was sent and which pane received it.

### Notes
- Do not delegate to RESERVED panes
- Target instance must be idle (waiting for input)
- Check progress later with `/doey-status`
