---
name: doey-clear
description: Kill and relaunch Claude instances. Use when you need to "restart workers", "reset the team", "clear and relaunch", or "fresh start". Resets process, context, name, agent, status. Skips reserved workers unless --force.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Teams: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do echo "--- $(basename "$f") ---"; cat "$f" 2>/dev/null; done || true`

Usage: `/doey-clear` (interactive) | `all` | `team N` | `workers` (keep manager) | `all --force`. No args → prompt. Set: TARGET_WINDOWS, FORCE, WORKERS_ONLY.

### kill_pane_process (SIGTERM → 1s → SIGKILL → clear)
```bash
kill_pane_process() {
  local PANE="$1" SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true; sleep 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" Escape 2>/dev/null || true; sleep 0.1
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true; sleep 0.5
}
```

### Clear Manager (skip if WORKERS_ONLY)
```bash
kill_pane_process "${SESSION_NAME}:${W}.0"
tmux send-keys -t "${SESSION_NAME}:${W}.0" "claude --dangerously-skip-permissions --model opus --name \"T${W} Subtaskmaster\" --agent \"t${W}-manager\"" Enter; sleep 0.5
```

### Clear Workers
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"; PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
  [ "$FORCE" != "true" ] && [ -f "${RD}/status/${PANE_SAFE}.reserved" ] && { echo "  ${W}.${wp} — reserved"; continue; }
  kill_pane_process "$PANE" || { echo "  ${W}.${wp} — not found"; continue; }
  W_NAME=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null || echo "T${W} W${wp}")
  WP=$(grep -rl "pane ${W}\.${wp} " "${RD}"/worker-system-prompt-*.md 2>/dev/null | head -1 || true)
  CMD="claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\""
  [ -n "$WP" ] && CMD="${CMD} --append-system-prompt-file \"${WP}\""
  tmux send-keys -t "$PANE" "$CMD" Enter
  doey status set --pane "$PANE" --status READY --task "cleared"
  echo "  ${W}.${wp} ✓"; sleep 0.5
done
```

Skip reserved unless `--force`. Skip Subtaskmaster if WORKERS_ONLY. Never clear dashboard panes (0.0, 0.1) or Taskmaster (1.0).
