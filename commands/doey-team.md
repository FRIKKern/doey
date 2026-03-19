# Skill: doey-team

Show team status and reservations.

## Usage
`/doey-team`

## Prompt

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
printf "%-14s %-12s %-10s %s\n" "PANE" "STATUS" "RESERVED" "LAST_UPDATE"
printf "%-14s %-12s %-10s %s\n" "----" "------" "--------" "-----------"
for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
  PANE_SAFE=$(echo "$pane" | tr ':.' '_')
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  if [ -f "$STATUS_FILE" ]; then
    STATUS=$(grep '^STATUS: ' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d' ' -f2- || echo "UNKNOWN")
    LAST_MOD=$(stat -f "%Sm" -t "%H:%M:%S" "$STATUS_FILE" 2>/dev/null || stat -c "%y" "$STATUS_FILE" 2>/dev/null | cut -d. -f1)
  else
    STATUS="UNKNOWN"; LAST_MOD="-"
  fi
  RESERVED="-"; [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && RESERVED="RSV"
  MARKER=""; [ "$pane" = "$MY_PANE" ] && MARKER=" <-- you"
  printf "%-14s %-12s %-10s %s%s\n" "$pane" "$STATUS" "$RESERVED" "$LAST_MOD" "$MARKER"
done
```

Report the table. Note any UNKNOWN-status panes.
