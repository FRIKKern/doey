---
name: doey-monitor
description: Monitor worker panes — reads status files (FINISHED, BUSY, ERROR, READY, RESERVED). Use when you need to "watch worker progress", "check for crashed panes", or "poll until workers finish".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team config: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; [ -f "$RD/team_${W}.env" ] && cat "$RD/team_${W}.env" 2>/dev/null|| true`
- Statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`
- Results: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/results/pane_${W}_*.json; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Crashes: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/crash_pane_*; do [ -f "$f" ] && echo "CRASH:" && cat "$f"; done 2>/dev/null || true`
- Pane titles: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); W="${DOEY_WINDOW_INDEX:-0}"; for p in $(tmux list-panes -t "$SESSION:$W" -F '#{pane_index}' 2>/dev/null); do TITLE=$(tmux display-message -t "$SESSION:$W.$p" -p '#{pane_title}' 2>/dev/null); echo "$W.$p: $TITLE"; done || true`

Build table: `PANE | STATUS | RESERVED | TASK | UPDATED`. Enrich FINISHED with `.json` result. Task from pane title.

### Deep Inspect
```bash
PANE="${SESSION_NAME}:${DOEY_WINDOW_INDEX:-0}.X"; PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

### Watching
Poll every 15s. Break when all non-reserved workers are FINISHED/READY.

### Error Recovery
**Unstick:** exit copy-mode → `C-c` (0.5s) → `C-u` (0.5s) → Enter (3s) → check `❯`. After 2 failures → `/doey-dispatch` Unstick.
**Nudge idle:** exit copy-mode → Enter (5s) → grep `thinking|working|Read|Edit|Bash`. Still idle → unstick or re-dispatch.

### Rules
- Never interrupt BUSY — only recover ERROR/unresponsive
- Status from files — never parse pane output; min 15s poll
