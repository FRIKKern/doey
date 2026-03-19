# Skill: doey-clear

Kill and relaunch Claude instances in a team. Resets process, context, name, agent, and status. Skips reserved workers unless `--force`.

## Usage
`/doey-clear` — interactive: asks what to clear
`/doey-clear all` — all teams (managers + watchdogs + workers)
`/doey-clear team N` — everything in team N
`/doey-clear workers` — workers only in current team
`/doey-clear all --force` — include reserved workers

## Prompt

You are resetting teams in a Doey tmux session — kill, clear terminal, relaunch fresh.

### Step 0: Interactive prompt (no arguments)

If no arguments, load context and ask what to clear based on caller role:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
```

- **Window Manager (WINDOW_INDEX > 0):** Suggest "this team", also offer "all teams" or "workers only"
- **Session Manager (WINDOW_INDEX = 0):** Suggest "all teams", also offer specific team

Wait for response. If arguments were provided, skip to Step 1.

### Step 1: Parse arguments and load context

Parse from args or interactive response:
- `all` → all team windows from `$TEAM_WINDOWS`
- `team N` → team window N
- `workers` → workers only (skip manager/watchdog)
- `--force` → include reserved workers

Build TARGET_WINDOWS, FORCE, and WORKERS_ONLY flags.

### Step 2: Validate targets

```bash
for W in $TARGET_WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ ! -f "$TEAM_ENV" ] && echo "WARNING: Team $W env not found — skipping" && continue
  WP=$(grep '^WORKER_PANES=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  WD=$(grep '^WATCHDOG_PANE=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  echo "Team $W: mgr=0, watchdog=${WD}, workers=${WP}"
done
```

### Step 3: Kill helper

```bash
kill_pane_process() {
  local PANE="$1" SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  if [ -n "$CHILD_PID" ]; then
    kill "$CHILD_PID" 2>/dev/null || true; sleep 1
    CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
    [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  fi
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true
  sleep 0.5
}
```

### Step 4: Clear each target team

For each W in TARGET_WINDOWS. If WORKERS_ONLY, skip 4a and 4b.

#### 4a. Window Manager (W.0)

```bash
MGR_PANE="${SESSION_NAME}:${W}.0"
kill_pane_process "$MGR_PANE"
tmux send-keys -t "$MGR_PANE" "claude --dangerously-skip-permissions --name \"T${W} Window Manager\" --agent \"t${W}-manager\"" Enter
sleep 0.5
```

#### 4b. Watchdog (in Dashboard)

**CRITICAL**: After relaunch, send briefing + scan loop or Watchdog sits idle.

```bash
WATCHDOG_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/team_${W}.env" | cut -d= -f2 | tr -d '"')
WDG_PANE="${SESSION_NAME}:${WATCHDOG_PANE}"
kill_pane_process "$WDG_PANE"
tmux send-keys -t "$WDG_PANE" "claude --dangerously-skip-permissions --model opus --name \"T${W} Watchdog\" --agent \"t${W}-watchdog\"" Enter
sleep 0.5
```

After all panes relaunched, background-send briefing + scan loop:

```bash
WP_LIST=$(echo "$WORKER_PANES" | tr ',' ' ' | sed "s/[0-9]*/${W}.&/g" | tr ' ' ',')
(
  sleep 15
  tmux send-keys -t "$WDG_PANE" \
    "Start monitoring session ${SESSION_NAME} window ${W}. Skip pane ${WATCHDOG_PANE} (yourself). Manager=${W}.0. Monitor panes ${WP_LIST}." Enter
  sleep 20
  tmux send-keys -t "$WDG_PANE" \
    '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
) &
```

#### 4c. Workers (W.1+)

```bash
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"
  PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

  # Skip reserved unless --force
  if [ "$FORCE" != "true" ] && [ -f "$STATUS_FILE" ] && grep -q "STATUS: RESERVED" "$STATUS_FILE"; then
    echo "  ${W}.${wp} — reserved, skipping"; continue
  fi
  kill_pane_process "$PANE" || { echo "  ${W}.${wp} — not found"; continue; }

  W_NAME=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null || echo "T${W} W${wp}")
  WORKER_PROMPT=$(grep -rl "pane ${W}\.${wp} " "${RUNTIME_DIR}"/worker-system-prompt-*.md 2>/dev/null | head -1 || true)

  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\" --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\"" Enter
  fi

  mkdir -p "${RUNTIME_DIR}/status"
  cat > "$STATUS_FILE" << EOF
PANE: ${PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: READY
TASK: cleared
EOF
  sleep 0.5
done
```

### Step 5: Report

Print summary per team (manager/watchdog/workers cleared, reserved skipped).

### Rules
- Clear order: Manager → Watchdog → Workers
- Never clear Session Manager (0.1) or Info Panel (0.0)
- Skip reserved unless `--force`; kill by PID only (SIGTERM→SIGKILL)
- Manager: `--agent "t${W}-manager"`, Watchdog: `--agent "t${W}-watchdog"`, Workers: `--append-system-prompt-file`
- If caller IS the Window Manager being cleared, warn it will kill own process, then proceed
- `sleep 0.5` between panes; all bash 3.2 compatible
