---
name: doey-watchdog-compact
description: Send /compact to Session Manager to reduce context window. Use when you need to "compact the SM", "reduce SM context", or "SM is running out of context".
---

Only Window Manager or Boss (send-keys blocked for others).

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Send `/compact` to SM (pane 0.2), verify, retry once after 15s.

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
source "$RD/session.env"
SM_PANE="${SESSION_NAME}:0.2"
tmux copy-mode -q -t "$SM_PANE" 2>/dev/null
tmux send-keys -t "$SM_PANE" "/compact" Enter
```

```bash
for attempt in 1 2; do
  sleep 15
  OUTPUT=$(tmux capture-pane -t "$SM_PANE" -p -S -20)
  if echo "$OUTPUT" | grep -qiE 'compact|summariz|monitor|wait'; then
    echo "SUCCESS: SM active after compact"; break
  elif [ "$attempt" -eq 2 ]; then
    echo "FAILED: SM not responding"
  else
    tmux copy-mode -q -t "$SM_PANE" 2>/dev/null
    tmux send-keys -t "$SM_PANE" "/compact" Enter
  fi
done
```
