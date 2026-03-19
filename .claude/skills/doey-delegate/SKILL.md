---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart).
---

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null`

Team environment:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_$(tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-).env 2>/dev/null`

All panes:
!`tmux list-panes -s -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}' 2>/dev/null`

My pane:
!`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'`

## Prompt

### Step 1: Identify panes

Review the context above to see all available panes and your own pane.

### Step 2: Ask user for target pane and task if not provided

### Step 3: Validate target

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { echo "RESERVED — pick another"; exit 1; }
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5)
echo "$OUTPUT"
echo "$OUTPUT" | grep -q '❯' && echo "Idle — OK" || echo "May be busy"
```

### Step 4: Send task

Follow `/doey-dispatch` **Reliable Dispatch Sequence** (steps 8-15) using `TARGET_PANE` as `$PANE`. Skips steps 1-7 since worker is already idle.

### Rules
1. **Never `send-keys "" Enter`** — empty string swallows Enter
2. **Always tmpfile/load-buffer** for task text
3. **Sleep between paste-buffer and send-keys Enter** (auto-scales by line count)
4. **Verify after dispatch** (per /doey-dispatch step 15)
5. **Never delegate to your own pane**
