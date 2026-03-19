# Skill: doey-add-window

Add a new team window with Window Manager, Watchdog, and Workers. Supports `--worktree` for git worktree isolation.

## Usage
`/doey-add-window [grid] [--worktree]`
`/doey-add-window 4x2` — 7 panes (MGR + 6 workers) + Watchdog in Dashboard
`/doey-add-window --worktree` — default grid, isolated in git worktree

## Prompt

### Step 1: Parse grid argument

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

GRID="${USER_GRID:-4x2}"
COLS=$(echo "$GRID" | cut -dx -f1)
ROWS=$(echo "$GRID" | cut -dx -f2)
case "$COLS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid cols"; exit 1 ;; esac
case "$ROWS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid rows"; exit 1 ;; esac
TOTAL=$((COLS * ROWS))
[ "$TOTAL" -lt 2 ] && echo "ERROR: Need at least 2 panes" && exit 1
WORKER_COUNT=$((TOTAL - 1))

WORKTREE_MODE="false"
for _aw_arg in "$@"; do [ "$_aw_arg" = "--worktree" ] && WORKTREE_MODE="true"; done
```

### Step 2: Create window and build grid

```bash
tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR"; sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')
for _s in $(seq 1 $((TOTAL - 1))); do
  tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"
done
tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled; sleep 0.5
```

### Step 3: Name panes and build worker list

```bash
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "MGR Window Manager"
WORKER_PANES_LIST=""; W_NUM=1
for i in $(seq 1 $((TOTAL - 1))); do
  tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "W${W_NUM} Worker ${W_NUM}"
  [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"
  W_NUM=$((W_NUM + 1))
done
```

### Step 4: Write team environment file

Write `team_${NEW_WIN}.env` (atomic: temp + mv) with SESSION_NAME, PROJECT_DIR, PROJECT_NAME, WINDOW_INDEX, GRID, TOTAL_PANES, MANAGER_PANE=0, WORKER_PANES, WORKER_COUNT, WATCHDOG_PANE=.

Update TEAM_WINDOWS in session.env atomically (append NEW_WIN).

### Step 5: Launch Claude in each pane

```bash
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" "claude --dangerously-skip-permissions --agent doey-manager" Enter
sleep 1

for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  WORKER_PROMPT=$(grep -l "pane ${NEW_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" "claude --dangerously-skip-permissions --model opus" Enter
  fi
  sleep 0.5
done

# Find next free Dashboard slot (0.2-0.7) for Watchdog
WDG_SLOT=""
for slot in 2 3 4 5 6 7; do
  SLOT_PID=$(tmux display-message -t "${SESSION_NAME}:0.${slot}" -p '#{pane_pid}' 2>/dev/null || true)
  SLOT_CHILD=$(pgrep -P "$SLOT_PID" 2>/dev/null || true)
  [ -z "$SLOT_CHILD" ] && WDG_SLOT="$slot" && break
done

if [ -n "$WDG_SLOT" ]; then
  tmux select-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -T "Watchdog — Team ${NEW_WIN}"
  tmux send-keys -t "${SESSION_NAME}:0.${WDG_SLOT}" "claude --dangerously-skip-permissions --model opus --agent \"t${NEW_WIN}-watchdog\"" Enter
  sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=0.${WDG_SLOT}/" "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" && mv "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" "${RUNTIME_DIR}/team_${NEW_WIN}.env"
else
  echo "WARNING: No available Dashboard slot for Watchdog"
fi
```

### Step 5b: Create worktree (if --worktree)

If `WORKTREE_MODE=true`, create worktree using same approach as `/doey-worktree` forward mode:
- Branch: `doey/team-${NEW_WIN}-$(date +%m%d-%H%M)`, Dir: `${PROJECT_DIR}/.doey-worktrees/team-${NEW_WIN}`
- Copy `.claude/settings.local.json` to worktree
- Update team env with WORKTREE_DIR and WORKTREE_BRANCH
- Best-effort — team created even if worktree fails
- Rename window to `T${NEW_WIN} [worktree]` on success

### Step 6: Verify boot

Sleep 8s, check each pane (MGR + workers + Watchdog) for child process + "bypass permissions" in output. Report any panes not ready.

### Step 7: Report

Summary: grid, window index, worker range, watchdog slot. Include worktree path/branch if created.

### Rules
- Pane 0 = Manager, 1+ = Workers; Watchdog in Dashboard 0.2-0.7
- Write team env before launching; update TEAM_WINDOWS atomically
- All bash 3.2 compatible
