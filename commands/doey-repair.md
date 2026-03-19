# Skill: doey-repair

## Usage
`/doey-repair`

## Prompt

You are diagnosing and repairing the Doey Dashboard (tmux window 0). The Dashboard has this layout:

```
┌──────────┬──────────────────────────────────────────────────┐
│          │               Session Manager (0.1)              │
│  Info    ├────────┬────────┬────────┬────────┬──────┬───────┤
│  Panel   │ WD 1   │ WD 2   │ WD 3   │ WD 4   │ WD 5 │ WD 6 │
│  (0.0)   │ (0.2)  │ (0.3)  │ (0.4)  │ (0.5)  │ (0.6)│ (0.7)│
└──────────┴────────┴────────┴────────┴────────┴──────┴───────┘
```

### Step 1: Load environment and build watchdog-team mapping

Run a single Bash call to load all context:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# Build watchdog slot → team mapping (once, reused in diagnosis and repair)
TEAM_FOR_02="" TEAM_FOR_03="" TEAM_FOR_04="" TEAM_FOR_05=""
for tf in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$tf" ] || continue
  WD_VAL=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2)
  WD_VAL="${WD_VAL%\"}" && WD_VAL="${WD_VAL#\"}"
  TW=$(basename "$tf" | sed 's/team_//;s/\.env//')
  case "$WD_VAL" in
    0.2) TEAM_FOR_02="$TW" ;;
    0.3) TEAM_FOR_03="$TW" ;;
    0.4) TEAM_FOR_04="$TW" ;;
    0.5) TEAM_FOR_05="$TW" ;;
    0.6) TEAM_FOR_06="$TW" ;;
    0.7) TEAM_FOR_07="$TW" ;;
  esac
done
echo "Watchdog mapping: 0.2→T${TEAM_FOR_02:-none} 0.3→T${TEAM_FOR_03:-none} 0.4→T${TEAM_FOR_04:-none} 0.5→T${TEAM_FOR_05:-none} 0.6→T${TEAM_FOR_06:-none} 0.7→T${TEAM_FOR_07:-none}"
```

### Step 2: Diagnose all Dashboard panes

```bash
# Get all pane info in one call
tmux list-panes -t "$SESSION_NAME:0" -F '#{pane_index}|#{pane_pid}|#{pane_current_command}|#{pane_title}' 2>/dev/null

# For each pane, check if a child process is running
for IDX in 0 1 2 3 4 5 6 7; do
  SHELL_PID=$(tmux display-message -t "$SESSION_NAME:0.${IDX}" -p '#{pane_pid}' 2>/dev/null) || { echo "0.${IDX}: MISSING"; continue; }
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""
  echo "0.${IDX}: child=${CHILD_PID:-none}"
done
```

If any pane is MISSING (not returned by `list-panes`), report: "Dashboard structure is damaged (pane 0.X missing). Run `doey reload` to rebuild." and **STOP** — do not attempt repairs.

Build a table classifying each pane as:
- **HEALTHY** — expected process is running (has a child process)
- **IDLE** — pane exists but nothing running (no child process)
- **UNUSED** — watchdog slot with no team assigned

For determining health:
- **0.0 (Info Panel):** HEALTHY if `pane_current_command` contains `bash` AND the pane title or capture output contains "Doey" or "Team" or box-drawing chars. IDLE if just a shell prompt.
- **0.1 (Session Manager):** HEALTHY if there's a child process. IDLE if no child.
- **0.2-0.7 (Watchdog slots):** HEALTHY if there's a child process. Use the mapping from Step 1 (`TEAM_FOR_02`/`03`/`04`/`05`/`06`/`07`) to show which team it belongs to. A slot with no team assigned is UNUSED (not broken).

Print a summary table like:
```
Dashboard Diagnosis:
  0.0  Info Panel        HEALTHY
  0.1  Session Manager   IDLE ← needs repair
  0.2  T1 Watchdog       HEALTHY
  0.3  T2 Watchdog       HEALTHY
  0.4  Watchdog slot     UNUSED
```

### Step 3: Repair broken panes

For each IDLE pane, repair it based on its role. Use the team mapping from Step 1 — do NOT re-scan team_*.env files.

**Info Panel (0.0):**
```bash
tmux send-keys -t "$SESSION_NAME:0.0" "clear && info-panel.sh '${RUNTIME_DIR}'" Enter
```
Wait 3s, verify it started.

**Session Manager (0.1):**
```bash
tmux send-keys -t "$SESSION_NAME:0.1" "claude --dangerously-skip-permissions --agent doey-session-manager" Enter
```
Wait 8s, verify Claude started.

**Watchdog slot (0.2-0.7):** Only repair if the slot is assigned to a team. Use the `TEAM_FOR_0X` variable from Step 1. If empty, skip — it's an unused slot.

If team found, respawn:
```bash
TEAM_W="$TEAM_FOR_0X"  # from Step 1 mapping
WDG_AGENT_NAME="t${TEAM_W}-watchdog"
tmux send-keys -t "$SESSION_NAME:0.X" "claude --dangerously-skip-permissions --model opus --name \"T${TEAM_W} Watchdog\" --agent \"${WDG_AGENT_NAME}\"" Enter
```
Wait 12s, then brief it:
```bash
tmux send-keys -t "$SESSION_NAME:0.X" "Start monitoring session $SESSION_NAME window ${TEAM_W}. Manager is in team window pane ${TEAM_W}.0. Monitor worker panes." Enter
```

### Step 4: Verify repairs

After all repairs, re-check child processes on any pane that was repaired. Report final status.

### Safety rules

- **NEVER kill panes or processes** — only send commands to idle shells
- **NEVER touch team windows (1+)** — only Dashboard (window 0)
- If a pane already has a child process running, skip it — it's healthy or being used
- All tmux commands should use `2>/dev/null` on error-prone calls
- If ALL panes are healthy, just say "Dashboard is healthy — nothing to repair"
