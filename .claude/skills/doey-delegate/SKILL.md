---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart). Use when you need to "send a task to an idle worker", "delegate work without restarting", or "assign a task to a specific pane".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team env: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- All panes: !`tmux list-panes -s -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}' 2>/dev/null|| true`
- My pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

### 1. Identify idle panes from context above
### 2. Get target pane and task from user (if not provided)
### 3. Validate idle + unreserved
Check `.reserved` file and `❯` prompt via `capture-pane -S -5`.

### 4. Rename + dispatch
```bash
tmux select-pane -t "$TARGET_PANE" -T "<short-task-label>_$(date +%m%d)"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << 'TASK'
<task prompt here>
TASK
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$TARGET_PANE"
TASK_LINES=$(wc -l < "$TASKFILE" | tr -d ' ')
if [ "$TASK_LINES" -gt 200 ]; then sleep 2; elif [ "$TASK_LINES" -gt 100 ]; then sleep 1.5; else sleep 0.5; fi
tmux send-keys -t "$TARGET_PANE" Enter && rm "$TASKFILE"
```

### 5. Verify
`sleep 5`, grep for `Read|Edit|Bash|thinking`. If idle: Enter, 3s, re-check → unstick per `/doey-dispatch`.

### Rules
- Always tmpfile/load-buffer — never `send-keys` for task text
- Never delegate to own pane; never kill/restart the worker
