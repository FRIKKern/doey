# Skill: tmux-delegate

Delegate a task to another Claude instance by sending it a prompt.

## Usage
`/tmux-delegate`

## Prompt
You are delegating a task to another Claude Code instance running in a TMUX pane.

### Steps

1. List available panes:
   ```bash
   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
   ```

2. Identify your own pane:
   ```bash
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

3. Ask the user:
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
   mkdir -p /tmp/claude-team
   TASKFILE=$(mktemp /tmp/claude-team/task_XXXXXX.txt)
   cat > "$TASKFILE" << 'TASK'
   $TASK_PROMPT
   TASK
   tmux load-buffer "$TASKFILE"
   tmux paste-buffer -t "$TARGET_PANE"
   sleep 0.5
   tmux send-keys -t "$TARGET_PANE" Enter
   rm "$TASKFILE"
   ```

   **CRITICAL**: Never use `send-keys "" Enter` (empty string before Enter) — it swallows the keystroke. Always use bare `Enter` after a `sleep 0.5`.

5. Confirm to the user that the task was sent and which pane received it.

### Notes
- The target Claude will receive this as user input in its conversation
- You can check on their progress later with `/tmux-status`
- The target instance must be idle (waiting for input) for this to work
