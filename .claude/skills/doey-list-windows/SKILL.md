---
name: doey-list-windows
description: List all team windows with their status. Use when you need to "show team windows", "list teams", or "what teams are running".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team environments: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`
- Tmux windows: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null|| true`
- Pane commands: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do for p in $(tmux list-panes -t "$SESSION:$w" -F '#{pane_index}' 2>/dev/null); do CMD=$(tmux display-message -t "$SESSION:$w.$p" -p '#{pane_current_command}' 2>/dev/null); echo "$w.$p: $CMD"; done; done || true`
- Worker statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && grep -H '^STATUS: ' "$f"; done 2>/dev/null || true`

**Read-only.** Build table: `WINDOW | GRID | MGR | WORKERS`.

- Window 0 = Dashboard (Boss 0.1, Session Manager 0.2). Windows 1+ = Teams.
- Extract GRID, WORKER_PANES, WORKER_COUNT, TEAM_TYPE from team env.
- Badges: `[worktree]` + branch if WORKTREE_DIR set. `[F]` if TEAM_TYPE=freelancer (no Manager).
- Manager: running command (not bash/zsh/sh) = OK; freelancer = "N/A".
- Count BUSY workers. Graceful fallback if team env missing.
