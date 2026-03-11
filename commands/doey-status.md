# Skill: doey-status

Share your status or check the status of other Claude instances.

## Usage
`/doey-status`

## Prompt
You are managing status updates across Claude Code instances in TMUX.

### Steps

1. Discover runtime directory and identify yourself:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=${MY_PANE//[:.]/_}
   ```

2. Ask the user: **set** your status or **view** all statuses?

### Status values
Valid statuses: IDLE, WORKING, RESERVED. RESERVED is set by `/doey-reserve` (permanent) or auto-reserve (60s on human input).

### Setting status
Write your current status:
```bash
cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" <<EOF
PANE: $MY_PANE
UPDATED: $(date -Iseconds)
STATUS: $STATUS_TEXT
TASK: $CURRENT_TASK
EOF
```

### Viewing statuses
Read all status files:
```bash
for f in "${RUNTIME_DIR}/status/"*.status; do
  echo "---"
  cat "$f"
done
```

Check for reserved panes:
```bash
for f in "${RUNTIME_DIR}/status/"*.reserved; do
  if [ -f "$f" ]; then
    EXPIRY=$(head -1 "$f")
    if [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ]; then
      echo "RESERVED: $(basename "$f" .reserved) (expires: $EXPIRY)"
    fi
  fi
done
```

Display a summary table showing each pane, its status, and what task it's working on. Show RESERVED status for panes with active `.reserved` files.
