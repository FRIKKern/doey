---
name: doey-list-windows
description: List all team windows with their status. Use when you need to "show team windows", "list teams", or "what teams are running".
---

- Teams: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`
- Windows: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null|| true`
- Statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && grep -H '^STATUS: ' "$f"; done 2>/dev/null || true`

**Read-only.** Table: `WINDOW | GRID | MGR | WORKERS`. Window 0 = Dashboard; 1+ = Teams.
Badges: `[F]` if freelancer. Count BUSY. Graceful fallback. With `--all`, also show `[worktree]` for windows with `WORKTREE_DIR` set.
