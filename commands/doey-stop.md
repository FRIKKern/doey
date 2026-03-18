# Skill: doey-stop

Stop a specific worker by pane number. Kills the Claude process, updates status, and leaves the pane shell intact for restart.

## Usage
`/doey-stop 4` — stop worker in pane W.4
`/doey-stop` — lists workers, then ask which to stop

## Prompt

You are stopping a specific Claude Code worker instance in TMUX by pane number.

### Step 1: Parse argument and validate target

If user provided a pane number, use it directly. If not, list workers and ask which to stop. Load project context.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"

TARGET="$PANE_NUMBER"  # set from user argument

if [ "$TARGET" = "0" ]; then
  echo "ERROR: Cannot stop pane ${WINDOW_INDEX}.0 — that is the Window Manager"
  exit 1
fi
# NOTE: Watchdog runs in Dashboard (${WATCHDOG_PANE}), not in team windows

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
# (vars from step 1)

PANE="${SESSION_NAME}:${WINDOW_INDEX}.${TARGET}"
tmux copy-mode -q -t "$PANE" 2>/dev/null

PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)

if [ -z "$CHILD_PID" ]; then
  echo "No Claude process found in pane ${WINDOW_INDEX}.${TARGET} — already stopped"
else
  kill "$CHILD_PID" 2>/dev/null
  sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  if [ -n "$CHILD_PID" ]; then
    kill -9 "$CHILD_PID" 2>/dev/null
    sleep 1
  fi
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
# (vars from step 1)

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
- Never stop Window Manager (pane 0) or Watchdog — use `/doey-clear` for full resets
- Always kill by PID, never via `/exit` or `send-keys`
- Always update the status file after stopping
- Pane shell stays alive for restart via `/doey-dispatch` or `/doey-clear`
