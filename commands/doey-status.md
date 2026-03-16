# Skill: doey-status

Share your status or check the status of other Claude instances.

## Usage
`/doey-status`

## Prompt
You are managing status updates across Claude Code instances in TMUX.

### Steps

1. **Discover runtime and identity:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
   ```

2. **Default action: view all statuses** (run the "Viewing statuses" block below). Only use "Setting status" if the user explicitly asked to set/update their status.

### Setting status
Valid values: READY, BUSY, FINISHED, RESERVED.
```bash
cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" <<EOF
PANE: $MY_PANE
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: $STATUS_TEXT
TASK: $CURRENT_TASK
EOF
```

### Viewing statuses
```bash
for f in "${RUNTIME_DIR}/status/"*.status; do echo "---"; cat "$f"; done
for f in "${RUNTIME_DIR}/status/"*.reserved; do
  [ -f "$f" ] || continue
  echo "RESERVED: $(basename "$f" .reserved)"
done
```

Display a summary table: pane, status, task, RESERVED for panes with active `.reserved` files.
