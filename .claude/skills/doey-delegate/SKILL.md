---
name: doey-delegate
description: Delegate a task to an idle Claude instance (no kill/restart).
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team env: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_$(tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-).env 2>/dev/null || true`
- All panes: !`tmux list-panes -s -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}' 2>/dev/null|| true`
- My pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

## Prompt

1. **Identify** — review injected panes above and your own pane.
2. **Ask** user for target pane (`W.P`) and task if not provided.
3. **Validate** — check target is not reserved and is idle:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TARGET_PANE="${SESSION_NAME}:<W>.<P>"  # from user input
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
[ -f "${RD}/status/${PANE_SAFE}.reserved" ] && { echo "RESERVED — pick another"; exit 1; }
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5)
echo "$OUTPUT" | grep -q '❯' && echo "Idle — OK" || echo "May be busy"
```

4. **Send task** — follow `/doey-dispatch` Dispatch Sequence steps 3-6 (rename, write+paste, settle+submit, verify) using `TARGET_PANE` as `$PANE`. Skip steps 0-2 (readiness/kill+restart) since worker is already idle.

### Rules
1. **Always tmpfile/load-buffer** — never `send-keys "" Enter`
2. **Settle before Enter** (scales by line count); **verify after dispatch**
3. **Never delegate to your own pane**
