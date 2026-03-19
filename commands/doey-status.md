# Skill: doey-status

View or set pane status.

## Usage
`/doey-status`

## Prompt

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
```

**Default: view all statuses.** Only set status if user explicitly asks.

### Viewing
```bash
for f in "${RUNTIME_DIR}/status/"*.status; do echo "---"; cat "$f"; done
for f in "${RUNTIME_DIR}/status/"*.reserved; do [ -f "$f" ] || continue; echo "RESERVED: $(basename "$f" .reserved)"; done
```

Display a summary table: pane, status, task, reservations.

### Setting (READY|BUSY|FINISHED|RESERVED)
```bash
cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" <<EOF
PANE: $MY_PANE
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: $STATUS_TEXT
TASK: $CURRENT_TASK
EOF
```
