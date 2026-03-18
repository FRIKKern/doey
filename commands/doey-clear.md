# Skill: doey-clear

Kill and relaunch all Claude instances in a team: Window Manager, Watchdog, and all Workers. Fully resets process, context, name, agent definition, and status. Respects reserved workers (skips them unless `--force` is used).

## Usage
`/doey-clear` — interactive: asks what to clear with smart suggestions
`/doey-clear all` — clear all teams (managers + watchdogs + workers)
`/doey-clear team 1` — clear everything in team 1
`/doey-clear team 2` — clear everything in team 2
`/doey-clear workers` — clear only workers in current team (keep manager + watchdog)
`/doey-clear all --force` — clear everything including reserved workers

## Prompt

You are fully resetting teams in a Doey tmux session. This kills each Claude process (Manager, Watchdog, Workers), clears the terminal, and relaunches fresh instances with the correct names, agents, and system prompts.

### Step 0: Interactive prompt (when no arguments given)

If the user ran `/doey-clear` with **no arguments**, do NOT silently pick a default. Instead, **ask what they want to clear** with a context-aware suggestion:

First, load context to determine who you are:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
```

Then present options based on the caller's role:

**If called from a Window Manager (team window, WINDOW_INDEX > 0):**
> What would you like to clear?
> 1. **This team** (Team {W}) — manager, watchdog, and all workers ← suggested
> 2. **All teams** — clear everything across all {N} teams
> 3. **Workers only** (Team {W}) — just the workers, keep manager and watchdog
>
> Or specify: `/doey-clear team 2`, `/doey-clear all`, `/doey-clear all --force`

**If called from the Session Manager (Dashboard, WINDOW_INDEX = 0):**
> What would you like to clear? You have {N} teams ({TEAM_WINDOWS}).
> 1. **All teams** — clear everything across all {N} teams ← suggested
> 2. **A specific team** — e.g., Team 1, Team 2, etc.
>
> Or specify: `/doey-clear all`, `/doey-clear team 1`, `/doey-clear all --force`

Wait for the user's response before proceeding. Accept answers like "1", "this team", "all", "team 2", etc.

**If arguments WERE provided** (e.g., `all`, `team 1`, `team 2 --force`), skip this step and proceed directly.

### Step 1: Parse arguments and load context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
```

Parse the arguments (from command args or interactive response):
- `all` → target ALL team windows (from `$TEAM_WINDOWS`)
- `team N` → target team window N only
- `workers` or `workers only` → only clear workers (skip manager and watchdog)
- `--force` flag (can appear anywhere in args) → also clear reserved workers

Build a list of target team windows, a FORCE flag, and a WORKERS_ONLY flag based on arguments.

### Step 2: Validate targets

For each target team window, load its env file and verify it exists:

```bash
for W in $TARGET_WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  if [ ! -f "$TEAM_ENV" ]; then
    echo "WARNING: Team $W env not found — skipping"
    continue
  fi
  WP=$(grep '^WORKER_PANES=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  WC=$(grep '^WORKER_COUNT=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  WD=$(grep '^WATCHDOG_PANE=' "$TEAM_ENV" | cut -d= -f2 | tr -d '"')
  echo "Team $W: manager=pane 0, watchdog=${WD}, workers=${WP} (${WC} workers)"
done
```

### Step 3: Helper — kill and relaunch a pane

Use this pattern for each pane (Manager, Watchdog, or Worker):

```bash
# Kill process in a pane. Args: PANE_REF
kill_pane_process() {
  local PANE="$1"
  local SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  if [ -n "$CHILD_PID" ]; then
    kill "$CHILD_PID" 2>/dev/null || true
    sleep 1
    CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
    if [ -n "$CHILD_PID" ]; then
      kill -9 "$CHILD_PID" 2>/dev/null || true
      sleep 0.5
    fi
  fi
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true
  sleep 0.5
  return 0
}
```

### Step 4: Clear each target team

For each team window W in TARGET_WINDOWS, do the following. **If WORKERS_ONLY is true, skip steps 4a and 4b** (only clear workers).

