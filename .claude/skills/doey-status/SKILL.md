---
name: doey-status
description: View or set pane status for Doey workers
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All statuses: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.status; do [ -f "$f" ] && echo "---" && cat "$f"; done 2>/dev/null || true`
- Reservations: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename "$f" .reserved)"; done 2>/dev/null || true`

**Default: view all statuses.** Only set status if user explicitly asks.

### Viewing

Display a summary table from the injected status data: pane, status, task, reservations.

### Setting (READY|BUSY|FINISHED|RESERVED)

Derive `RUNTIME_DIR`, `MY_PANE`, and `PANE_SAFE` from the injected context, then:

```bash
RUNTIME_DIR="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
cat > "${RUNTIME_DIR}/status/${PANE_SAFE}.status" <<EOF
PANE: $MY_PANE
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: $STATUS_TEXT
TASK: $CURRENT_TASK
EOF
```
