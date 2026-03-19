---
name: doey-repair
description: Diagnose and repair Doey Dashboard (window 0).
---

!`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); cat "$RD/session.env" 2>/dev/null; for f in "$RD"/team_*.env; do [ -f "$f" ] && echo "--- $(basename "$f") ---" && cat "$f" 2>/dev/null; done || true`

Diagnose and repair Dashboard (window 0). Layout: 0.0=InfoPanel, 0.1=SessionMgr, 0.2-0.7=Watchdogs.

### Step 1: Build watchdog-team mapping

Parse WATCHDOG_PANE from each `team_*.env` to map slot 0.X -> team N (case statement for bash 3.2):

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TEAM_FOR_02="" TEAM_FOR_03="" TEAM_FOR_04="" TEAM_FOR_05="" TEAM_FOR_06="" TEAM_FOR_07=""
for tf in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$tf" ] || continue
  WD_VAL=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2); WD_VAL="${WD_VAL%\"}"; WD_VAL="${WD_VAL#\"}"
  TW=$(basename "$tf" | sed 's/team_//;s/\.env//'); SLOT=$(echo "$WD_VAL" | tr -d '.')
  case "$SLOT" in
    02) TEAM_FOR_02="$TW" ;; 03) TEAM_FOR_03="$TW" ;; 04) TEAM_FOR_04="$TW" ;;
    05) TEAM_FOR_05="$TW" ;; 06) TEAM_FOR_06="$TW" ;; 07) TEAM_FOR_07="$TW" ;;
  esac
done
```

### Step 2: Diagnose

```bash
for IDX in 0 1 2 3 4 5 6 7; do
  SHELL_PID=$(tmux display-message -t "$SESSION_NAME:0.${IDX}" -p '#{pane_pid}' 2>/dev/null) || { echo "0.${IDX}: MISSING"; continue; }
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""
  echo "0.${IDX}: child=${CHILD_PID:-none}"
done
```

If any pane MISSING -> report "Dashboard damaged. Run `doey reload`." and **STOP**.

Classify: **HEALTHY** = has child | **IDLE** = no child | **UNUSED** = watchdog slot with no team.

### Step 3: Repair IDLE panes

Send commands to idle shells only:

| Pane | Command |
|------|---------|
| 0.0 | `tmux send-keys -t "$SESSION_NAME:0.0" "clear && info-panel.sh '${RUNTIME_DIR}'" Enter` |
| 0.1 | `tmux send-keys -t "$SESSION_NAME:0.1" "claude --dangerously-skip-permissions --agent doey-session-manager" Enter` |
| 0.2-0.7 | Skip if `TEAM_FOR_0X` empty. Otherwise launch watchdog, wait 12s, brief with session/window info. |

### Step 4: Verify

Re-check child processes on repaired panes. Report results.

### Rules
- **NEVER kill panes/processes** — only send commands to idle shells
- **Only window 0** — skip panes with running child processes