#### 4a. Clear the Window Manager (pane W.0) — skip if WORKERS_ONLY

```bash
MGR_PANE="${SESSION_NAME}:${W}.0"
echo "  ${W}.0 Window Manager..."
kill_pane_process "$MGR_PANE"

# Relaunch with the team-specific agent
# Agent name pattern: t${W}-manager (generated from doey-manager)
tmux send-keys -t "$MGR_PANE" "claude --dangerously-skip-permissions --name \"T${W} Window Manager\" --agent \"t${W}-manager\"" Enter
echo "  ${W}.0 Window Manager ✓"
sleep 0.5
```

#### 4b. Clear the Watchdog (lives in Dashboard window 0) — skip if WORKERS_ONLY

The Watchdog pane is in the Dashboard, not in the team window. Read `WATCHDOG_PANE` from team env:

```bash
WATCHDOG_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/team_${W}.env" | cut -d= -f2 | tr -d '"')
WDG_PANE="${SESSION_NAME}:${WATCHDOG_PANE}"
echo "  ${WATCHDOG_PANE} Watchdog..."
kill_pane_process "$WDG_PANE"

# Relaunch with the team-specific watchdog agent
tmux send-keys -t "$WDG_PANE" "claude --dangerously-skip-permissions --model opus --name \"T${W} Watchdog\" --agent \"t${W}-watchdog\"" Enter
echo "  ${WATCHDOG_PANE} Watchdog ✓"
sleep 0.5
```

#### 4c. Clear all Workers (panes W.1+)

```bash
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"
  PANE_SAFE=$(echo "$PANE" | tr ':.' '_')

  # Check if reserved (skip unless --force)
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  if [ "$FORCE" != "true" ] && [ -f "$STATUS_FILE" ] && grep -q "STATUS: RESERVED" "$STATUS_FILE"; then
    echo "  ${W}.${wp} — reserved, skipping (use --force to include)"
    continue
  fi

  # Kill process (returns 1 if pane not found)
  if ! kill_pane_process "$PANE"; then
    echo "  ${W}.${wp} — pane not found, skipping"
    continue
  fi

  # Get worker name from pane title
  W_NAME=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null || echo "T${W} W${wp}")

  # Find system prompt file for this worker
  WORKER_PROMPT=$(grep -rl "pane ${W}\.${wp} " "${RUNTIME_DIR}"/worker-system-prompt-*.md 2>/dev/null | head -1 || true)

  # Relaunch Claude with correct name and system prompt
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\" --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\"" Enter
  fi

  # Update status file
  mkdir -p "${RUNTIME_DIR}/status"
  cat > "$STATUS_FILE" << EOF
PANE: ${PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: READY
TASK: cleared
EOF

  echo "  ${W}.${wp} ✓"
  sleep 0.5
done
```

### Step 5: Report results

Print a summary:

```
Clear complete:
  Team 1: Manager ✓, Watchdog ✓, 6 workers cleared ✓
  Team 2: Manager ✓, Watchdog ✓, 5 workers cleared, 1 reserved (skipped) ✓
  Total: 2 managers, 2 watchdogs, 11 workers reset
```

### Important: Self-awareness

**If the caller IS a Window Manager being cleared**, warn that this command will kill the caller's own process:
- If targeting own team: "WARNING: This will kill my own process. I will be relaunched with fresh context."
- Proceed anyway — the kill/relaunch will handle it.

**If the caller IS the Session Manager (pane 0.1)**, never clear the Session Manager itself — only clear the target teams.

### Rules
- Clear order: Manager first, then Watchdog, then Workers (Manager restarts fastest, ready to receive workers as they come up)
- Never clear the Session Manager (pane 0.1) or Info Panel (pane 0.0)
- Skip reserved workers unless `--force` is used
- Always kill by PID (SIGTERM first, SIGKILL if needed), never via send-keys
- Always clear the terminal before relaunching
- Manager agent: `t${W}-manager`, Watchdog agent: `t${W}-watchdog`
- Workers use `--append-system-prompt-file` (not `--agent`)
- Use `sleep 0.5` between panes to avoid overwhelming tmux
- All bash must be bash 3.2 compatible
