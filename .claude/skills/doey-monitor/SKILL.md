---
name: doey-monitor
description: Monitor worker panes — reads status files (FINISHED, BUSY, ERROR, READY, RESERVED). Use when you need to "watch worker progress", "check for crashed panes", or "poll until workers finish".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team config: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; [ -f "$RD/team_${W}.env" ] && cat "$RD/team_${W}.env" 2>/dev/null|| true`
- Worker statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`
- Results: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/results/pane_${W}_*.json; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Crash alerts: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/crash_pane_*; do [ -f "$f" ] && echo "CRASH:" && cat "$f"; done 2>/dev/null || true`
- Watchdog heartbeat: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; HB="$RD/status/watchdog_W${W}.heartbeat"; [ -f "$HB" ] && echo "heartbeat: $(cat $HB) age: $(( $(date +%s) - $(cat $HB) ))s" || echo "No watchdog heartbeat"`
- Pane titles: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); W="${DOEY_WINDOW_INDEX:-0}"; for p in $(tmux list-panes -t "$SESSION:$W" -F '#{pane_index}' 2>/dev/null); do TITLE=$(tmux display-message -t "$SESSION:$W.$p" -p '#{pane_title}' 2>/dev/null); echo "$W.$p: $TITLE"; done || true`

**Expected:** 1-2 tmux commands (capture-pane for deep inspect), 5-6 file reads (status + results + heartbeat), ~5s per poll cycle.

### Status Table

Build from injected data: `PANE | STATUS | RESERVED | TASK | UPDATED`. For each worker pane (WORKER_PANES): status from `.status` file (enrich FINISHED with `.json` result), `.reserved` flag, task from pane title, age of status file.

### Deep Inspect (replace X with pane index)

```bash
PANE="${SESSION_NAME}:${DOEY_WINDOW_INDEX:-0}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"
echo "--- Last 20 lines ---"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

### Watching Mode

Poll every 15s with `[%H:%M:%S]` header. Track ALL_DONE; break when all non-reserved workers are FINISHED/READY.

### Error Recovery

**Unstick:** exit copy-mode → `C-c` (0.5s) → `C-u` (0.5s) → `Enter` (3s) → check for `❯`. After 2 failures, see `/doey-dispatch` Unstick section.

**Nudge idle:** exit copy-mode → `Enter` (5s) → grep for `thinking|working|Read|Edit|Bash`. Still idle → unstick or re-dispatch.

### Rules
1. **Never interrupt BUSY** — only recover ERROR/unresponsive
2. **Status from files** — never parse pane output
3. **Min 15s poll** | **Always exit copy-mode before send-keys**
