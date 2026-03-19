---
name: doey-kill-session
description: Kill the entire Doey session — all windows, processes, and runtime files.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null`

**Confirm first:** "This will kill session `${SESSION_NAME}`, all processes, and remove `${RUNTIME_DIR}`. Proceed?"
Do NOT proceed without explicit yes.

### Kill processes, then session

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

kill_children() {
  local sig="${1:-TERM}"
  for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do
    for ppid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do
      pid=$(pgrep -P "$ppid" 2>/dev/null) && kill -"$sig" "$pid" 2>/dev/null
    done
  done
}

kill_children TERM; echo "Sent SIGTERM"; sleep 2
kill_children 9;    echo "Sent SIGKILL to stragglers"; sleep 1

tmux kill-session -t "$SESSION_NAME"
rm -rf "$RUNTIME_DIR"
echo "Session ${SESSION_NAME} killed, runtime removed: ${RUNTIME_DIR}"
```

### Rules
- **Always confirm** — destructive and irreversible
- Kill processes before session (prevents orphans)
- Re-initialize with `doey`
