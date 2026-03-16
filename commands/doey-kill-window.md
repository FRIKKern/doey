# Skill: doey-kill-window

Kill an entire team window — stops all Claude processes, removes the tmux window, and cleans up runtime files.

## Usage
`/doey-kill-window [window_index]` — kill a specific team window
`/doey-kill-window` — kill the current team window

## Prompt
You are killing a team window in a running Doey tmux session.

### Step 1: Parse target window and validate

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TARGET_WIN="${1:-$WINDOW_INDEX}"

if [ "$TARGET_WIN" = "0" ]; then
  echo "ERROR: Cannot kill window 0 (Dashboard). Use /doey-kill-session for full teardown."
  exit 1
fi

if ! tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | grep -qx "$TARGET_WIN"; then
  echo "ERROR: Window ${TARGET_WIN} does not exist in session ${SESSION_NAME}"
  exit 1
fi

echo "Target: window ${TARGET_WIN}"
```

### Step 2: Read team config and kill all processes

Uses vars from Step 1.

```bash
# (vars from step 1)
TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WIN}.env"
if [ -f "$TEAM_ENV" ]; then
  T_WORKER_PANES="" T_WATCHDOG_PANE="" T_MANAGER_PANE=""
  while IFS='=' read -r key value; do
    value="${value%\"}" && value="${value#\"}"
    case "$key" in
      WORKER_PANES) T_WORKER_PANES="$value" ;;
      WATCHDOG_PANE) T_WATCHDOG_PANE="$value" ;;
      MANAGER_PANE) T_MANAGER_PANE="$value" ;;
    esac
  done < "$TEAM_ENV"
fi

KILLED=0
for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do
  CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
  if [ -n "$CHILD_PID" ]; then
    kill "$CHILD_PID" 2>/dev/null
    KILLED=$((KILLED + 1))
  fi
done
echo "Sent SIGTERM to ${KILLED} processes"
sleep 3

for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do
  CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
done
sleep 1
```

### Step 3: Kill the tmux window

```bash
# (vars from step 1)
tmux kill-window -t "${SESSION_NAME}:${TARGET_WIN}"
echo "Window ${TARGET_WIN} killed"
```

### Step 4: Clean up runtime files

```bash
# (vars from step 1)
rm -f "${RUNTIME_DIR}/team_${TARGET_WIN}.env"

SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':.' '_')
for pattern in \
  "${RUNTIME_DIR}/status/${SESSION_SAFE}_${TARGET_WIN}_"* \
  "${RUNTIME_DIR}/results/pane_${TARGET_WIN}_"*.json \
  "${RUNTIME_DIR}/status/completion_pane_${TARGET_WIN}_"* \
  "${RUNTIME_DIR}/status/crash_pane_${TARGET_WIN}_"*; do
  for f in $pattern; do [ -f "$f" ] && rm -f "$f"; done
done
rm -f "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WIN}.json"
rm -f "${RUNTIME_DIR}/status/watchdog_W${TARGET_WIN}.heartbeat"

CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
NEW_WINDOWS=$(echo "$CURRENT_WINDOWS" | tr ',' '\n' | grep -v "^${TARGET_WIN}$" | tr '\n' ',' | sed 's/,$//')
TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX")
sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"
mv "$TMPENV" "${RUNTIME_DIR}/session.env"

echo "Runtime files cleaned for window ${TARGET_WIN}"
```

### Step 5: Report

```
Window ${TARGET_WIN} killed and cleaned up.
  Processes stopped: ${KILLED}
  Runtime files removed: team_${TARGET_WIN}.env, status/result/completion files
  TEAM_WINDOWS updated: ${NEW_WINDOWS}
```

### Rules
- **NEVER kill window 0** (Dashboard) — use `/doey-kill-session` for full teardown
- **Always kill processes before killing the window** — prevents orphan processes
- **Always clean up runtime files** after killing
- **Always update TEAM_WINDOWS** in session.env (atomic write)
- **Always kill by PID** — never use `/exit` or `send-keys`
- All bash must be 3.2 compatible
