---
name: doey-list-windows
description: List all team windows with their status
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null`
- Team environments: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null`
- Tmux windows: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null`
- Pane commands: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do for p in $(tmux list-panes -t "$SESSION:$w" -F '#{pane_index}' 2>/dev/null); do CMD=$(tmux display-message -t "$SESSION:$w.$p" -p '#{pane_current_command}' 2>/dev/null); echo "$w.$p: $CMD"; done; done`
- Watchdog heartbeats: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/watchdog_W*.heartbeat; do [ -f "$f" ] && echo "$(basename $f): $(cat $f)"; done 2>/dev/null`
- Worker statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && grep -H '^STATUS: ' "$f"; done 2>/dev/null`

List all team windows. **Read-only — never modify files or processes.**

Use the injected context to build a table:

```
WINDOW  GRID    MGR     WDG         WORKERS
------  ------  ------  ----------  -------
```

For each window:
- Window 0 = Dashboard. Check if Session Manager (0.1) has a running process.
- Windows 1+ = Team windows. Extract GRID, WORKER_PANES, WATCHDOG_PANE, WORKER_COUNT from team env.
- Check worktree badge: if WORKTREE_DIR is set, show `[worktree]` with branch.
- Manager status: check if pane W.0 has a running command (not bash/zsh/sh).
- Watchdog status: check heartbeat age. >120s = STALE, otherwise OK. No heartbeat file = DOWN.
- Count BUSY workers from status files.

Format: `WINDOW GRID MGR WDG TOTAL (N busy, M idle) [worktree] branch: X`

### Rules
- **Read-only** — never modify files or processes
- Window 0 = Dashboard; graceful fallback if team env missing
