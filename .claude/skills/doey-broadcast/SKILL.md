---
name: doey-broadcast
description: Broadcast a message to all other Claude instances.
---

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

My pane:
!`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'|| true`

## Prompt

Ask user for the message if not provided. Replace `YOUR_MESSAGE_HERE` below, then run:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
TIMESTAMP="$(date +%s)$$"
mkdir -p "${RUNTIME_DIR}/broadcasts" "${RUNTIME_DIR}/messages"

MESSAGE="YOUR_MESSAGE_HERE"

cat > "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" <<EOF
FROM: $MY_PANE
TIME: $(date '+%Y-%m-%dT%H:%M:%S%z')
---
$MESSAGE
EOF

DELIVERED=0
for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
  [ "$pane" = "$MY_PANE" ] && continue
  PANE_SAFE=$(echo "$pane" | tr ':.' '_')
  cp "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" "${RUNTIME_DIR}/messages/${PANE_SAFE}_${TIMESTAMP}.msg"
  DELIVERED=$((DELIVERED + 1))
done
echo "Broadcast delivered to ${DELIVERED} panes"
```

Report delivery count.
