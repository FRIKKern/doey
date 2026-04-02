---
name: doey-nudge
description: Cascading nudge — wake stalled Claude instances across all teams. Use when workers seem stuck, idle, or unresponsive.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Send a nudge cascade to Taskmaster, who will propagate it to all team Subtaskmasters and their Workers.

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RD}/session.env"
TASKMASTER_PANE="${SESSION_NAME}:0.2"

NUDGE_MSG="Nudge cascade requested. Check all team Subtaskmasters and ensure work is progressing. For each team window W in [${TEAM_WINDOWS}], send-keys to W.0 telling the Subtaskmaster to check worker status files and nudge any stalled workers (BUSY with no status update in >120s). Use copy-mode -q before each send-keys. Fire and forget."

tmux copy-mode -q -t "$TASKMASTER_PANE" 2>/dev/null || true
TMPFILE=$(mktemp)
printf '%s\n' "$NUDGE_MSG" > "$TMPFILE"
tmux load-buffer -b doey_nudge "$TMPFILE"
rm -f "$TMPFILE"
tmux copy-mode -q -t "$TASKMASTER_PANE" 2>/dev/null || true
tmux paste-buffer -b doey_nudge -t "$TASKMASTER_PANE" 2>/dev/null || true
tmux copy-mode -q -t "$TASKMASTER_PANE" 2>/dev/null || true
tmux send-keys -t "$TASKMASTER_PANE" Enter 2>/dev/null || true
tmux delete-buffer -b doey_nudge 2>/dev/null || true
echo "Nudge sent to Taskmaster (${TASKMASTER_PANE})"
```
