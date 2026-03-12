# Skill: doey-team

View the full team of Claude instances, their status, reservations, and unread messages.

## Usage
`/doey-team`

## Prompt
You are showing the team overview of all Claude Code instances in TMUX.

### Gather and display team status

Run this single bash block to print the full team table:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
NOW=$(date +%s)

printf "%-14s %-12s %-10s %-6s %s\n" "PANE" "STATUS" "RESERVED" "MSGS" "LAST_UPDATE"
printf "%-14s %-12s %-10s %-6s %s\n" "----" "------" "--------" "----" "-----------"

for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
  PANE_SAFE=${pane//[:.]/_}

  # Status
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  if [ -f "$STATUS_FILE" ]; then
    STATUS=$(grep '^STATUS: ' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d' ' -f2- || echo "UNKNOWN")
    LAST_MOD=$(stat -f "%Sm" -t "%H:%M:%S" "$STATUS_FILE" 2>/dev/null || stat -c "%y" "$STATUS_FILE" 2>/dev/null | cut -d. -f1)
  else
    STATUS="UNKNOWN"
    LAST_MOD="-"
  fi

  # Reservation
  RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
  RESERVED="-"
  if [ -f "$RESERVE_FILE" ]; then
    RESERVED="RSV"
  fi

  # Unread messages
  MSG_COUNT=$(ls "${RUNTIME_DIR}/messages/${PANE_SAFE}_"*.msg 2>/dev/null | wc -l | tr -d ' ')

  # Mark current pane
  MARKER=""
  [ "$pane" = "$MY_PANE" ] && MARKER=" <-- you"

  printf "%-14s %-12s %-10s %-6s %s%s\n" "$pane" "$STATUS" "$RESERVED" "$MSG_COUNT" "$LAST_MOD" "$MARKER"
done
```

Report the table output to the user. If any panes show issues (UNKNOWN status, high message counts), note them briefly.
