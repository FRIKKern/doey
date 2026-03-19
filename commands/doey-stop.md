# Skill: doey-stop

Stop a worker by pane number. Kills the Claude process, updates status, leaves pane shell intact.

## Usage
`/doey-stop 4` — stop worker in pane W.4
`/doey-stop` — lists workers, then ask which to stop

## Prompt

### Step 1: Validate target

If no pane number given, list workers and ask. Load context:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"

TARGET="$PANE_NUMBER"  # from user argument
if [ "$TARGET" = "0" ]; then echo "ERROR: Cannot stop pane ${WINDOW_INDEX}.0 (Window Manager)"; exit 1; fi

VALID=false
for i in $(echo "$WORKER_PANES" | tr ',' ' '); do [ "$i" = "$TARGET" ] && VALID=true; done
if [ "$VALID" = "false" ]; then echo "ERROR: Pane ${WINDOW_INDEX}.${TARGET} not a worker. Valid: ${WORKER_PANES}"; exit 1; fi
echo "Target: pane ${WINDOW_INDEX}.${TARGET}"
```

### Step 2: Kill Claude process

```bash
# (vars from step 1)
PANE="${SESSION_NAME}:${WINDOW_INDEX}.${TARGET}"
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)

if [ -z "$CHILD_PID" ]; then
  echo "No Claude process in pane ${WINDOW_INDEX}.${TARGET} — already stopped"
else
  kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null; sleep 1; }
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && { echo "ERROR: Failed to stop — manual intervention needed"; exit 1; }
fi
echo "Stopped pane ${WINDOW_INDEX}.${TARGET}"
```

### Step 3: Update status

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
echo "Status updated to FINISHED"
```

### Rules
- Never stop Window Manager (pane 0) or Watchdog
- Always kill by PID, never via `/exit` or `send-keys`
- Always update status after stopping
- Pane shell stays alive for restart via `/doey-dispatch` or `/doey-clear`
