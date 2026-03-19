# Skill: doey-kill-session

Kill the entire Doey session — all windows, processes, and runtime files.

## Usage
`/doey-kill-session`

## Prompt

**Confirm first:** "This will kill session `${SESSION_NAME}`, all processes, and remove `${RUNTIME_DIR}`. Proceed?"
Do NOT proceed without explicit yes.

### Kill processes

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

WINDOWS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null)
TOTAL_KILLED=0
for w in $WINDOWS; do
  for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do
    CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
    if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null; TOTAL_KILLED=$((TOTAL_KILLED + 1)); fi
  done
done
echo "Sent SIGTERM to ${TOTAL_KILLED} processes"; sleep 2

# SIGKILL stragglers
for w in $WINDOWS; do
  for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do
    CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
    [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
  done
done
sleep 1
```

### Kill session and clean up

RUNTIME_DIR and SESSION_NAME are already captured — reuse after kill.

```bash
tmux kill-session -t "$SESSION_NAME"
rm -rf "$RUNTIME_DIR"
echo "Session ${SESSION_NAME} killed, runtime removed: ${RUNTIME_DIR}"
```

Report: processes killed, session destroyed, runtime cleaned.

### Rules
- **Always confirm** — destructive and irreversible
- Kill processes before session (prevents orphans)
- Cannot be undone — re-initialize with `doey`
