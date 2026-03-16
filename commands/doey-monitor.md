# Skill: doey-monitor

Smart monitoring of all worker panes — detects FINISHED, BUSY, ERROR, READY, and RESERVED states from status files.

## Usage
`/doey-monitor`

## Prompt
You are monitoring the status of all Claude Code worker instances in TMUX.

### Project Context

Every Bash call that touches tmux or status files must start with this preamble (provides `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WORKER_COUNT`, `WATCHDOG_PANE`, `WINDOW_INDEX`):

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

**Always use `${SESSION_NAME}`** — never hardcode session names.

### Quick Status Check

Single bash block — reads all status files and prints a formatted table. Starts with the preamble above, then:

```bash
# (preamble from Project Context)
STATUS_DIR="${RUNTIME_DIR}/status"
NOW=$(date +%s)

printf "%-6s | %-12s | %-10s | %-30s | %s\n" "PANE" "STATUS" "RESERVED" "TASK" "LAST_UPDATED"
printf "%-6s-+-%-12s-+-%-10s-+-%-30s-+-%s\n" "------" "------------" "----------" "------------------------------" "------------"

for i in $(echo "${WORKER_PANES}" | tr ',' ' '); do
  PANE_ID="${SESSION_NAME}:${WINDOW_INDEX}.${i}"
  PANE_SAFE=$(echo "${PANE_ID}" | tr ':.' '_')

  STATUS_FILE="${STATUS_DIR}/${PANE_SAFE}.status"
  if [ -f "$STATUS_FILE" ]; then
    STATUS=$(grep '^STATUS: ' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d' ' -f2- || echo "UNKNOWN")
  else
    STATUS="UNKNOWN"
  fi

  RESULT_FILE="${RUNTIME_DIR}/results/pane_${WINDOW_INDEX}_${i}.json"
  if [ "$STATUS" = "FINISHED" ] && [ -f "$RESULT_FILE" ]; then
    RESULT_STATUS=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//;s/"//')
    [ -n "$RESULT_STATUS" ] && STATUS="FINISHED (${RESULT_STATUS})"
  fi

  RESERVE_FILE="${STATUS_DIR}/${PANE_SAFE}.reserved"
  RESERVED="-"
  if [ -f "$RESERVE_FILE" ]; then
    RESERVED="RESERVED"; STATUS="RESERVED"
  fi

  TASK=$(tmux display-message -t "$PANE_ID" -p '#{pane_title}' 2>/dev/null || echo "-")
  [ -z "$TASK" ] && TASK="-"

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

### Crash Alerts & Watchdog Health

Run after the status table. Uses preamble vars from Project Context.

```bash
# (preamble from Project Context)
NOW=$(date +%s)

CRASH_FOUND=false
for f in "${RUNTIME_DIR}/status"/crash_pane_*; do
  [ -f "$f" ] || continue
  CRASH_FOUND=true
  echo "CRASH ALERT:" && cat "$f"
done
$CRASH_FOUND || echo "No crash alerts."

HB_FILE="${RUNTIME_DIR}/status/watchdog_W${WINDOW_INDEX}.heartbeat"
if [ -f "$HB_FILE" ]; then
  HB_AGO=$(( NOW - $(cat "$HB_FILE") ))
  if [ "$HB_AGO" -gt 120 ]; then
    echo "Watchdog heartbeat stale: ${HB_AGO}s ago"
  else
    echo "Watchdog heartbeat: ${HB_AGO}s ago (healthy)"
  fi
else
  echo "No Watchdog heartbeat file found"
fi
```

### Deep Inspect

Capture last 20 lines of a specific worker pane. Replace `X` with pane index.

```bash
# (preamble from Project Context)
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "${PANE}" | tr ':.' '_')
echo "=== Deep Inspect: ${PANE} ==="
echo "--- Status file ---"
cat "${RUNTIME_DIR}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"
echo "--- Last 20 lines ---"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

### Watching Mode (continuous)

Wrap the Quick Status Check in a `while true` poll with 15-second sleep:
- Print timestamp header: `printf "[%s] Worker Status\n\n" "$(date +%H:%M:%S)"`
- Track `ALL_DONE=true`; set to `false` if any non-reserved worker is not FINISHED/READY
- If `ALL_DONE`, print "All non-reserved workers are FINISHED or READY" and `break`
- Otherwise print "Watching... (next check in 15s)" and `sleep 15`

### Error Recovery

**Unstick a worker** (ERROR or unresponsive): exit copy-mode, then send `C-c`, wait 0.5s, `C-u`, wait 0.5s, `Enter`, wait 3s, capture output. If `❯` prompt appears, worker recovered. If still stuck after 2 attempts, force-kill and restart — see `/doey-dispatch` **Troubleshooting: Unstick a non-responsive worker**.

**Nudge a dispatched worker** that hasn't started after 10s: exit copy-mode, send `Enter`, wait 5s, check for `thinking|working|Read|Edit|Bash` in captured output. If still idle, use the unstick sequence above or re-dispatch.

### Rules

1. **Never interrupt a BUSY worker** — only recover ERROR or unresponsive workers
2. **Always read status files** from `${RUNTIME_DIR}/status/` — do not parse pane output for state detection
3. **Do NOT poll more frequently than every 15 seconds** in watching mode
4. **Report errors immediately** — capture deep inspect output and include in report
5. **Always exit copy-mode** before sending keys: `tmux copy-mode -q -t "$PANE" 2>/dev/null`
