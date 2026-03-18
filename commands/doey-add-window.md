# Skill: doey-add-window

Add a new team window to the current Doey session with its own Window Manager, Watchdog, and Workers. Supports `--worktree` for git worktree isolation.

## Usage
`/doey-add-window [grid] [--worktree]` — add a team window, optionally isolated in a git worktree
`/doey-add-window 4x2` — add a 4x2 team window (7 panes: MGR + 6 workers) + Watchdog in Dashboard
`/doey-add-window --worktree` — add a default team window isolated in its own git worktree branch

## Prompt
You are adding a new team window to a running Doey tmux session.

### Step 1: Parse grid argument

Parse grid from user argument (default `4x2`), validate NxM format. Load project context.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

GRID="${USER_GRID:-4x2}"  # Set USER_GRID from argument, or accept default 4x2
COLS=$(echo "$GRID" | cut -dx -f1)
ROWS=$(echo "$GRID" | cut -dx -f2)

case "$COLS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid grid cols: $COLS"; exit 1 ;; esac
case "$ROWS" in [1-9]|[1-9][0-9]) ;; *) echo "ERROR: Invalid grid rows: $ROWS"; exit 1 ;; esac

TOTAL=$((COLS * ROWS))
if [ "$TOTAL" -lt 2 ]; then
  echo "ERROR: Grid $GRID has $TOTAL panes — need at least 2 (MGR + 1 worker)"
  exit 1
fi

WORKER_COUNT=$((TOTAL - 1))

# Parse --worktree flag
WORKTREE_MODE="false"
for _aw_arg in "$@"; do
  [ "$_aw_arg" = "--worktree" ] && WORKTREE_MODE="true"
done

echo "Grid: ${GRID} (${TOTAL} panes: 1 MGR + ${WORKER_COUNT} workers, Watchdog in Dashboard)"
if [ "$WORKTREE_MODE" = "true" ]; then
  echo "Worktree isolation: enabled"
fi
```

### Step 2: Create window and build grid

```bash
# (vars from step 1)

tmux new-window -t "$SESSION_NAME" -c "$PROJECT_DIR"
sleep 0.5

NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

NEEDED=$((TOTAL - 1))
for _s in $(seq 1 $NEEDED); do
  tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$PROJECT_DIR"
done

tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled
sleep 0.5
echo "Window ${NEW_WIN} created with ${TOTAL} panes"
```

### Step 3: Name panes and build worker list

```bash
# (vars from step 1)

tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "MGR Window Manager"

WORKER_PANES_LIST=""
W_NUM=1
for i in $(seq 1 $((TOTAL - 1))); do
  tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "W${W_NUM} Worker ${W_NUM}"
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
# (vars from step 1)

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

CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
if [ -n "$CURRENT_WINDOWS" ]; then
  NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}"
else
  NEW_WINDOWS="${NEW_WIN}"
fi

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
# (vars from step 1)

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

# Find next available Dashboard slot (0.2-0.7) for Watchdog
WDG_SLOT=""
for slot in 2 3 4 5 6 7; do
  SLOT_PID=$(tmux display-message -t "${SESSION_NAME}:0.${slot}" -p '#{pane_pid}' 2>/dev/null || true)
  SLOT_CHILD=$(pgrep -P "$SLOT_PID" 2>/dev/null || true)
  if [ -z "$SLOT_CHILD" ]; then
    WDG_SLOT="$slot"
    break
  fi
done

if [ -n "$WDG_SLOT" ]; then
  tmux select-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -T "Watchdog — Team ${NEW_WIN}"
  tmux send-keys -t "${SESSION_NAME}:0.${WDG_SLOT}" "claude --dangerously-skip-permissions --model opus --agent \"t${NEW_WIN}-watchdog\"" Enter
  sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=0.${WDG_SLOT}/" "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" && mv "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" "${RUNTIME_DIR}/team_${NEW_WIN}.env"
  echo "Watchdog launched in Dashboard pane 0.${WDG_SLOT}"
else
  echo "WARNING: No available Dashboard slot (0.2-0.7) for Watchdog"
fi

echo "All panes launched in window ${NEW_WIN}"
```

### Step 5b: Create worktree (if --worktree)

```bash
# (vars from previous steps)

