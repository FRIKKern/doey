# Skill: doey-repair

## Usage
`/doey-repair`

## Prompt

Diagnose and repair the Doey Dashboard (window 0). Layout:

```
┌──────────┬──────────────────────────────────────────────────┐
│  Info    │               Session Manager (0.1)              │
│  Panel   ├────────┬────────┬────────┬────────┬──────┬───────┤
│  (0.0)   │ WD 1-6 (0.2-0.7) — one Watchdog per team       │
└──────────┴────────┴────────┴────────┴────────┴──────┴───────┘
```

### Step 1: Load environment and build watchdog-team mapping

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# Build TEAM_FOR[pane_index] mapping from team env files
TEAM_FOR_02="" TEAM_FOR_03="" TEAM_FOR_04="" TEAM_FOR_05="" TEAM_FOR_06="" TEAM_FOR_07=""
for tf in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$tf" ] || continue
  WD_VAL=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2)
  WD_VAL="${WD_VAL%\"}" && WD_VAL="${WD_VAL#\"}"
  TW=$(basename "$tf" | sed 's/team_//;s/\.env//')
  case "$WD_VAL" in
    0.2) TEAM_FOR_02="$TW" ;; 0.3) TEAM_FOR_03="$TW" ;;
    0.4) TEAM_FOR_04="$TW" ;; 0.5) TEAM_FOR_05="$TW" ;;
    0.6) TEAM_FOR_06="$TW" ;; 0.7) TEAM_FOR_07="$TW" ;;
  esac
done
echo "Watchdog map: 0.2→T${TEAM_FOR_02:-?} 0.3→T${TEAM_FOR_03:-?} 0.4→T${TEAM_FOR_04:-?} 0.5→T${TEAM_FOR_05:-?} 0.6→T${TEAM_FOR_06:-?} 0.7→T${TEAM_FOR_07:-?}"
```

### Step 2: Diagnose all Dashboard panes

```bash
tmux list-panes -t "$SESSION_NAME:0" -F '#{pane_index}|#{pane_pid}|#{pane_current_command}|#{pane_title}' 2>/dev/null

for IDX in 0 1 2 3 4 5 6 7; do
  SHELL_PID=$(tmux display-message -t "$SESSION_NAME:0.${IDX}" -p '#{pane_pid}' 2>/dev/null) || { echo "0.${IDX}: MISSING"; continue; }
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""
  echo "0.${IDX}: child=${CHILD_PID:-none}"
done
```

If any pane is MISSING: report "Dashboard damaged (pane 0.X missing). Run `doey reload`." and **STOP**.

Classify each pane:
- **HEALTHY** — has child process (0.0 also needs "Doey"/"Team"/box-drawing in output)
- **IDLE** — exists but no child process
- **UNUSED** — watchdog slot (0.2-0.7) with no team assigned

Print a diagnosis table, then repair IDLE panes.

### Step 3: Repair IDLE panes

Use team mapping from Step 1 — do NOT re-scan team_*.env.

**0.0 (Info Panel):**
```bash
tmux send-keys -t "$SESSION_NAME:0.0" "clear && info-panel.sh '${RUNTIME_DIR}'" Enter
```

**0.1 (Session Manager):**
```bash
tmux send-keys -t "$SESSION_NAME:0.1" "claude --dangerously-skip-permissions --agent doey-session-manager" Enter
```

**0.2-0.7 (Watchdog slots):** Skip if `TEAM_FOR_0X` is empty (unused slot). Otherwise:
```bash
TEAM_W="$TEAM_FOR_0X"
tmux send-keys -t "$SESSION_NAME:0.X" "claude --dangerously-skip-permissions --model opus --name \"T${TEAM_W} Watchdog\" --agent \"t${TEAM_W}-watchdog\"" Enter
```
Wait 12s, then brief: `"Start monitoring session $SESSION_NAME window ${TEAM_W}. Manager is in pane ${TEAM_W}.0."`

### Step 4: Verify and report

Re-check child processes on repaired panes. If all healthy: "Dashboard is healthy — nothing to repair."

### Rules
- **NEVER kill panes/processes** — only send commands to idle shells
- **Only touch window 0** — never team windows (1+)
- Skip panes with running child processes
- Use `2>/dev/null` on error-prone tmux calls
