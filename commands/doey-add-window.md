# Skill: doey-add-window

Add a new team window to the current Doey session with its own Window Manager, Watchdog, and Workers.

## Usage
`/doey-add-window [grid]` — add a team window (default grid: 2x2)
`/doey-add-window 3x2` — add a 3x2 team window (6 panes: MGR + WDG + 4 workers)

## Prompt
You are adding a new team window to a running Doey tmux session.

### Project Context

Every Bash call must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`. **Always use `${SESSION_NAME}`** — never hardcode session names.

### Step 1: Parse grid argument

Parse the grid from the user argument. Default is `2x2`. Validate NxM format.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

GRID="${1:-2x2}"
COLS=$(echo "$GRID" | cut -dx -f1)
ROWS=$(echo "$GRID" | cut -dx -f2)

# Validate
case "$COLS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid grid cols: $COLS"; exit 1 ;; esac
case "$ROWS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid grid rows: $ROWS"; exit 1 ;; esac

TOTAL=$((COLS * ROWS))
if [ "$TOTAL" -lt 3 ]; then
  echo "ERROR: Grid $GRID has $TOTAL panes — need at least 3 (MGR + WDG + 1 worker)"
  exit 1
fi

WORKER_COUNT=$((TOTAL - 2))
echo "Grid: ${GRID} (${TOTAL} panes: 1 MGR + 1 WDG + ${WORKER_COUNT} workers)"
```

### Step 2: Create the new window and build the grid

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# Create new window (pane 0 is created automatically)
tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR"
sleep 0.5

# Get new window index
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

# Create remaining panes (TOTAL - 1 splits needed)
NEEDED=$((TOTAL - 1))
for _s in $(seq 1 $NEEDED); do
  tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"
done

# Balance layout
tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled
sleep 0.5

echo "Window ${NEW_WIN} created with ${TOTAL} panes"
```

### Step 3: Name panes and build worker list

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# Pane 0 = Window Manager, Pane 1 = Watchdog, Pane 2+ = Workers
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "MGR-W${NEW_WIN}"
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.1" -T "WDG-W${NEW_WIN}"

WORKER_PANES_LIST=""
W_NUM=1
for i in $(seq 2 $((TOTAL - 1))); do
  tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "W${W_NUM}-W${NEW_WIN}"
  if [ -n "$WORKER_PANES_LIST" ]; then
    WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}"
  else
    WORKER_PANES_LIST="${i}"
  fi
  W_NUM=$((W_NUM + 1))
done

echo "Panes named. Workers: ${WORKER_PANES_LIST}"
```

### Step 4: Write team environment file

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TEAM_FILE="${RUNTIME_DIR}/team_${NEW_WIN}.env"
cat > "${TEAM_FILE}.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=${GRID}
TOTAL_PANES=${TOTAL}
MANAGER_PANE=0
WATCHDOG_PANE=1
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
TEAM_EOF
mv "${TEAM_FILE}.tmp" "$TEAM_FILE"

# Update TEAM_WINDOWS in session.env (append new window index)
CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
if [ -n "$CURRENT_WINDOWS" ]; then
  NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}"
else
  NEW_WINDOWS="${NEW_WIN}"
fi

# Atomic update of session.env
TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX")
if grep -q '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env"; then
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"
else
  cat "${RUNTIME_DIR}/session.env" > "$TMPENV"
  echo "TEAM_WINDOWS=${NEW_WINDOWS}" >> "$TMPENV"
fi
mv "$TMPENV" "${RUNTIME_DIR}/session.env"

echo "team_${NEW_WIN}.env written. TEAM_WINDOWS=${NEW_WINDOWS}"
```

### Step 5: Launch Claude Code in each pane

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# Window Manager
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" "claude --dangerously-skip-permissions --agent doey-manager" Enter
sleep 1

# Watchdog
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.1" "claude --dangerously-skip-permissions --model haiku --agent doey-watchdog" Enter
sleep 1

# Workers
for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "claude --dangerously-skip-permissions --model opus" Enter
  sleep 0.5
done

echo "All panes launched in window ${NEW_WIN}"
```

### Step 6: Verify boot

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

sleep 8

NOT_READY=0; DOWN_PANES=""
for i in 0 1 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"
  fi
done

if [ "$NOT_READY" -eq 0 ]; then
  echo "All panes booted successfully in window ${NEW_WIN}"
else
  echo "WARNING: ${NOT_READY} panes not ready:${DOWN_PANES} — may need more time"
fi
```

### Step 7: Report

Output a summary table:
```
Team window ${NEW_WIN} created:
  Grid:      ${GRID}
  Win Mgr:   ${NEW_WIN}.0
  Watchdog:  ${NEW_WIN}.1
  Workers:   ${NEW_WIN}.2 — ${NEW_WIN}.$((TOTAL-1))  (${WORKER_COUNT} workers)
```

### Rules
- **Always validate grid format** before creating panes
- **Minimum 3 panes** per team window (MGR + WDG + 1 worker)
- **Pane 0 is always Window Manager, pane 1 is always Watchdog** in new windows
- **Always write team_W.env** before launching Claude instances
- **Always update TEAM_WINDOWS** in session.env (atomic write)
- **Never hardcode window indices** — always read from tmux
- All bash must be 3.2 compatible — no associative arrays, no mapfile
