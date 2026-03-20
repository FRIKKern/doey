---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart).
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

## Prompt

### Step 1: Identify panes

Review the context above to see all available panes and your own pane.

### Step 2: Ask user for target pane and task if not provided

### Step 3: Validate target

Use the user-supplied `W.P` pane address (e.g., `3.2`), not hardcoded `WINDOW_INDEX`:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TARGET_PANE="${SESSION_NAME}:<W>.<P>"  # from user input
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { echo "RESERVED — pick another"; exit 1; }
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5)
echo "$OUTPUT"
echo "$OUTPUT" | grep -q '❯' && echo "Idle — OK" || echo "May be busy"
```

### Step 4: Send task

Follow `/doey-dispatch` Dispatch Sequence using `TARGET_PANE` as `$PANE`: rename pane (step 3), write+paste task via tmpfile (step 4), settle+submit (step 5), verify (step 6). Skip readiness check/kill+restart (steps 1-2) since worker is already idle.

### Rules
1. **Always tmpfile/load-buffer** for task text — never `send-keys "" Enter`
2. **Sleep between paste-buffer and Enter** (scales by line count); **verify after dispatch**
3. **Never delegate to your own pane**
