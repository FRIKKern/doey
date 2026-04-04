---
name: doey-nudge
description: Cascading nudge — wake stalled Claude instances across all teams. Use when workers seem stuck, idle, or unresponsive.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Send a nudge cascade to Taskmaster, who will propagate it to all team Subtaskmasters and their Workers.

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RD}/session.env"
_TM_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${SESSION_NAME}:${_TM_PANE:-1.0}"

NUDGE_MSG="Nudge cascade requested. Check all team Subtaskmasters and ensure work is progressing. For each team window W in [${TEAM_WINDOWS}], send-keys to W.0 telling the Subtaskmaster to check worker status files and nudge any stalled workers (BUSY with no status update in >120s). Use copy-mode -q before each send-keys. Fire and forget."

source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
doey_send_verified "$TASKMASTER_PANE" "$NUDGE_MSG" && echo "Nudge sent to Taskmaster (${TASKMASTER_PANE})" || echo "Nudge delivery failed"
```
