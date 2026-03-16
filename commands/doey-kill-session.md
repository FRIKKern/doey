# Skill: doey-kill-session

Kill the entire Doey session — all windows, all processes, all runtime files.

## Usage
`/doey-kill-session`

## Prompt
You are tearing down an entire Doey tmux session.

### Project Context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

### Step 1: Confirm with user

**Before doing anything**, ask the user:

> This will kill the entire Doey session `${SESSION_NAME}` — all windows, all processes, and remove all runtime files at `${RUNTIME_DIR}`. Proceed? (yes/no)

**Do NOT proceed without explicit confirmation.**

### Step 2: List all windows and kill processes

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

echo "Killing all processes in session ${SESSION_NAME}..."

WINDOWS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null)
TOTAL_KILLED=0

for w in $WINDOWS; do
  for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do
    CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
    if [ -n "$CHILD_PID" ]; then
      kill "$CHILD_PID" 2>/dev/null
      TOTAL_KILLED=$((TOTAL_KILLED + 1))
    fi
  done
done

echo "Sent SIGTERM to ${TOTAL_KILLED} processes"
sleep 2

# SIGKILL stragglers
for w in $WINDOWS; do
  for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${w}" -F '#{pane_pid}' 2>/dev/null); do
    CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
    [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
  done
done
sleep 1
```

### Step 3: Kill the tmux session and clean up

**Important:** Capture RUNTIME_DIR and SESSION_NAME before killing the session, since `tmux show-environment` will fail after the session is destroyed.

```bash
# These values were captured in Step 2 — reuse them here
# RUNTIME_DIR and SESSION_NAME are already set from the earlier source

tmux kill-session -t "$SESSION_NAME"
echo "Session ${SESSION_NAME} killed"

# Step 4: Clean up runtime files (RUNTIME_DIR captured before kill)
rm -rf "$RUNTIME_DIR"
echo "Runtime directory removed: ${RUNTIME_DIR}"
```

### Step 4: Report

```
Session ${SESSION_NAME} fully torn down.
  Processes killed: ${TOTAL_KILLED}
  Runtime removed: ${RUNTIME_DIR}
```

### Rules
- **ALWAYS confirm with the user** before proceeding — this is destructive and irreversible
- **Kill all processes before killing the session** — prevents orphans
- **Remove the entire runtime directory** — all team files, status, results, messages
- **This command cannot be undone** — the session must be re-initialized with `doey init`
- All bash must be 3.2 compatible
