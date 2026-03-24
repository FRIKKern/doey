---
name: doey-kill-session
description: Kill the entire Doey session — all windows, processes, and runtime files. Use when you need to "kill this session", "shut down doey", or "stop everything and clean up".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

**Confirm first:** "This will kill session `${SESSION_NAME}`, all processes, and remove `${RUNTIME_DIR}`. Proceed?"

## Step 1: Read session config
bash: RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); _sv() { grep "^$1=" "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }; SESSION_NAME=$(_sv SESSION_NAME); echo "Session: ${SESSION_NAME}, Runtime: ${RD}"

## Step 2: SIGTERM all processes
bash: for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do for ppid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do pid=$(pgrep -P "$ppid" 2>/dev/null) && kill "$pid" 2>/dev/null; done; done; echo "SIGTERM sent"; sleep 2

## Step 3: SIGKILL stragglers
bash: for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do for ppid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do pid=$(pgrep -P "$ppid" 2>/dev/null) && kill -9 "$pid" 2>/dev/null; done; done; sleep 2

## Step 4: Kill tmux session
bash: tmux kill-session -t "$SESSION_NAME"; echo "Session ${SESSION_NAME} killed"

## Step 5: Remove runtime
bash: rm -rf "$RD"; echo "Runtime removed: ${RD}"

### Rules
- Never proceed without explicit user confirmation
- Kill processes before session (prevents orphans)
- Don't `source` runtime env files — use safe reads only
- Re-init with `doey`
