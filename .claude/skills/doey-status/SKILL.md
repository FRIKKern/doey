---
name: doey-status
description: View or set pane status for Doey workers. Team-wide view with `/doey-status team`. Use when you need to "check worker status", "see which panes are busy", or "set a pane to READY".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All panes: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-panes -s -t "$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All statuses: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.status; do [ -f "$f" ] && echo "---" && cat "$f"; done 2>/dev/null || true`
- Reservations: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename "$f" .reserved)"; done 2>/dev/null || true`

Default: view current window statuses. Only set if user explicitly asks.

### View (default)
Table from injected data: pane, status, task, reservations. Mark current pane with `<-- you`.

### Team-wide (`/doey-status team`)
All panes across all windows: `PANE | STATUS | RESERVED | LAST_UPDATE`. Note UNKNOWN panes.

### Set (`/doey-status set <STATE>`)
Valid: READY, BUSY, FINISHED, RESERVED. Write `${RUNTIME_DIR}/status/${PANE_SAFE}.status` (PANE, UPDATED, STATUS, TASK). PANE_SAFE = pane ID with `tr ':-.' '_'`.
