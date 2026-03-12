# Skill: doey-broadcast

Broadcast a message to ALL other Claude instances in TMUX.

## Usage
`/doey-broadcast`

## Prompt
You are broadcasting a message to all other Claude Code instances.

### Step 1: Get the message

Ask the user for the broadcast message if not already provided as an argument. Store it in `$MESSAGE`.

### Step 2: Create broadcast and deliver to all panes

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
TIMESTAMP=$(gdate +%s%N 2>/dev/null || echo "$(date +%s)$$")

mkdir -p "${RUNTIME_DIR}/broadcasts" "${RUNTIME_DIR}/messages"

MESSAGE="YOUR_MESSAGE_HERE"

cat > "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" <<EOF
FROM: $MY_PANE
TIME: $(date -Iseconds)
---
$MESSAGE
EOF

DELIVERED=0
for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
  [ "$pane" = "$MY_PANE" ] && continue
  PANE_SAFE=${pane//[:.]/_}
  cp "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" "${RUNTIME_DIR}/messages/${PANE_SAFE}_${TIMESTAMP}.msg"
  DELIVERED=$((DELIVERED + 1))
done

echo "Broadcast delivered to ${DELIVERED} panes"
```

Replace `YOUR_MESSAGE_HERE` with the actual message before running.

### Step 3: Confirm delivery

# Delivery handled by Watchdog (checks idle state before sending)

Report how many panes the broadcast was queued for. The Watchdog will deliver to each pane when it is idle.
