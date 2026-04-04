---
name: doey-taskmaster-compact
description: Send /compact to Taskmaster to reduce context window. Use when you need to "compact the Taskmaster", "reduce Taskmaster context", or "Taskmaster is running out of context".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Subtaskmaster/Boss only. Send `/compact` to Taskmaster (1.0), verify, retry once after 15s.

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
source "$RD/session.env"
source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
_TM_PANE=$(grep '^TASKMASTER_PANE=' "$RD/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${SESSION_NAME}:${_TM_PANE:-1.0}"
doey_send_verified "$TASKMASTER_PANE" "/compact"
```

```bash
for attempt in 1 2; do
  sleep 15
  OUTPUT=$(tmux capture-pane -t "$TASKMASTER_PANE" -p -S -20)
  if echo "$OUTPUT" | grep -qiE 'compact|summariz|monitor|wait'; then
    echo "SUCCESS: Taskmaster active after compact"; break
  elif [ "$attempt" -eq 2 ]; then
    echo "FAILED: Taskmaster not responding"
  else
    doey_send_verified "$TASKMASTER_PANE" "/compact"
  fi
done
```
