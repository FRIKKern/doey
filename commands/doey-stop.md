# Skill: doey-stop

Stop a specific worker by pane number. Kills the Claude process, updates status, and leaves the pane shell intact for restart.

## Usage
`/doey-stop 4` — stop worker in pane 0.4
`/doey-stop` — lists workers, then ask which to stop

## Prompt

You are stopping a specific Claude Code worker instance in TMUX by pane number.

### Project Context (read once per Bash call)

Every Bash call must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `WINDOW_INDEX`. **Always use `${SESSION_NAME}`** — never hardcode session names.

### Step 1: Parse argument and validate target

If the user provided a pane number (e.g., `/doey-stop 4`), use it directly. If no number was given, list workers and ask which to stop.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"

TARGET="$PANE_NUMBER"  # set from user argument

# Validate target is a worker pane (not Window Manager or Watchdog)
if [ "$TARGET" = "0" ]; then
  echo "ERROR: Cannot stop pane ${WINDOW_INDEX}.0 — that is the Window Manager"
  exit 1
fi
if [ "$TARGET" = "$WATCHDOG_PANE" ]; then
  echo "ERROR: Cannot stop pane ${WINDOW_INDEX}.${WATCHDOG_PANE} — that is the Watchdog. Use /doey-restart-window instead."
  exit 1
fi

# Verify it's a valid worker pane
VALID=false
for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
  [ "$i" = "$TARGET" ] && VALID=true
done
if [ "$VALID" = "false" ]; then
  echo "ERROR: Pane ${WINDOW_INDEX}.${TARGET} is not a worker pane. Valid workers: ${WORKER_PANES}"
  exit 1
fi

echo "Target: pane ${WINDOW_INDEX}.${TARGET}"
```

### Step 2: Kill the Claude process by PID

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"

PANE="${SESSION_NAME}:${WINDOW_INDEX}.${TARGET}"

# Exit copy-mode first
tmux copy-mode -q -t "$PANE" 2>/dev/null

# Kill child process (Claude) of the pane's shell
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)

if [ -z "$CHILD_PID" ]; then
  echo "No Claude process found in pane ${WINDOW_INDEX}.${TARGET} — already stopped"
else
  kill "$CHILD_PID" 2>/dev/null
  sleep 3

  # Verify it died — SIGKILL if not
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  if [ -n "$CHILD_PID" ]; then
    kill -9 "$CHILD_PID" 2>/dev/null
    sleep 1
  fi

  # Final check
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  if [ -n "$CHILD_PID" ]; then
    echo "ERROR: Failed to stop Claude in pane ${WINDOW_INDEX}.${TARGET} — manual intervention needed"
    exit 1
  fi
fi

echo "Claude process stopped in pane ${WINDOW_INDEX}.${TARGET}"
```

### Step 3: Update status file

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"

PANE="${SESSION_NAME}:${WINDOW_INDEX}.${TARGET}"
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"

cat > "${RUNTIME_DIR}/status/${PANE_SAFE}.status" << EOF
PANE: ${PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: FINISHED
TASK: manually stopped
EOF

echo "Status updated to FINISHED for pane ${WINDOW_INDEX}.${TARGET}"
```

### Rules
- **Never stop the Window Manager pane** (pane index 0 in each window)
- **Never stop the Watchdog pane** — use `/doey-restart-window` instead
- **Always kill by PID** — never use `/exit` or `send-keys` to stop Claude
- **Always update the status file** after stopping
- The pane shell remains alive — the worker can be restarted via `/doey-dispatch` or `/doey-restart-window`
