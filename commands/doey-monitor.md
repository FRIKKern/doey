# Skill: doey-monitor

Smart monitoring of all worker panes — detects FINISHED, BUSY, ERROR, READY, and RESERVED states from status files.

## Usage
`/doey-monitor`

## Prompt
You are monitoring the status of all Claude Code worker instances in TMUX.

### Project Context (read once per Bash call)

Every Bash call that touches tmux or status files must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WORKER_COUNT`, `WATCHDOG_PANE`, `TOTAL_PANES`. **Always use `${SESSION_NAME}`** — never hardcode session names.

### Quick Status Check

Single bash block — reads all status files and prints a formatted table.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

STATUS_DIR="${RUNTIME_DIR}/status"
NOW=$(date +%s)

printf "%-6s | %-12s | %-10s | %-30s | %s\n" "PANE" "STATUS" "RESERVED" "TASK" "LAST_UPDATED"
printf "%-6s-+-%-12s-+-%-10s-+-%-30s-+-%s\n" "------" "------------" "----------" "------------------------------" "------------"

for i in $(echo "${WORKER_PANES}" | tr ',' ' '); do
  PANE_ID="${SESSION_NAME}:0.${i}"
  PANE_SAFE=$(echo "${PANE_ID}" | tr ':.' '_')

  # Read status file
  STATUS_FILE="${STATUS_DIR}/${PANE_SAFE}.status"
  if [ -f "$STATUS_FILE" ]; then
    STATUS=$(grep '^STATUS: ' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d' ' -f2- || echo "UNKNOWN")
  else
    STATUS="UNKNOWN"
  fi

  # Read reservation
  RESERVE_FILE="${STATUS_DIR}/${PANE_SAFE}.reserved"
  RESERVED="-"
  if [ -f "$RESERVE_FILE" ]; then
    EXPIRY=$(head -1 "$RESERVE_FILE" 2>/dev/null || echo "")
    if [ "$EXPIRY" = "permanent" ]; then
      RESERVED="permanent"
      STATUS="RESERVED"
    elif [ -n "$EXPIRY" ] && [ "$NOW" -lt "$EXPIRY" ] 2>/dev/null; then
      RESERVED="$((EXPIRY - NOW))s left"
      STATUS="RESERVED"
    fi
  fi

  # Read task name from pane title
  TASK=$(tmux display-message -t "$PANE_ID" -p '#{pane_title}' 2>/dev/null || echo "-")
  [ -z "$TASK" ] && TASK="-"

  # Last updated (mtime of status file)
  if [ -f "$STATUS_FILE" ]; then
    MTIME=$(stat -f %m "$STATUS_FILE" 2>/dev/null || stat -c %Y "$STATUS_FILE" 2>/dev/null || echo "$NOW")
    AGO=$(( NOW - MTIME ))
    if [ "$AGO" -lt 60 ]; then UPDATED="${AGO}s ago"
    elif [ "$AGO" -lt 3600 ]; then UPDATED="$(( AGO / 60 ))m ago"
    else UPDATED="$(( AGO / 3600 ))h ago"; fi
  else
    UPDATED="-"
  fi

  printf "%-6s | %-12s | %-10s | %-30s | %s\n" "W${i}" "$STATUS" "$RESERVED" "$TASK" "$UPDATED"
done
```

### Deep Inspect

Capture last 20 lines of a specific worker pane for detailed inspection.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"
echo "=== Deep Inspect: ${PANE} ==="

# Status file contents
PANE_SAFE=$(echo "${PANE}" | tr ':.' '_')
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
echo "--- Status file ---"
cat "$STATUS_FILE" 2>/dev/null || echo "(no status file)"

echo "--- Last 20 lines ---"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

### Watching Mode (continuous)

Polls every 15 seconds. Exits when all non-reserved workers show FINISHED or READY.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

STATUS_DIR="${RUNTIME_DIR}/status"

