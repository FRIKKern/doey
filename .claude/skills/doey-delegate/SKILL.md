---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart). Use when you need to "send a task to an idle worker", "delegate work without restarting", or "assign a task to a specific pane".
---

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Team environment:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

All panes:
!`tmux list-panes -s -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}' 2>/dev/null|| true`

My pane:
!`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

**Expected:** 4 tmux commands (capture-pane, copy-mode, load-buffer/paste-buffer, send-keys), 2 file reads (status + reserved), ~10s.

## Prompt

Delegate a task to an idle Claude instance without killing or restarting it. Session/team config is injected above. Use the user-supplied `W.P` pane address (e.g., `3.2`), not hardcoded `WINDOW_INDEX`.

## Step 1: Identify panes

Review the context above to see all available panes and your own pane. Note which panes show idle workers.

Expected: A list of panes with their titles and PIDs. Identify candidate idle workers.

## Step 2: Get target pane and task from user

Ask the user for the target pane (`W.P` format) and the task to delegate, if not already provided.

Expected: User provides target pane address and task description.

## Step 3: Validate target is idle and unreserved

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && TARGET_PANE="${SESSION_NAME}:<W>.<P>" && PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_') && [ ! -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null; OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5) && echo "$OUTPUT" && echo "$OUTPUT" | grep -q '❯' && echo "Idle — OK" || echo "May be busy"
Expected: "Idle — OK" printed, confirming target pane is at the `>` prompt and not reserved.

**If this fails with "RESERVED — pick another":** The pane has a `.reserved` file. Choose a different worker pane.
**If this fails with "May be busy":** Worker is currently processing. Wait or pick another pane.
**If this fails with "can't find pane":** Verify the pane address matches the format `session:window.pane`.

## Step 4: Rename target pane

bash: tmux select-pane -t "$TARGET_PANE" -T "<short-task-label>_$(date +%m%d)"
Expected: Pane title updated to reflect the delegated task.

**If this fails with "can't find pane":** Re-check pane address from Step 3.

## Step 5: Write and paste task prompt

Write task to tmpfile, load into tmux buffer, paste into target pane, settle, then submit. Follow `/doey-dispatch` dispatch sequence (steps 3-6).

bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt") && cat > "$TASKFILE" << 'TASK'
<task prompt here>
TASK
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null; tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$TARGET_PANE" && TASK_LINES=$(wc -l < "$TASKFILE" | tr -d ' ') && if [ "$TASK_LINES" -gt 200 ]; then sleep 2; elif [ "$TASK_LINES" -gt 100 ]; then sleep 1.5; else sleep 0.5; fi && tmux send-keys -t "$TARGET_PANE" Enter && rm "$TASKFILE"
Expected: Task prompt pasted and submitted to target pane. Tmpfile cleaned up.

**If this fails with "no buffer":** Ensure `load-buffer` succeeded — check that TASKFILE was written and is non-empty.
**If this fails with "can't find pane":** Worker may have been killed. Re-check pane list.

## Step 6: Verify dispatch

bash: sleep 5 && tmux capture-pane -t "$TARGET_PANE" -p -S -10 | grep -qE 'Read|Edit|Bash|thinking' && echo "Working" || echo "Idle — may need retry"
Expected: "Working" — target pane is actively processing the task.

**If this fails with "Idle — may need retry":** Send Enter again: `tmux send-keys -t "$TARGET_PANE" Enter`, wait 3s, re-check. Still idle → unstick per `/doey-dispatch` Unstick section.

## Gotchas

- Do NOT delegate to your own pane — check "My pane" in Context above.
- Do NOT use `send-keys` for task text — always use tmpfile + `load-buffer` + `paste-buffer`.
- Do NOT skip the sleep between `paste-buffer` and Enter — scales by line count.
- Do NOT skip verification after dispatch — always confirm the worker started processing.
- Do NOT kill/restart the worker — this skill assumes the Claude instance is already running and idle.

### Rules

1. **Always tmpfile/load-buffer** for task text — never `send-keys "" Enter`
2. **Sleep between paste-buffer and Enter** (scales by line count); **verify after dispatch**
3. **Never delegate to your own pane**

Total: 4 commands, 0 errors expected.
