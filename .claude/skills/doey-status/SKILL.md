---
name: doey-status
description: View or set pane status for Doey workers. Team-wide view with `/doey-status team`.
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All panes: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-panes -s -t "$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- All statuses: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.status; do [ -f "$f" ] && echo "---" && cat "$f"; done 2>/dev/null || true`
- Reservations: !`SD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status"; for f in "$SD"/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename "$f" .reserved)"; done 2>/dev/null || true`

**Default: view current window statuses.** Only set status if user explicitly asks.

## Step 1: View Current Window Statuses (Default)

Display a summary table from the injected context data above: `PANE | STATUS | TASK | RESERVED`.

For each pane in the current window:
- Read status from the `.status` file
- Get task name from status file TASK field
- Check for `.reserved` flag
- Mark the current pane with `<-- you`

Expected: A formatted table showing all panes in the current window with their state. Current pane is highlighted.

## Step 2: Team-Wide View (`/doey-status team` or `/doey-status all`)

Show ALL panes across ALL windows. Build a table: `PANE | STATUS | RESERVED | LAST_UPDATE`.

For each pane from the "All panes" context data:
bash: # For each PANE_ID, derive safe name and read status:
PANE_SAFE=$(echo "$PANE_ID" | tr ':.' '_')
STATUS=$(grep '^STATUS=' "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null | cut -d= -f2- || echo "UNKNOWN")
RESERVED=$([ -f "${DOEY_RUNTIME}/status/${PANE_SAFE}.reserved" ] && echo "YES" || echo "")
UPDATED=$(stat -f '%Sm' -t '%H:%M:%S' "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null || echo "?")
Expected: A table covering every pane in every window. Any panes without status files show as UNKNOWN.

**If this fails with "UNKNOWN" for many panes:** Workers may not have started yet or the runtime directory is stale. Verify `${DOEY_RUNTIME}/status/` contains `.status` files.

## Step 3: Set Status (`/doey-status set <STATE>`)

Valid states: READY, BUSY, FINISHED, RESERVED.

bash: PANE_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'); PANE_SAFE=$(echo "$PANE_ID" | tr ':.' '_'); cat > "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" <<EOF
PANE=$PANE_ID
UPDATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
STATUS=<STATE>
TASK=<description>
EOF
Expected: Status file written at `${DOEY_RUNTIME}/status/${PANE_SAFE}.status` with the specified state.

**If this fails with "No such file or directory":** The status directory doesn't exist. Create it first: `mkdir -p "${DOEY_RUNTIME}/status"`.

**If this fails with "Permission denied":** Check that `${DOEY_RUNTIME}` is writable.

## Gotchas

- Do NOT set status unless the user explicitly asks — default is view mode
- Do NOT use any state value other than READY, BUSY, FINISHED, or RESERVED
- Do NOT derive status by reading pane output — always use `.status` files
- Do NOT forget to use `tr ':.' '_'` when converting pane IDs to safe filenames

Total: 3 commands, 0 errors expected.
