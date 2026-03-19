# Skill: doey-stop

Stop a worker by pane number. Kills process, updates status, leaves shell for restart.

## Usage
`/doey-stop 4` — stop worker in pane W.4
`/doey-stop` — lists workers, asks which to stop

## Prompt

### Step 1: Validate target

Load context, parse pane number from args (or ask). Reject pane 0 (Window Manager). Verify target is in WORKER_PANES.

### Step 2: Kill by PID

```bash
PANE="${SESSION_NAME}:${WINDOW_INDEX}.${TARGET}"
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)

if [ -z "$CHILD_PID" ]; then
  echo "Already stopped"
else
  kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null || true; sleep 1; }
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && echo "ERROR: Failed to stop" && exit 1
fi
```

### Step 3: Update status

```bash
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"
cat > "${RUNTIME_DIR}/status/${PANE_SAFE}.status" << EOF
PANE: ${PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: FINISHED
TASK: manually stopped
EOF
```

### Rules
- Never stop Manager (pane 0) or Watchdog; kill by PID only
- Always update status file; shell stays alive for restart via `/doey-dispatch`
