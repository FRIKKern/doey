# Skill: doey-monitor

Monitor worker panes — reads status files (FINISHED, BUSY, ERROR, READY, RESERVED).

## Usage
`/doey-monitor`

## Prompt
Monitor Claude Code worker instances in tmux.

### Preamble

Every Bash call must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

### Status Table

```bash
# (preamble)
STATUS_DIR="${RUNTIME_DIR}/status"; NOW=$(date +%s)
printf "%-6s | %-12s | %-10s | %-30s | %s\n" "PANE" "STATUS" "RESERVED" "TASK" "UPDATED"
printf -- "-------+--------------+------------+--------------------------------+--------\n"
for i in $(echo "${WORKER_PANES}" | tr ',' ' '); do
  PANE_ID="${SESSION_NAME}:${WINDOW_INDEX}.${i}"
  PANE_SAFE=$(echo "${PANE_ID}" | tr ':.' '_')
  SF="${STATUS_DIR}/${PANE_SAFE}.status"
  [ -f "$SF" ] && STATUS=$(grep '^STATUS: ' "$SF" | head -1 | cut -d' ' -f2-) || STATUS="UNKNOWN"
  RF="${RUNTIME_DIR}/results/pane_${WINDOW_INDEX}_${i}.json"
  if [ "$STATUS" = "FINISHED" ] && [ -f "$RF" ]; then
    RS=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$RF" | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//;s/"//')
    [ -n "$RS" ] && STATUS="FINISHED (${RS})"
  fi
  [ -f "${STATUS_DIR}/${PANE_SAFE}.reserved" ] && RESERVED="RESERVED" && STATUS="RESERVED" || RESERVED="-"
  TASK=$(tmux display-message -t "$PANE_ID" -p '#{pane_title}' 2>/dev/null || echo "-")
  [ -z "$TASK" ] && TASK="-"
  if [ -f "$SF" ]; then
    MTIME=$(stat -f %m "$SF" 2>/dev/null || stat -c %Y "$SF" 2>/dev/null || echo "$NOW")
    AGO=$(( NOW - MTIME ))
    if [ "$AGO" -lt 60 ]; then UPDATED="${AGO}s ago"
    elif [ "$AGO" -lt 3600 ]; then UPDATED="$(( AGO / 60 ))m ago"
    else UPDATED="$(( AGO / 3600 ))h ago"; fi
  else UPDATED="-"; fi
  printf "%-6s | %-12s | %-10s | %-30s | %s\n" "W${i}" "$STATUS" "$RESERVED" "$TASK" "$UPDATED"
done
```

### Crash Alerts & Watchdog Health

```bash
# (preamble)
NOW=$(date +%s); CRASH_FOUND=false
for f in "${RUNTIME_DIR}/status"/crash_pane_*; do
  [ -f "$f" ] || continue; CRASH_FOUND=true
  echo "CRASH ALERT:" && cat "$f"
done
$CRASH_FOUND || echo "No crash alerts."
HB_FILE="${RUNTIME_DIR}/status/watchdog_W${WINDOW_INDEX}.heartbeat"
if [ -f "$HB_FILE" ]; then
  HB_AGO=$(( NOW - $(cat "$HB_FILE") ))
  [ "$HB_AGO" -gt 120 ] && echo "Watchdog heartbeat stale: ${HB_AGO}s ago" || echo "Watchdog heartbeat: ${HB_AGO}s ago (healthy)"
else echo "No Watchdog heartbeat file found"; fi
```

### Deep Inspect (replace X with pane index)

```bash
# (preamble)
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "${PANE}" | tr ':.' '_')
cat "${RUNTIME_DIR}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"
echo "--- Last 20 lines ---"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

### Watching Mode

Wrap Status Table in `while true; do ... sleep 15; done`. Print `"[%H:%M:%S] Worker Status"` header. Track `ALL_DONE=true`; set false if any non-reserved worker is not FINISHED/READY. Break when all done.

### Error Recovery

**Unstick:** exit copy-mode → `C-c` (0.5s) → `C-u` (0.5s) → `Enter` (3s) → check for `❯`. After 2 failures, see `/doey-dispatch` Troubleshooting.

**Nudge idle:** exit copy-mode → `Enter` (5s) → grep for `thinking|working|Read|Edit|Bash`. Still idle → unstick or re-dispatch.

### Rules

1. **Never interrupt BUSY** — only recover ERROR/unresponsive
2. **Status from files** (`${RUNTIME_DIR}/status/`) — never parse pane output
3. **Min 15s poll interval** | **Always exit copy-mode before send-keys**
