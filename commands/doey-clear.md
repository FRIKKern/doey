# Skill: doey-clear

Kill and relaunch all Claude instances in a team. Resets process, context, name, agent, and status. Skips reserved workers unless `--force`.

## Usage
`/doey-clear` — interactive (asks what to clear)
`/doey-clear all` — all teams
`/doey-clear team N` — specific team
`/doey-clear workers` — workers only (keep manager + watchdog)
`/doey-clear all --force` — include reserved workers

## Prompt

Reset teams in a Doey tmux session: kill each Claude process, clear terminal, relaunch with correct names/agents/prompts.

### Step 0: Load context (always)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
```

### Step 1: Interactive prompt (no arguments only)

If no arguments, ask what to clear. If arguments were provided, skip to Step 2.

**From a Window Manager (WINDOW_INDEX > 0):**
> What would you like to clear?
> 1. **This team** (Team {W}) — manager, watchdog, and all workers ← suggested
> 2. **All teams** — clear everything across all {N} teams
> 3. **Workers only** (Team {W}) — just the workers, keep manager and watchdog

**From the Session Manager (WINDOW_INDEX = 0):**
> What would you like to clear? You have {N} teams ({TEAM_WINDOWS}).
> 1. **All teams** — clear everything across all {N} teams ← suggested
> 2. **A specific team** — e.g., Team 1, Team 2, etc.

Wait for response. Accept "1", "this team", "all", "team 2", etc.

### Step 2: Parse arguments

From command args or interactive response, build:
- **TARGET_WINDOWS**: `all` → `$TEAM_WINDOWS`; `team N` → window N; `workers` → current team
- **FORCE**: `--force` anywhere in args
- **WORKERS_ONLY**: `workers` target

### Step 3: Validate targets

```bash
for W in $TARGET_WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ ! -f "$TEAM_ENV" ] && echo "WARNING: Team $W env not found — skipping" && continue
  WP=$(grep '^WORKER_PANES=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  WC=$(grep '^WORKER_COUNT=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  WD=$(grep '^WATCHDOG_PANE=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  echo "Team $W: manager=pane 0, watchdog=${WD}, workers=${WP} (${WC} workers)"
done
```

### Step 4: Helper — kill pane process

SIGTERM → wait → SIGKILL if needed → clear terminal. Returns 1 if pane not found.

```bash
kill_pane_process() {
  local PANE="$1" SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true
  sleep 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true
  sleep 0.5
}
```

### Step 5: Clear each target team

For each team window W. **If WORKERS_ONLY, skip 5a and 5b.**

#### 5a. Clear Window Manager (pane W.0)

```bash
MGR_PANE="${SESSION_NAME}:${W}.0"
echo "  ${W}.0 Window Manager..."
kill_pane_process "$MGR_PANE"
tmux send-keys -t "$MGR_PANE" "claude --dangerously-skip-permissions --name \"T${W} Window Manager\" --agent \"t${W}-manager\"" Enter
echo "  ${W}.0 Window Manager ✓"; sleep 0.5
```

#### 5b. Clear Watchdog (in Dashboard window 0)

**CRITICAL**: After relaunch, you MUST send briefing + scan loop or the Watchdog sits idle.

```bash
WATCHDOG_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/team_${W}.env" | cut -d= -f2 | tr -d '"')
WDG_PANE="${SESSION_NAME}:${WATCHDOG_PANE}"
echo "  ${WATCHDOG_PANE} Watchdog..."
kill_pane_process "$WDG_PANE"
tmux send-keys -t "$WDG_PANE" "claude --dangerously-skip-permissions --model opus --name \"T${W} Watchdog\" --agent \"t${W}-watchdog\"" Enter
echo "  ${WATCHDOG_PANE} Watchdog ✓"; sleep 0.5
```

**After all panes relaunched**, send briefing + scan loop in background:

```bash
WP_LIST=$(echo "$WORKER_PANES" | tr ',' ' ' | sed "s/[0-9]*/${W}.&/g" | tr ' ' ',')
(
  sleep 15
  tmux send-keys -t "$WDG_PANE" \
    "Start monitoring session ${SESSION_NAME} window ${W}. Skip pane ${WATCHDOG_PANE} (yourself, in Dashboard). Manager is in team window pane ${W}.0. Monitor panes ${WP_LIST}." Enter
  sleep 20
  tmux send-keys -t "$WDG_PANE" \
    '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
) &
echo "  ${WATCHDOG_PANE} Watchdog briefing scheduled (~35s)"
```

#### 5c. Clear Workers (panes W.1+)

```bash
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"
  PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

  # Skip reserved unless --force
  if [ "$FORCE" != "true" ] && [ -f "$STATUS_FILE" ] && grep -q "STATUS: RESERVED" "$STATUS_FILE"; then
    echo "  ${W}.${wp} — reserved, skipping (use --force)"; continue
  fi

  # Skip missing panes
  kill_pane_process "$PANE" || { echo "  ${W}.${wp} — not found, skipping"; continue; }

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
  echo "  ${W}.${wp} ✓"; sleep 0.5
done
```

### Step 6: Report results

```
Clear complete:
  Team 1: Manager ✓, Watchdog ✓, 6 workers cleared ✓
  Team 2: Manager ✓, Watchdog ✓, 5 workers cleared, 1 reserved (skipped) ✓
```

### Rules
- Clear order: Manager → Watchdog → Workers
- Never clear Session Manager (0.1) or Info Panel (0.0)
- If caller IS a Window Manager being cleared: warn, then proceed (relaunch handles it)
- Skip reserved workers unless `--force`
- Kill by PID (SIGTERM → SIGKILL), never via send-keys
- Clear terminal before relaunching
- Agents: `t${W}-manager`, `t${W}-watchdog`; workers use `--append-system-prompt-file`
- `sleep 0.5` between panes; bash 3.2 compatible
