---
name: doey-kill-session
description: Kill the entire Doey session — all windows, processes, and runtime files. Use when you need to "kill this session", "shut down doey", or "stop everything and clean up".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

**Expected:** 1 bash command, 1 confirmation prompt, 1 tmux kill-session, 1 rm, ~10s.

**Confirm first:** "This will kill session `${SESSION_NAME}`, all processes, and remove `${RUNTIME_DIR}`. Proceed?" Do NOT proceed without explicit yes.

## Prompt

## Step 1: Read session config
bash: RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); _sv() { grep "^$1=" "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }; SESSION_NAME=$(_sv SESSION_NAME); echo "Session: ${SESSION_NAME}, Runtime: ${RD}"
Expected: "Session: doey-<project>, Runtime: /tmp/doey/<project>" printed

**If this fails with "DOEY_RUNTIME: not set":** Not inside a Doey session. Nothing to kill.

## Step 2: Kill all processes across all windows (SIGTERM)
bash: for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do for ppid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do pid=$(pgrep -P "$ppid" 2>/dev/null) && kill "$pid" 2>/dev/null; done; done; echo "SIGTERM sent to all processes"; sleep 2
Expected: "SIGTERM sent to all processes" — graceful shutdown initiated

**If this fails with "no such process":** Process already exited — safe to continue.

## Step 3: Kill remaining processes (SIGKILL)
bash: for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do for ppid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do pid=$(pgrep -P "$ppid" 2>/dev/null) && kill -9 "$pid" 2>/dev/null; done; done; sleep 2; echo "SIGKILL sent to stragglers"
Expected: "SIGKILL sent to stragglers" — all remaining processes force-killed

**If this fails with "no such process":** Already dead — safe to continue.

## Step 4: Kill tmux session
bash: tmux kill-session -t "$SESSION_NAME"; echo "Session ${SESSION_NAME} killed"
Expected: "Session doey-<project> killed" — all tmux windows and panes destroyed

**If this fails with "can't find session":** Session already gone — continue to cleanup.

## Step 5: Remove runtime directory
bash: rm -rf "$RD"; echo "Runtime removed: ${RD}"
Expected: "Runtime removed: /tmp/doey/<project>" — all runtime files deleted

**If this fails with "No such file or directory":** Already cleaned up — nothing to do.

## Gotchas
- Do NOT proceed without explicit user confirmation — this is destructive and irreversible.
- Do NOT kill the tmux session before killing processes — this creates orphan processes.
- Do NOT use `source` on runtime env files — `/tmp` is world-writable; use safe reads only.

Total: 5 commands, 0 errors expected.

Always confirm — destructive. Kill processes before session (prevents orphans). Re-init with `doey`.
