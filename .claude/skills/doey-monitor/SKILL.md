---
name: doey-monitor
description: Monitor worker panes — reads status files (FINISHED, BUSY, ERROR, READY, RESERVED)
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team config: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; [ -f "$RD/team_${W}.env" ] && cat "$RD/team_${W}.env" 2>/dev/null|| true`
- Worker statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`
- Results: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/results/pane_${W}_*.json; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Crash alerts: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/crash_pane_*; do [ -f "$f" ] && echo "CRASH:" && cat "$f"; done 2>/dev/null || true`
- Watchdog heartbeat: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; HB="$RD/status/watchdog_W${W}.heartbeat"; [ -f "$HB" ] && echo "heartbeat: $(cat $HB) age: $(( $(date +%s) - $(cat $HB) ))s" || echo "No watchdog heartbeat"`
- Pane titles: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); W="${DOEY_WINDOW_INDEX:-0}"; for p in $(tmux list-panes -t "$SESSION:$W" -F '#{pane_index}' 2>/dev/null); do TITLE=$(tmux display-message -t "$SESSION:$W.$p" -p '#{pane_title}' 2>/dev/null); echo "$W.$p: $TITLE"; done || true`

### Status Table

Build a table from the injected data:

```
PANE   | STATUS       | RESERVED   | TASK                           | UPDATED
-------+--------------+------------+--------------------------------+--------
```

For each worker pane (from WORKER_PANES in team config):
- Status from `.status` file. If FINISHED, enrich with result status from `.json`.
- If `.reserved` file exists, show RESERVED.
- Task from pane title.
- Updated = age of status file modification time.

### Deep Inspect (replace X with pane index)

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
source "$RD/session.env"
W="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${W}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
cat "${RD}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"
echo "--- Last 20 lines ---"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

### Watching Mode

Wrap Status Table check in `while true; do ... sleep 15; done`. Print `"[%H:%M:%S] Worker Status"` header. Track `ALL_DONE=true`; set false if any non-reserved worker is not FINISHED/READY. Break when all done.

### Error Recovery

**Unstick:** exit copy-mode → `C-c` (0.5s) → `C-u` (0.5s) → `Enter` (3s) → check for `❯`. After 2 failures, see `/doey-dispatch` Troubleshooting.

**Nudge idle:** exit copy-mode → `Enter` (5s) → grep for `thinking|working|Read|Edit|Bash`. Still idle → unstick or re-dispatch.

### Rules

1. **Never interrupt BUSY** — only recover ERROR/unresponsive
2. **Status from files** (`${RUNTIME_DIR}/status/`) — never parse pane output
3. **Min 15s poll interval** | **Always exit copy-mode before send-keys**
