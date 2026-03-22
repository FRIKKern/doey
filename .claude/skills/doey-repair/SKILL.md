---
name: doey-repair
description: Diagnose and repair Doey Dashboard (window 0).
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team files: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do echo "--- $(basename "$f") ---"; cat "$f" 2>/dev/null; done || true`

Diagnose and repair Dashboard (window 0). Layout: 0.0=InfoPanel, 0.1=SessionMgr, 0.2-0.7=Watchdogs (one per team).

## Step 1: Build watchdog-team mapping
bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && TEAM_FOR_02="" TEAM_FOR_03="" TEAM_FOR_04="" TEAM_FOR_05="" TEAM_FOR_06="" TEAM_FOR_07="" && for tf in "${RUNTIME_DIR}"/team_*.env; do [ -f "$tf" ] || continue; WD_VAL=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2); WD_VAL="${WD_VAL%\"}"; WD_VAL="${WD_VAL#\"}"; TW=$(basename "$tf" | sed 's/team_//;s/\.env//'); SLOT=$(echo "$WD_VAL" | tr -d '.'); case "$SLOT" in 02) TEAM_FOR_02="$TW" ;; 03) TEAM_FOR_03="$TW" ;; 04) TEAM_FOR_04="$TW" ;; 05) TEAM_FOR_05="$TW" ;; 06) TEAM_FOR_06="$TW" ;; 07) TEAM_FOR_07="$TW" ;; esac; done && echo "Map: 0.2→T${TEAM_FOR_02:-?} 0.3→T${TEAM_FOR_03:-?} 0.4→T${TEAM_FOR_04:-?} 0.5→T${TEAM_FOR_05:-?} 0.6→T${TEAM_FOR_06:-?} 0.7→T${TEAM_FOR_07:-?}"
Expected: Prints mapping like `Map: 0.2→T1 0.3→T2 0.4→T3 0.5→? 0.6→? 0.7→?`

**If this fails with "No such file or directory":** No team env files exist. Check that teams are running with `doey status`.

## Step 2: Diagnose pane health
bash: for IDX in 0 1 2 3 4 5 6 7; do SHELL_PID=$(tmux display-message -t "$SESSION_NAME:0.${IDX}" -p '#{pane_pid}' 2>/dev/null) || { echo "0.${IDX}: MISSING"; continue; }; CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""; echo "0.${IDX}: child=${CHILD_PID:-none}"; done
Expected: Each pane reports its child process status. HEALTHY = has child process, IDLE = no child, UNUSED = watchdog slot with no team assigned.

**If this fails with "MISSING" for any pane:** Dashboard is damaged. Run `doey reload` and **STOP** — do not continue to Step 3.

## Step 3: Repair IDLE panes
Use the team mapping from Step 1. Send commands to idle shells only. Classify and repair each pane:

For pane 0.0 (InfoPanel) if IDLE:
bash: tmux send-keys -t "$SESSION_NAME:0.0" "clear && info-panel.sh '${RUNTIME_DIR}'" Enter
Expected: Info panel restarts and shows live dashboard.

For pane 0.1 (Session Manager) if IDLE:
bash: tmux send-keys -t "$SESSION_NAME:0.1" "claude --dangerously-skip-permissions --agent doey-session-manager" Enter
Expected: Session Manager Claude instance starts.

For panes 0.2-0.7 (Watchdogs) if IDLE and team assigned:
Skip if `TEAM_FOR_0X` is empty (UNUSED slot). Otherwise:
bash: tmux send-keys -t "$SESSION_NAME:0.X" "claude --dangerously-skip-permissions --model opus --name \"T${TEAM_W} Watchdog\" --agent \"t${TEAM_W}-watchdog\"" Enter
Expected: Watchdog Claude instance starts. Wait 12s, then brief with session/window info.

**If this fails with "no server running":** tmux session is gone. Run `doey` to start a fresh session.

## Step 4: Verify repairs
bash: for IDX in 0 1 2 3 4 5 6 7; do SHELL_PID=$(tmux display-message -t "$SESSION_NAME:0.${IDX}" -p '#{pane_pid}' 2>/dev/null) || { echo "0.${IDX}: MISSING"; continue; }; CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""; echo "0.${IDX}: child=${CHILD_PID:-none}"; done
Expected: Previously IDLE panes now show child processes. Report results.

**If this fails with panes still showing "none":** Wait 5s and retry — Claude instances take a moment to start.

## Gotchas
- Do NOT kill panes or processes — only send commands to idle shells
- Do NOT touch panes with running child processes — only repair IDLE ones
- Do NOT repair panes outside window 0
- Use case statement for bash 3.2 compatibility (no `declare -A`)

Total: 5 commands, 0 errors expected.

### Rules
- **NEVER kill panes/processes** — only send commands to idle shells
- **Only window 0** — skip panes with running child processes
