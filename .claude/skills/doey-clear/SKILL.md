---
name: doey-clear
description: Kill and relaunch Claude instances. Use when you need to "restart workers", "reset the team", "clear and relaunch", or "fresh start". Resets process, context, name, agent, status. Skips reserved workers unless --force.
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-}"|| true`
- Team windows: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do echo "--- $(basename "$f") ---"; cat "$f" 2>/dev/null; done || true`

## Usage

`/doey-clear` — interactive
`/doey-clear all` — all teams
`/doey-clear team N` — specific team
`/doey-clear workers` — workers only (keep manager)
`/doey-clear all --force` — include reserved workers

## Step 1: Parse Arguments

No args → prompt interactively (suggest "this team" for Manager, "all teams" for SM).

Set: **TARGET_WINDOWS** (list), **FORCE** (bool), **WORKERS_ONLY** (bool).

## Step 2: Validate Targets

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
for W in $TARGET_WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  if [ ! -f "$TEAM_ENV" ]; then echo "WARNING: Team $W env not found — skipping"; continue; fi
  _tv() { grep "^$1=" "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }
  WORKER_PANES=$(_tv WORKER_PANES); WORKER_COUNT=$(_tv WORKER_COUNT)
  echo "Team $W: manager=0, workers=${WORKER_PANES} (${WORKER_COUNT})"
done
```

## Step 3: kill_pane_process helper

SIGTERM → 1s → SIGKILL → clear terminal. Returns 1 if pane missing.

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

## Step 4: Clear Manager (skip if WORKERS_ONLY)

Order: Manager → Workers.

```bash
MGR_PANE="${SESSION_NAME}:${W}.0"
kill_pane_process "$MGR_PANE"
tmux send-keys -t "$MGR_PANE" "claude --dangerously-skip-permissions --model opus --name \"T${W} Window Manager\" --agent \"t${W}-manager\"" Enter
echo "  ${W}.0 Manager ✓"; sleep 0.5
```

## Step 5: Clear Workers (W.1+)

Skip reserved unless --force. Kill, relaunch with name + system prompt, write READY status.

```bash
for wp in $(echo "$WORKER_PANES" | tr ',' ' '); do
  PANE="${SESSION_NAME}:${W}.${wp}"; PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
  if [ "$FORCE" != "true" ] && [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "  ${W}.${wp} — reserved"; continue; fi
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

## Step 6: Report

Print per-team summary: Manager status, workers cleared/reserved counts.

## Rules

- Skip reserved unless `--force`; skip Manager if WORKERS_ONLY
- Never clear Boss (0.1), Session Manager (0.2), or Info Panel (0.0)
- Kill by PID (SIGTERM → SIGKILL); `sleep 0.5` between panes
- Bash 3.2 compatible.
