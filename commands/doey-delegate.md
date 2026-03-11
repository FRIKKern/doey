# Skill: doey-delegate

Delegate a task to another Claude instance by sending it a prompt.

## Usage
`/doey-delegate`

## Prompt
You are delegating a task to another Claude Code instance running in a TMUX pane.

### Steps

1. Discover runtime directory and list available panes:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
   ```

2. Identify your own pane:
   ```bash
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

3. Check for reserved panes before delegating:
   ```bash
   PANE_SAFE=${TARGET_PANE//[:.]/_}
   RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
   if [ -f "$RESERVE_FILE" ]; then
     EXPIRY=$(head -1 "$RESERVE_FILE")
     if [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ]; then
       echo "Pane is reserved — pick another"
     fi
   fi
   ```

4. Ask the user:
   - Which pane to delegate to (if not specified)
   - What task/prompt to send

4. **Rename the worker** so the task is visible in the pane border:
   ```bash
   tmux send-keys -t "$TARGET_PANE" "/rename short-task-name" Enter
   sleep 1
   ```

5. Send the task directly as keystrokes to the target pane:
   ```bash
   tmux send-keys -t "$TARGET_PANE" "$TASK_PROMPT" Enter
   ```

   **IMPORTANT**: If the prompt is long or contains special characters, write it to a temp file first and use `tmux load-buffer` + `tmux paste-buffer`:
   ```bash
   mkdir -p "${RUNTIME_DIR}"
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
5. Confirm to the user that the task was sent and which pane received it.

### Notes
- Do not delegate to a RESERVED pane — check for `.reserved` file first
- The target Claude will receive this as user input in its conversation
- You can check on their progress later with `/doey-status`
- The target instance must be idle (waiting for input) for this to work