# If --worktree flag was set, create a worktree for the new team
WT_DIR="" WT_BRANCH=""
if [ "$WORKTREE_MODE" = "true" ]; then
  WT_BRANCH="doey/team-${NEW_WIN}-$(date +%m%d-%H%M)"
  WT_DIR="${PROJECT_DIR}/.doey-worktrees/team-${NEW_WIN}"

  # Create worktree directory parent
  mkdir -p "${PROJECT_DIR}/.doey-worktrees"

  # Create git worktree
  if ! git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$WT_BRANCH" 2>&1; then
    echo "WARNING: Failed to create worktree. Team created without isolation."
    WT_DIR="" WT_BRANCH=""
  else
    # Copy settings.local.json (gitignored, won't be in worktree)
    if [ -f "${PROJECT_DIR}/.claude/settings.local.json" ]; then
      mkdir -p "${WT_DIR}/.claude"
      cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"
    fi

    # Update team env with worktree info
    TEAM_ENV="${RUNTIME_DIR}/team_${NEW_WIN}.env"
    if [ -f "$TEAM_ENV" ]; then
      _tmp_env=$(mktemp "${RUNTIME_DIR}/team_env_XXXXXX")
      cat "$TEAM_ENV" > "$_tmp_env"
      printf 'WORKTREE_DIR="%s"\n' "$WT_DIR" >> "$_tmp_env"
      printf 'WORKTREE_BRANCH="%s"\n' "$WT_BRANCH" >> "$_tmp_env"
      mv "$_tmp_env" "$TEAM_ENV"
    fi

    # NOTE: For workers to actually run in the worktree directory,
    # the doey.sh launcher needs the Wave 2 wiring (add_dynamic_team_window
    # accepting a worktree path). Until then, workers start in PROJECT_DIR
    # and the Window Manager should instruct them to work in WT_DIR.

    echo "Worktree created: $WT_DIR (branch: $WT_BRANCH)"
  fi
fi
```

### Step 6: Verify boot

```bash
# (vars from step 1)

sleep 8

NOT_READY=0; DOWN_PANES=""
for i in 0 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"
  fi
done

if [ -n "$WDG_SLOT" ]; then
  WDG_PID=$(tmux display-message -t "${SESSION_NAME}:0.${WDG_SLOT}" -p '#{pane_pid}')
  WDG_CHILD=$(pgrep -P "$WDG_PID" 2>/dev/null)
  WDG_OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -p 2>/dev/null)
  if [ -z "$WDG_CHILD" ] || ! echo "$WDG_OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES 0.$WDG_SLOT"
  fi
fi

if [ "$NOT_READY" -eq 0 ]; then
  echo "All panes booted successfully in window ${NEW_WIN}"
else
  echo "WARNING: ${NOT_READY} panes not ready:${DOWN_PANES} — may need more time"
fi
```

### Step 7: Report

If worktree mode succeeded, rename the tmux window:
```bash
if [ "$WORKTREE_MODE" = "true" ] && [ -n "$WT_DIR" ] && [ -d "$WT_DIR" ]; then
  tmux rename-window -t "${SESSION_NAME}:${NEW_WIN}" "T${NEW_WIN} [worktree]"
fi
```

Output a summary table:
```
Team window ${NEW_WIN} created:
  Grid:      ${GRID}
  Win Mgr:   ${NEW_WIN}.0
  Workers:   ${NEW_WIN}.1 — ${NEW_WIN}.$((TOTAL-1))  (${WORKER_COUNT} workers)
  Watchdog:  0.${WDG_SLOT} (Dashboard)
```
If worktree was created, also show:
```
  Worktree:  ${WT_DIR}
  Branch:    ${WT_BRANCH}
```

### Rules
- Validate grid format, minimum 2 panes (MGR + 1 worker)
- Pane 0 = Window Manager, pane 1+ = Workers; Watchdog goes to Dashboard slot 0.2-0.7
- Write team_W.env before launching Claude; update TEAM_WINDOWS atomically
- Never hardcode window indices — read from tmux
- All bash must be 3.2 compatible
- `--worktree` creates a git worktree at `${PROJECT_DIR}/.doey-worktrees/team-W/`
- Worktree creation is best-effort — team is still created even if worktree fails
- `.claude/settings.local.json` must be copied into worktree (it's gitignored)
