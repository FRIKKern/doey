# Skill: doey-repair

## Usage
`/doey-repair`

## Prompt

You are diagnosing and repairing the Doey Dashboard (tmux window 0). The Dashboard has this layout:

```
┌──────────┬──────────────────────────┐
│          │    Session Manager (0.1) │
│  Info    ├────────┬────────┬────────┤
│  Panel   │ WD 1   │ WD 2   │ WD 3   │
│  (0.0)   │ (0.2)  │ (0.3)  │ (0.4)  │
└──────────┴────────┴────────┴────────┘
```

### Step 1: Load environment

Every Bash call must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This gives you `SESSION_NAME`, `PROJECT_DIR`, `SM_PANE` (default "0.1"), `WDG_SLOT_1`/`WDG_SLOT_2`/`WDG_SLOT_3`.

### Step 2: Diagnose all Dashboard panes

Check each pane in window 0 (panes 0.0 through 0.4). For each pane, run:

```bash
PANE_TARGET="$SESSION_NAME:0.X"  # replace X with pane index

# Does pane exist?
SHELL_PID=$(tmux display-message -t "$PANE_TARGET" -p '#{pane_pid}' 2>/dev/null) || { echo "PANE 0.X: MISSING"; continue; }

# What's running?
PANE_CMD=$(tmux display-message -t "$PANE_TARGET" -p '#{pane_current_command}' 2>/dev/null) || PANE_CMD="unknown"
PANE_TITLE=$(tmux display-message -t "$PANE_TARGET" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="unknown"

# Is something running inside the shell?
CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null) || CHILD_PID=""

echo "PANE 0.X: pid=$SHELL_PID cmd=$PANE_CMD title=$PANE_TITLE child=$CHILD_PID"
```

Build a table classifying each pane as:
- **HEALTHY** — expected process is running
- **IDLE** — pane exists but nothing running (shell prompt visible, no child process)
- **WRONG** — pane exists but unexpected process
- **MISSING** — pane doesn't exist

For determining health:
- **0.0 (Info Panel):** HEALTHY if `pane_current_command` contains `bash` AND capture-pane output contains "Doey" or "Team" or box-drawing chars. IDLE if just a shell prompt.
- **0.1 (Session Manager):** HEALTHY if there's a child process. IDLE if no child.
- **0.2-0.4 (Watchdog slots):** HEALTHY if there's a child process. To find which team a slot belongs to, check team_*.env files:
  ```bash
  for tf in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$tf" ] || continue
    WD_VAL=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2)
    WD_VAL="${WD_VAL%\"}" && WD_VAL="${WD_VAL#\"}"
    if [ "$WD_VAL" = "0.X" ]; then
      TEAM_W=$(basename "$tf" | sed 's/team_//;s/\.env//')
      echo "  Assigned to Team $TEAM_W"
    fi
  done
  ```
  A watchdog slot with no matching team_*.env is UNUSED (not broken).

Print a summary table like:
```
Dashboard Diagnosis:
  0.0  Info Panel        HEALTHY
  0.1  Session Manager   IDLE ← needs repair
  0.2  T1 Watchdog       HEALTHY
  0.3  T2 Watchdog       HEALTHY
  0.4  Watchdog slot     UNUSED
```

**CRITICAL:** If any pane is MISSING (not just idle), report: "Dashboard structure is damaged (pane 0.X missing). Run `doey reload` to rebuild." and STOP — do not attempt repairs.

### Step 3: Repair broken panes

For each IDLE pane, repair it based on its role:

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

**Watchdog slot (0.2-0.4):** Only repair if the slot is assigned to a team (has a matching team_*.env). Find the team number first:
```bash
TEAM_W=""
for tf in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$tf" ] || continue
  WD_VAL=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2)
  WD_VAL="${WD_VAL%\"}" && WD_VAL="${WD_VAL#\"}"
  if [ "$WD_VAL" = "0.X" ]; then
    TEAM_W=$(basename "$tf" | sed 's/team_//;s/\.env//')
    break
  fi
done
```
If no team found, skip — it's an unused slot.

If team found, respawn:
```bash
WDG_AGENT_NAME="t${TEAM_W}-watchdog"
tmux send-keys -t "$SESSION_NAME:0.X" "claude --dangerously-skip-permissions --model haiku --name \"T${TEAM_W} Watchdog\" --agent \"${WDG_AGENT_NAME}\"" Enter
```
Wait 12s, then brief it:
```bash
tmux send-keys -t "$SESSION_NAME:0.X" "Start monitoring session $SESSION_NAME window ${TEAM_W}. Manager is in team window pane ${TEAM_W}.0. Monitor worker panes." Enter
```

### Step 4: Verify repairs

After all repairs, re-run the diagnosis check from Step 2 on any pane that was repaired. Report final status.

### Safety rules

- **NEVER kill panes or processes** — only send commands to idle shells
- **NEVER touch team windows (1+)** — only Dashboard (window 0)
- If a pane already has a child process running, skip it — it's healthy or being used
- All tmux commands should use `2>/dev/null` on error-prone calls
- If ALL panes are healthy, just say "Dashboard is healthy — nothing to repair"
