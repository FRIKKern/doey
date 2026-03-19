---
name: doey-clear
description: Kill and relaunch Claude instances. Resets process, context, name, agent, status. Skips reserved workers unless --force.
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-|| true`
- Team windows: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do echo "--- $(basename "$f") ---"; cat "$f" 2>/dev/null; done || true`

## Usage

`/doey-clear` — interactive | `/doey-clear all` — all teams | `/doey-clear team N` — specific team
`/doey-clear workers` — workers only (keep manager + watchdog) | `/doey-clear all --force` — include reserved

## Prompt

Kill each Claude process, clear terminal, relaunch with correct names/agents/prompts. Use injected config variables (SESSION_NAME, TEAM_WINDOWS, WORKER_PANES, etc.).

### Interactive prompt (no arguments)

Skip if arguments provided. Window Manager: suggest "this team", offer "all teams" / "workers only". Session Manager: suggest "all teams", offer "specific team".

### Parse arguments

- **TARGET_WINDOWS**: `all` -> `$TEAM_WINDOWS`; `team N` -> window N; `workers` -> current team
- **FORCE**: `--force` anywhere in args — **WORKERS_ONLY**: `workers` target

### Validate + kill helper

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
_tv() { grep "^$1=" "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }  # safe read (no source — /tmp is world-writable)
kill_pane_process() {  # SIGTERM -> 1s -> SIGKILL -> clear. Returns 1 if pane missing.
  local PANE="$1" SHELL_PID CHILD_PID
  SHELL_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$SHELL_PID" ] && return 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true; sleep 1
  CHILD_PID=$(pgrep -P "$SHELL_PID" 2>/dev/null || true)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 0.5; }
  tmux send-keys -t "$PANE" "clear" Enter 2>/dev/null || true; sleep 0.5
}
for W in $TARGET_WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ ! -f "$TEAM_ENV" ] && echo "WARNING: Team $W env not found — skipping" && continue
  WATCHDOG_PANE=$(_tv WATCHDOG_PANE); WORKER_PANES=$(_tv WORKER_PANES); WORKER_COUNT=$(_tv WORKER_COUNT)
  echo "Team $W: manager=0, watchdog=${WATCHDOG_PANE}, workers=${WORKER_PANES} (${WORKER_COUNT})"
done
```

### Clear each target team

For each window W. **If WORKERS_ONLY, skip Manager and Watchdog.**

#### Manager (W.0)

```bash
kill_pane_process "${SESSION_NAME}:${W}.0"
tmux send-keys -t "${SESSION_NAME}:${W}.0" "claude --dangerously-skip-permissions --model opus --name \"T${W} Window Manager\" --agent \"t${W}-manager\"" Enter
echo "  ${W}.0 Manager ✓"; sleep 0.5
```

#### Watchdog (Dashboard window 0)

**CRITICAL**: Schedule briefing + scan loop after relaunch or Watchdog sits idle.

```bash
WDG_PANE="${SESSION_NAME}:${WATCHDOG_PANE}"
kill_pane_process "$WDG_PANE"
tmux send-keys -t "$WDG_PANE" "claude --dangerously-skip-permissions --model opus --name \"T${W} Watchdog\" --agent \"t${W}-watchdog\"" Enter
echo "  ${WATCHDOG_PANE} Watchdog ✓"; sleep 0.5
WP_LIST=$(echo "$WORKER_PANES" | tr ',' ' ' | sed "s/[0-9]*/${W}.&/g" | tr ' ' ',')
(
  sleep 15
  tmux send-keys -t "$WDG_PANE" "Start monitoring session ${SESSION_NAME} window ${W}. Skip pane ${WATCHDOG_PANE} (yourself). Manager=${W}.0. Monitor panes ${WP_LIST}." Enter
  sleep 20
  tmux send-keys -t "$WDG_PANE" '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
) &
```

#### Workers (W.1+)

```bash
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
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
  printf 'PANE: %s\nUPDATED: %s\nSTATUS: READY\nTASK: cleared\n' "$PANE" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  echo "  ${W}.${wp} ✓"; sleep 0.5
done
```

### Report + Rules

Print per-team summary: Manager/Watchdog status, workers cleared/reserved counts.
- Order: Manager -> Watchdog -> Workers. Never clear Session Manager (0.1) or Info Panel (0.0).
- If caller IS the Window Manager being cleared: warn, then proceed.
- Kill by PID (SIGTERM -> SIGKILL), never via send-keys. `sleep 0.5` between panes; bash 3.2 compatible.
