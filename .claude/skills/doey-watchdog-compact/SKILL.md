---
name: doey-watchdog-compact
description: Send /compact to Watchdog to reduce context window
---

**Only Window Manager or Session Manager can invoke this.**

!`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; cat "$RD/session.env" 2>/dev/null; W="${DOEY_WINDOW_INDEX:-0}"; cat "$RD/team_${W}.env" 2>/dev/null || true`

Send `/compact` to the Watchdog, then verify (retry once after 15s).

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
source "$RD/session.env"
W="${DOEY_WINDOW_INDEX:-0}"
[ -f "$RD/team_${W}.env" ] && source "$RD/team_${W}.env"
WATCHDOG="${SESSION_NAME}:${WATCHDOG_PANE}"
tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
tmux send-keys -t "$WATCHDOG" "/compact" Enter
```

```bash
for attempt in 1 2; do
  sleep 15
  OUTPUT=$(tmux capture-pane -t "$WATCHDOG" -p -S -20)
  if echo "$OUTPUT" | grep -qiE 'compact|summariz|monitor'; then
    echo "SUCCESS: Watchdog active after compact"; break
  elif [ "$attempt" -eq 2 ]; then
    echo "FAILED: Watchdog not responding"
  else
    tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
    tmux send-keys -t "$WATCHDOG" "/compact" Enter
  fi
done
```
