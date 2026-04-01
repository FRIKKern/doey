---
name: doey-monitor
description: Monitor worker panes — reads status files (FINISHED, BUSY, ERROR, READY, RESERVED). Use when you need to "watch worker progress", "check for crashed panes", or "poll until workers finish".
---

- Statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f"; done 2>/dev/null || true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`
- Results: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/results/pane_${W}_*.json; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f"; done 2>/dev/null || true`
- Crashes: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/crash_pane_*; do [ -f "$f" ] && echo "CRASH:" && cat "$f"; done 2>/dev/null || true`
- Titles: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); W="${DOEY_WINDOW_INDEX:-0}"; for p in $(tmux list-panes -t "$SESSION:$W" -F '#{pane_index}' 2>/dev/null); do echo "$W.$p: $(tmux display-message -t "$SESSION:$W.$p" -p '#{pane_title}' 2>/dev/null)"; done || true`

Table: `PANE | STATUS | RESERVED | TASK | UPDATED`. Enrich FINISHED from `.json`. Task from pane title.

### Deep Inspect
```bash
PANE="${SESSION_NAME}:${DOEY_WINDOW_INDEX:-0}.X"; PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status)"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(not found)"
```

### Watch: poll 15s, break when all non-reserved = FINISHED/READY

### Error Recovery
- **Unstick:** copy-mode -q → C-c (0.5s) → C-u (0.5s) → Enter (3s) → check ❯. 2 fails → `/doey-dispatch` Unstick
- **Nudge idle:** copy-mode -q → Enter (5s) → grep activity → unstick/re-dispatch

Never interrupt BUSY. Status from files only. Min 15s poll.
