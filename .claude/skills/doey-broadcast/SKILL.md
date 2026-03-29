---
name: doey-broadcast
description: Broadcast a message to all other Claude instances. Use when you need to "send a message to all panes", "notify all workers", or "broadcast to the team".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- My pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

Ask user for message if not provided. Replace `YOUR_MESSAGE_HERE`:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(grep '^SESSION_NAME=' "$RD/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
TIMESTAMP="$(date +%s)$$"
mkdir -p "${RD}/broadcasts" "${RD}/messages"
MESSAGE="YOUR_MESSAGE_HERE"
printf 'FROM: %s\nTIME: %s\n---\n%s\n' "$MY_PANE" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$MESSAGE" > "${RD}/broadcasts/${TIMESTAMP}.broadcast"
DELIVERED=0
for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
  [ "$pane" = "$MY_PANE" ] && continue
  PANE_SAFE=$(echo "$pane" | tr ':-.' '_')
  cp "${RD}/broadcasts/${TIMESTAMP}.broadcast" "${RD}/messages/${PANE_SAFE}_${TIMESTAMP}.msg"
  DELIVERED=$((DELIVERED + 1))
done
echo "Broadcast delivered to ${DELIVERED} panes"
```
