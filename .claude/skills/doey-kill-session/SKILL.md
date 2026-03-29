---
name: doey-kill-session
description: Kill the entire Doey session — all windows, processes, and runtime files. Use when you need to "kill this session", "shut down doey", or "stop everything and clean up".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

**Confirm first:** "This kills session `${SESSION_NAME}`, all processes, and removes `${RUNTIME_DIR}`. Proceed?"

### Execute
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION_NAME=$(grep "^SESSION_NAME=" "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
# SIGTERM → wait → SIGKILL
for sig in TERM 9; do
  for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do
    for ppid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do
      pid=$(pgrep -P "$ppid" 2>/dev/null) && kill -"$sig" "$pid" 2>/dev/null
    done
  done; sleep 2
done
tmux kill-session -t "$SESSION_NAME"
rm -rf "$RD"
echo "Session ${SESSION_NAME} killed, runtime removed"
```

### Rules
- Never proceed without explicit user confirmation
- Kill processes before session (prevents orphans)
- Re-init with `doey`
