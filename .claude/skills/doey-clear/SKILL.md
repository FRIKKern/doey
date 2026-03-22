---
name: doey-clear
description: Kill and relaunch Claude instances. Use when you need to "restart workers", "reset the team", "clear and relaunch", or "fresh start". Resets process, context, name, agent, status. Skips reserved workers unless --force.
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-}"|| true`
- Team windows: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do echo "--- $(basename "$f") ---"; cat "$f" 2>/dev/null; done || true`

**Expected:** 3-4 bash commands per pane (kill, clear, relaunch, verify), ~30 seconds per team.

## Usage

`/doey-clear` — interactive
`/doey-clear all` — all teams
`/doey-clear team N` — specific team
`/doey-clear workers` — workers only (keep manager + watchdog)
`/doey-clear all --force` — include reserved workers

## Step 1: Parse Arguments

If no arguments provided, prompt interactively. Window Manager: suggest "this team", offer "all teams" / "workers only". Session Manager: suggest "all teams", offer "specific team". Accept "1", "this team", "all", "team 2", etc.

Set these variables from arguments:
- **TARGET_WINDOWS**: `all` -> `$TEAM_WINDOWS`; `team N` -> window N; `workers` -> current team
- **FORCE**: `--force` anywhere in args
- **WORKERS_ONLY**: `workers` target

## Step 2: Validate Targets

Check that each target team's env file exists. Read pane config safely (no `source` — /tmp is world-writable).

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
for W in $TARGET_WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ ! -f "$TEAM_ENV" ] && echo "WARNING: Team $W env not found — skipping" && continue
  # Safe reads (no source — /tmp is world-writable)
  _tv() { grep "^$1=" "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }
  WATCHDOG_PANE=$(_tv WATCHDOG_PANE); WORKER_PANES=$(_tv WORKER_PANES); WORKER_COUNT=$(_tv WORKER_COUNT)
  echo "Team $W: manager=0, watchdog=${WATCHDOG_PANE}, workers=${WORKER_PANES} (${WORKER_COUNT})"
done
```

Expected: one line per team with pane layout.
**If error:** team env file missing — skip that team and warn.

## Step 3: Kill Pane Process

Helper function used by Steps 4-6. SIGTERM -> 1s -> SIGKILL if needed -> clear terminal. Returns 1 if pane missing.

```bash
kill_pane_process() {
  local PANE="$1" SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true; sleep 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  tmux copy-mode -q -t "$PANE" 2>/dev/null || true
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true; sleep 0.5
}
```

Expected: process killed, terminal cleared.
**If error:** pane missing — function returns 1, caller skips.

## Step 4: Clear Manager (W.0)

**Skip this step if WORKERS_ONLY.** Order: Manager first, then Watchdog, then Workers.

```bash
MGR_PANE="${SESSION_NAME}:${W}.0"
kill_pane_process "$MGR_PANE"
tmux send-keys -t "$MGR_PANE" "claude --dangerously-skip-permissions --model opus --name \"T${W} Window Manager\" --agent \"t${W}-manager\"" Enter
echo "  ${W}.0 Manager ✓"; sleep 0.5
```

Expected: Manager relaunched with correct name and agent.
**If error:** pane not found — warn and continue to next step.

## Step 5: Clear Watchdog

**Skip this step if WORKERS_ONLY.** After relaunch, schedule briefing + scan loop or Watchdog sits idle.

```bash
WATCHDOG_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/team_${W}.env" | cut -d= -f2 | tr -d '"')
WDG_PANE="${SESSION_NAME}:${WATCHDOG_PANE}"
kill_pane_process "$WDG_PANE"
tmux send-keys -t "$WDG_PANE" "claude --dangerously-skip-permissions --model haiku --name \"T${W} Watchdog\" --agent \"t${W}-watchdog\"" Enter
echo "  ${WATCHDOG_PANE} Watchdog ✓"; sleep 0.5
# Schedule briefing after all panes relaunched
WP_LIST=$(echo "$WORKER_PANES" | tr ',' ' ' | sed "s/[0-9][0-9]*/${W}.&/g" | tr ' ' ',')
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

Expected: Watchdog relaunched, briefing scheduled in background (~35s).
**If error:** pane not found — warn and continue.

## Step 6: Clear Workers (W.1+)

Loop over WORKER_PANES. Skip reserved panes unless --force. Kill process, relaunch with correct name and system prompt, write READY status.

```bash
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"
  PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

  if [ "$FORCE" != "true" ] && [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "  ${W}.${wp} — reserved (use --force)"; continue
  fi
  kill_pane_process "$PANE" || { echo "  ${W}.${wp} — not found"; continue; }

  W_NAME=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null || echo "T${W} W${wp}")
  WORKER_PROMPT=$(grep -rl "pane ${W}\.${wp} " "${RUNTIME_DIR}"/worker-system-prompt-*.md 2>/dev/null | head -1 || true)
  CMD="claude --dangerously-skip-permissions --model opus --name \"${W_NAME}\""
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "$PANE" "$CMD" Enter

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

Expected: each non-reserved worker relaunched, status file written as READY.
**If error:** pane not found — skip with warning. Reserved pane — skip with note.

## Step 7: Report

Print per-team summary: Manager/Watchdog status, workers cleared/reserved counts. If caller IS the Window Manager being cleared: warn, then proceed.

Total: 5-7 bash commands per team (validate, kill+relaunch manager, kill+relaunch watchdog, kill+relaunch each worker), 0 errors expected.

## Gotchas

- Do NOT clear reserved panes unless `--force` is specified
- Do NOT kill the Manager pane (pane 0) when WORKERS_ONLY
- Do NOT restart while another clear is in progress
- Do NOT forget to schedule Watchdog briefing after relaunch — without it, Watchdog sits idle
- Do NOT clear Session Manager (0.1) or Info Panel (0.0) — ever
- Kill by PID (SIGTERM -> SIGKILL), never via send-keys
- `sleep 0.5` between panes; all bash must be 3.2 compatible
