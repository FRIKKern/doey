---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart). Use when you need to "send a task to an idle worker", "delegate work without restarting", or "assign a task to a specific pane".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team env: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- All panes: !`tmux list-panes -s -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}' 2>/dev/null|| true`
- My pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

1. Identify idle panes from context. 2. Get target + task from user if needed. 3. Validate: no `.reserved`, has `❯` prompt.

### 4. Task Assignment Files (before dispatch)
```bash
# Pre-write task assignment so on-prompt-submit can enforce accountability
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TARGET_PANE_SAFE=$(echo "$TARGET_PANE" | tr ':-.' '_')
if [ -n "${TASK_ID:-}" ]; then
  printf '%s\n' "$TASK_ID" > "${RD}/status/${TARGET_PANE_SAFE}.task_id"
fi
if [ -n "${SUBTASK_NUM:-}" ]; then
  printf '%s\n' "$SUBTASK_NUM" > "${RD}/status/${TARGET_PANE_SAFE}.subtask_id"
fi
```

### 5. Rename + dispatch

Include `Task #${TASK_ID}` in the prompt header so hooks can track it.

```bash
tmux select-pane -t "$TARGET_PANE" -T "<short-task-label>_$(date +%m%d)"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << 'TASK'
**TASK_ID:** ${TASK_ID}

<task prompt here>
TASK
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$TARGET_PANE"
TASK_LINES=$(wc -l < "$TASKFILE" | tr -d ' ')
if [ "$TASK_LINES" -gt 200 ]; then sleep 2; elif [ "$TASK_LINES" -gt 100 ]; then sleep 1.5; else sleep 0.5; fi
tmux send-keys -t "$TARGET_PANE" Enter && rm "$TASKFILE"
```

### 6. Verify (sleep 5, grep `Read|Edit|Bash|thinking`, retry once)

Rules: Always tmpfile/load-buffer. Never delegate to own pane. Never kill/restart.
