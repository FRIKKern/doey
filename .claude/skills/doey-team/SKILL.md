---
name: doey-team
description: Show team status and reservations across all panes
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null`
- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null`
- All panes: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-panes -s -t "$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null`
- All statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null`

Build a table from the injected data:

```
PANE           STATUS       RESERVED   LAST_UPDATE
----           ------       --------   -----------
```

For each pane in the session:
- Convert pane ID to safe name (`:` and `.` → `_`) to find its status file.
- Extract STATUS from the status file, or "UNKNOWN" if missing.
- Check for `.reserved` file → show "RSV" if present.
- Show last modification time of status file.
- Mark the current pane with `<-- you`.

Report the table. Note any UNKNOWN-status panes.
