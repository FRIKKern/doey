---
name: doey-add-window
description: Add a new team window (Manager + Workers + Watchdog), optionally in a git worktree.
---

## Usage
`/doey-add-window [grid] [--worktree]` — default grid: 4x2

## Context

Session config:
!`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Current windows:
!`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`

## Prompt

Add a new team window to the running Doey session.

### Step 1: Parse grid and validate

Parse grid from user arg (default `4x2`), validate NxM (min 2 panes). `--worktree` enables isolation.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

GRID="${USER_GRID:-4x2}"  # Set USER_GRID from argument
COLS=$(echo "$GRID" | cut -dx -f1)
ROWS=$(echo "$GRID" | cut -dx -f2)
case "$COLS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid cols: $COLS"; exit 1 ;; esac
case "$ROWS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid rows: $ROWS"; exit 1 ;; esac
TOTAL=$((COLS * ROWS))
[ "$TOTAL" -lt 2 ] && { echo "ERROR: Need at least 2 panes (MGR + 1 worker)"; exit 1; }
WORKER_COUNT=$((TOTAL - 1))

WORKTREE_MODE="false"
for _aw_arg in "$@"; do [ "$_aw_arg" = "--worktree" ] && WORKTREE_MODE="true"; done
```

### Step 2: Create window, build grid, name panes

```bash
tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR"
sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

for _s in $(seq 1 $((TOTAL - 1))); do
  tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"
done
tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled
sleep 0.5

tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "MGR Window Manager"
WORKER_PANES_LIST=""
for i in $(seq 1 $((TOTAL - 1))); do
  tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "W${i} Worker ${i}"
  [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"
done
```

### Step 3: Write team env and update session

```bash
TEAM_FILE="${RUNTIME_DIR}/team_${NEW_WIN}.env"
cat > "${TEAM_FILE}.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${PROJECT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=${GRID}
TOTAL_PANES=${TOTAL}
MANAGER_PANE=0
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
WATCHDOG_PANE=
TEAM_EOF
mv "${TEAM_FILE}.tmp" "$TEAM_FILE"

# Append window to TEAM_WINDOWS atomically
CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
[ -n "$CURRENT_WINDOWS" ] && NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}" || NEW_WINDOWS="${NEW_WIN}"
TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX")
if grep -q '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env"; then
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"
else
  cat "${RUNTIME_DIR}/session.env" > "$TMPENV"
  echo "TEAM_WINDOWS=${NEW_WINDOWS}" >> "$TMPENV"
fi
mv "$TMPENV" "${RUNTIME_DIR}/session.env"
```

### Step 4: Launch Claude in all panes

```bash
# Manager
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" "claude --dangerously-skip-permissions --agent doey-manager" Enter
sleep 1

# Workers
for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  WORKER_PROMPT=$(grep -l "pane ${NEW_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  CMD="claude --dangerously-skip-permissions --model opus"
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "$CMD" Enter
  sleep 0.5
done

# Watchdog — first available Dashboard slot (0.2-0.7)
WDG_SLOT=""
for slot in 2 3 4 5 6 7; do
  SLOT_CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:0.${slot}" -p '#{pane_pid}' 2>/dev/null || echo 0)" 2>/dev/null || true)
  [ -z "$SLOT_CHILD" ] && { WDG_SLOT="$slot"; break; }
done
if [ -n "$WDG_SLOT" ]; then
  tmux select-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -T "Watchdog — Team ${NEW_WIN}"
  tmux send-keys -t "${SESSION_NAME}:0.${WDG_SLOT}" "claude --dangerously-skip-permissions --model opus --agent \"t${NEW_WIN}-watchdog\"" Enter
  sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=0.${WDG_SLOT}/" "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" && mv "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" "${RUNTIME_DIR}/team_${NEW_WIN}.env"
else
  echo "WARNING: No available Dashboard slot for Watchdog"
fi
```

### Step 5: Create worktree (if --worktree)

Best-effort — team is still created if worktree fails.

```bash
WT_DIR="" WT_BRANCH=""
if [ "$WORKTREE_MODE" = "true" ]; then
  WT_BRANCH="doey/team-${NEW_WIN}-$(date +%m%d-%H%M)"
  WT_DIR="${PROJECT_DIR}/.doey-worktrees/team-${NEW_WIN}"
  mkdir -p "${PROJECT_DIR}/.doey-worktrees"

  if ! git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$WT_BRANCH" 2>&1; then
    echo "WARNING: Worktree failed. Team created without isolation."
    WT_DIR="" WT_BRANCH=""
  else
    [ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"

    _tmp_env=$(mktemp "${RUNTIME_DIR}/team_env_XXXXXX")
    cat "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "$_tmp_env"
    printf 'WORKTREE_DIR="%s"\nWORKTREE_BRANCH="%s"\n' "$WT_DIR" "$WT_BRANCH" >> "$_tmp_env"
    mv "$_tmp_env" "${RUNTIME_DIR}/team_${NEW_WIN}.env"
  fi
fi
```

### Step 6: Verify boot and report

```bash
sleep 8

NOT_READY=0; DOWN_PANES=""
for i in 0 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"
  fi
done

if [ -n "$WDG_SLOT" ]; then
  WDG_CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:0.${WDG_SLOT}" -p '#{pane_pid}')" 2>/dev/null)
  WDG_OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -p 2>/dev/null)
  if [ -z "$WDG_CHILD" ] || ! echo "$WDG_OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES 0.$WDG_SLOT"
  fi
fi

[ "$NOT_READY" -eq 0 ] && echo "All panes booted" || echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"
```

Rename window if worktree succeeded, then output summary: grid, manager pane, worker range, watchdog slot, worktree info if applicable.

### Rules
- Pane 0 = Manager, 1+ = Workers; Watchdog in Dashboard 0.2-0.7
- Write team_W.env before launching; update TEAM_WINDOWS atomically
- Never hardcode window indices. Bash 3.2 compatible.
- Copy `.claude/settings.local.json` into worktrees (gitignored)
