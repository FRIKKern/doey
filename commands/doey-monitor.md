# Skill: doey-monitor

Monitors worker panes — detects FINISHED, BUSY, ERROR, READY, RESERVED from status files.

## Usage
`/doey-monitor`

## Prompt

### Project Context
Same as `/doey-dispatch` — source `session.env` and team env.

### Quick Status Check

```bash
# (load context: RUNTIME_DIR, session.env, team env)
STATUS_DIR="${RUNTIME_DIR}/status"; NOW=$(date +%s)
printf "%-6s | %-12s | %-10s | %-30s | %s\n" "PANE" "STATUS" "RESERVED" "TASK" "LAST_UPDATED"
printf "%-6s-+-%-12s-+-%-10s-+-%-30s-+-%s\n" "------" "------------" "----------" "------------------------------" "------------"

for i in $(echo "${WORKER_PANES}" | tr ',' ' '); do
  PANE_ID="${SESSION_NAME}:${WINDOW_INDEX}.${i}"
  PANE_SAFE=$(echo "${PANE_ID}" | tr ':.' '_')
  STATUS_FILE="${STATUS_DIR}/${PANE_SAFE}.status"

  STATUS="UNKNOWN"
  [ -f "$STATUS_FILE" ] && STATUS=$(grep '^STATUS: ' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d' ' -f2-)

  # Enrich FINISHED with result status
  RESULT_FILE="${RUNTIME_DIR}/results/pane_${WINDOW_INDEX}_${i}.json"
  if [ "$STATUS" = "FINISHED" ] && [ -f "$RESULT_FILE" ]; then
    RS=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$RESULT_FILE" | head -1 | sed 's/.*"//;s/"//')
    [ -n "$RS" ] && STATUS="FINISHED ($RS)"
  fi

  RESERVED="-"
  [ -f "${STATUS_DIR}/${PANE_SAFE}.reserved" ] && RESERVED="RESERVED" && STATUS="RESERVED"
  TASK=$(tmux display-message -t "$PANE_ID" -p '#{pane_title}' 2>/dev/null || echo "-")

  UPDATED="-"
  if [ -f "$STATUS_FILE" ]; then
    MTIME=$(stat -f %m "$STATUS_FILE" 2>/dev/null || stat -c %Y "$STATUS_FILE" 2>/dev/null || echo "$NOW")
    AGO=$((NOW - MTIME))
    if [ "$AGO" -lt 60 ]; then UPDATED="${AGO}s ago"
    elif [ "$AGO" -lt 3600 ]; then UPDATED="$((AGO / 60))m ago"
    else UPDATED="$((AGO / 3600))h ago"; fi
  fi
  printf "%-6s | %-12s | %-10s | %-30s | %s\n" "W${i}" "$STATUS" "$RESERVED" "$TASK" "$UPDATED"
done
```

### Crash Alerts & Watchdog Health

```bash
NOW=$(date +%s); CRASH_FOUND=false
for f in "${RUNTIME_DIR}/status"/crash_pane_*; do
  [ -f "$f" ] || continue; CRASH_FOUND=true; echo "CRASH ALERT:" && cat "$f"
done
$CRASH_FOUND || echo "No crash alerts."

HB_FILE="${RUNTIME_DIR}/status/watchdog_W${WINDOW_INDEX}.heartbeat"
if [ -f "$HB_FILE" ]; then
  HB_AGO=$((NOW - $(cat "$HB_FILE")))
  [ "$HB_AGO" -gt 120 ] && echo "Watchdog heartbeat stale: ${HB_AGO}s" || echo "Watchdog heartbeat: ${HB_AGO}s (healthy)"
else echo "No Watchdog heartbeat file"; fi
```

### Deep Inspect

Show status file + last 20 lines for pane `${SESSION_NAME}:${WINDOW_INDEX}.X`.

### Watching Mode

Poll every 15s. Break when all non-reserved workers are FINISHED or READY.

### Error Recovery

See `/doey-dispatch` Unstick section. Summary: `copy-mode -q` → `C-c` → `C-u` → `Enter`, wait 3s. After 2 fails: kill + restart.

### Rules
1. Never interrupt BUSY workers — only recover ERROR/unresponsive
2. State from status files, not pane output
3. Poll minimum 15s in watching mode
4. Exit copy-mode before send-keys
