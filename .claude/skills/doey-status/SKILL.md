---
name: doey-status
description: View or set pane status for Doey workers. Team-wide view with `/doey-status team`. Use when you need to "check worker status", "see which panes are busy", or "set a pane to READY".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All panes: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-panes -s -t "$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All statuses: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.status; do [ -f "$f" ] && echo "---" && cat "$f"; done 2>/dev/null || true`
- Reservations: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename "$f" .reserved)"; done 2>/dev/null || true`

**Expected:** 0 tmux commands (view: data injected), 1 status file write (set mode only), ~3s.

**Default: view current window statuses.** Only set if user explicitly asks.

### Viewing (default)

Display summary table from injected data: pane, status, task, reservations. Mark current pane with `<-- you`.

### Team-wide view (`/doey-status team` or `/doey-status all`)

Show ALL panes across ALL windows. Build table: `PANE | STATUS | RESERVED | LAST_UPDATE`. For each pane: convert ID to safe name (`tr ':.' '_'`), extract STATUS (or "UNKNOWN"), check `.reserved` file, show status file age. Note any UNKNOWN panes.

### Setting (`/doey-status set <STATE>`)

Valid states: READY, BUSY, FINISHED, RESERVED. Write to `${RUNTIME_DIR}/status/${PANE_SAFE}.status` with fields: PANE, UPDATED (ISO 8601), STATUS, TASK. Derive PANE_SAFE from current pane ID (`tr ':.' '_'`).
