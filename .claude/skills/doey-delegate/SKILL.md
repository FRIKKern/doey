---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart). Use when you need to "send a task to an idle worker", "delegate work without restarting", or "assign a task to a specific pane".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`
- All panes: !`tmux list-panes -s -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}' 2>/dev/null|| true`
- My pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

## Prompt

Delegate a task to an idle Claude instance (no kill/restart). Use user-supplied `W.P` pane address.

## Step 1: Identify idle panes from context above

## Step 2: Get target pane and task from user (if not provided)

## Step 3: Validate target is idle and unreserved

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && SESSION_NAME=$(grep '^SESSION_NAME=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"') && TARGET_PANE="${SESSION_NAME}:<W>.<P>" && PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_') && if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then echo "RESERVED — pick another"; exit 1; fi && tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null; OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5) && echo "$OUTPUT" && echo "$OUTPUT" | grep -q '❯' && echo "Idle — OK" || echo "May be busy"

## Step 4: Rename target pane

bash: tmux select-pane -t "$TARGET_PANE" -T "<short-task-label>_$(date +%m%d)"

## Step 5: Write and paste task prompt

Tmpfile → load-buffer → paste-buffer → settle → Enter. Follow `/doey-dispatch` dispatch sequence.

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt") && cat > "$TASKFILE" << 'TASK'
<task prompt here>
TASK
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null; tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$TARGET_PANE" && TASK_LINES=$(wc -l < "$TASKFILE" | tr -d ' ') && if [ "$TASK_LINES" -gt 200 ]; then sleep 2; elif [ "$TASK_LINES" -gt 100 ]; then sleep 1.5; else sleep 0.5; fi && tmux send-keys -t "$TARGET_PANE" Enter && rm "$TASKFILE"

## Step 6: Verify dispatch

bash: sleep 5 && tmux capture-pane -t "$TARGET_PANE" -p -S -10 | grep -qE 'Read|Edit|Bash|thinking' && echo "Working" || echo "Idle — may need retry"

If idle: send Enter, wait 3s, re-check. Still idle → unstick per `/doey-dispatch`.

### Rules
- Always tmpfile/load-buffer — never `send-keys` for task text
- Sleep between paste-buffer and Enter (scales by line count)
- Never delegate to own pane; never kill/restart the worker
