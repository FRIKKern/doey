---
name: doey-repair
description: Diagnose and repair Doey Dashboard (window 0). Use when you need to "fix the dashboard", "repair window 0", or "dashboard panes are broken".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team files: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do echo "--- $(basename "$f") ---"; cat "$f" 2>/dev/null; done || true`

Diagnose and repair Dashboard (window 0). Layout: 0.0=InfoPanel, 0.1=Boss, 0.2=SessionManager.

### Step 1: Diagnose

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
for IDX in 0 1 2; do
  SHELL_PID=$(tmux display-message -t "$SESSION_NAME:0.${IDX}" -p '#{pane_pid}' 2>/dev/null) || { echo "0.${IDX}: MISSING"; continue; }
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""
  echo "0.${IDX}: child=${CHILD_PID:-none}"
done
```

If any pane MISSING → report "Dashboard damaged. Run `doey reload`." and **STOP**.

Classify: **HEALTHY** (has child) | **IDLE** (no child). Repair IDLE panes only.

### Step 2: Repair IDLE panes

Send commands to idle shells only:

| Pane | Role | Command |
|------|------|---------|
| 0.0 | Info Panel | `tmux send-keys -t "$SESSION_NAME:0.0" "clear && info-panel.sh '${RUNTIME_DIR}'" Enter` |
| 0.1 | Boss | `tmux send-keys -t "$SESSION_NAME:0.1" "claude --dangerously-skip-permissions --agent doey-boss" Enter` |
| 0.2 | Session Manager | `tmux send-keys -t "$SESSION_NAME:0.2" "claude --dangerously-skip-permissions --agent doey-session-manager" Enter` |

### Step 3: Verify — re-check child processes, report results.

### Rules
- **NEVER kill panes/processes** — only send commands to idle shells
- **Only window 0** — skip panes with running child processes