while true; do
  NOW=$(date +%s)
  ALL_DONE=true
  clear

  printf "[%s] Worker Status\n\n" "$(date +%H:%M:%S)"
  printf "%-6s | %-12s | %-10s | %-30s | %s\n" "PANE" "STATUS" "RESERVED" "TASK" "LAST_UPDATED"
  printf "%-6s-+-%-12s-+-%-10s-+-%-30s-+-%s\n" "------" "------------" "----------" "------------------------------" "------------"

  for i in $(echo "${WORKER_PANES}" | tr ',' ' '); do
    PANE_ID="${SESSION_NAME}:0.${i}"
    PANE_SAFE=$(echo "${PANE_ID}" | tr ':.' '_')

    # Read status
    STATUS_FILE="${STATUS_DIR}/${PANE_SAFE}.status"
    if [ -f "$STATUS_FILE" ]; then
      STATUS=$(grep '^STATUS: ' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d' ' -f2- || echo "UNKNOWN")
    else
      STATUS="UNKNOWN"
    fi

    # Read reservation
    RESERVE_FILE="${STATUS_DIR}/${PANE_SAFE}.reserved"
    IS_RESERVED=false
    RESERVED="-"
    if [ -f "$RESERVE_FILE" ]; then
      EXPIRY=$(head -1 "$RESERVE_FILE" 2>/dev/null || echo "")
      if [ "$EXPIRY" = "permanent" ]; then
        RESERVED="permanent"; IS_RESERVED=true; STATUS="RESERVED"
      elif [ -n "$EXPIRY" ] && [ "$NOW" -lt "$EXPIRY" ] 2>/dev/null; then
        RESERVED="$((EXPIRY - NOW))s left"; IS_RESERVED=true; STATUS="RESERVED"
      fi
    fi

    # Task name
    TASK=$(tmux display-message -t "$PANE_ID" -p '#{pane_title}' 2>/dev/null || echo "-")
    [ -z "$TASK" ] && TASK="-"

    # Last updated
    if [ -f "$STATUS_FILE" ]; then
      MTIME=$(stat -f %m "$STATUS_FILE" 2>/dev/null || stat -c %Y "$STATUS_FILE" 2>/dev/null || echo "$NOW")
      AGO=$(( NOW - MTIME ))
      if [ "$AGO" -lt 60 ]; then UPDATED="${AGO}s ago"
      elif [ "$AGO" -lt 3600 ]; then UPDATED="$(( AGO / 60 ))m ago"
      else UPDATED="$(( AGO / 3600 ))h ago"; fi
    else
      UPDATED="-"
    fi

    printf "%-6s | %-12s | %-10s | %-30s | %s\n" "W${i}" "$STATUS" "$RESERVED" "$TASK" "$UPDATED"

    # Check if this worker is still active (not done)
    if [ "$IS_RESERVED" = "false" ] && [ "$STATUS" != "FINISHED" ] && [ "$STATUS" != "READY" ]; then
      ALL_DONE=false
    fi
  done

  echo ""
  if [ "$ALL_DONE" = "true" ]; then
    echo "All non-reserved workers are FINISHED or READY. Exiting watch."
    break
  fi

  echo "Watching... (next check in 15s)"
  sleep 15
done
```

### Error Recovery

Concrete recovery commands for common failure states.

**Unstick a worker showing ERROR or unresponsive state:**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"

# Exit copy-mode first
tmux copy-mode -q -t "$PANE" 2>/dev/null

# Send Ctrl+C to interrupt, then clear input
tmux send-keys -t "$PANE" C-c
sleep 1
tmux send-keys -t "$PANE" C-u
sleep 0.5

# Check if worker recovered to prompt
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5 2>/dev/null)
if echo "$OUTPUT" | grep -q '❯'; then
  echo "Worker 0.X recovered — idle at prompt, ready for re-dispatch"
else
  echo "Worker 0.X still stuck — force-killing process"
  PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
  sleep 2
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter
  sleep 8
  echo "Worker 0.X restarted — ready for re-dispatch"
fi
```

**Nudge a QUEUED worker that hasn't started processing after 10s:**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" Enter
sleep 5

OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5 2>/dev/null)
if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "Worker 0.X now processing"
else
  echo "Worker 0.X still not processing — use error recovery or re-dispatch"
fi
```

### Rules

1. **Never interrupt a BUSY worker** — only recover ERROR or unresponsive workers
2. **Always read status files** from `${RUNTIME_DIR}/status/` — do not parse pane output for state detection
3. **Do NOT poll more frequently than every 15 seconds** in watching mode
4. **Report errors immediately** — capture deep inspect output and include in report
5. **Always exit copy-mode** before sending keys: `tmux copy-mode -q -t "$PANE" 2>/dev/null`
