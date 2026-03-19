---
name: doey-watchdog-compact
description: Send /compact to Watchdog to reduce context window
---

**Only Window Manager or Session Manager can invoke this** (send-keys blocked for other roles).

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team config: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; [ -f "$RD/team_${W}.env" ] && cat "$RD/team_${W}.env" 2>/dev/null|| true`

Send `/compact` to the Watchdog, then verify it responds (retry once after 15s).

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
source "$RD/session.env"
W="${DOEY_WINDOW_INDEX:-0}"
[ -f "$RD/team_${W}.env" ] && source "$RD/team_${W}.env"
WATCHDOG="${SESSION_NAME}:${WATCHDOG_PANE}"
tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
tmux send-keys -t "$WATCHDOG" "/compact" Enter
echo "Sent /compact to ${WATCHDOG}"
```

```bash
for attempt in 1 2; do
  sleep 15
  OUTPUT=$(tmux capture-pane -t "$WATCHDOG" -p -S -20)
  echo "$OUTPUT"
  if echo "$OUTPUT" | grep -qiE 'compact|summariz|monitor'; then
    echo "SUCCESS: Watchdog active after compact"; break
  elif [ "$attempt" -eq 2 ]; then
    echo "FAILED: Watchdog not responding — manual intervention needed"
  else
    tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
    tmux send-keys -t "$WATCHDOG" "/compact" Enter
  fi
done
```

Report result.
