# Skill: doey-worktree

Isolate a team window in a git worktree, or return it.

## Usage
`/doey-worktree [W]` — isolate team W (default: current window)
`/doey-worktree [W] --back` — return team W to main project

## Prompt

Transform a team window to/from an isolated git worktree. **Do NOT ask for confirmation — just do it.**

### Step 1: Parse, validate, and check state

Parse user args: number → `TARGET_WIN`, `--back`/`back` → `BACK_MODE=true`, no args → current window.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_WIN="${DOEY_WINDOW_INDEX:-1}"
BACK_MODE=false
# Parse from user message: number → TARGET_WIN, --back → BACK_MODE

[ "$TARGET_WIN" = "0" ] && { echo "ERROR: Cannot transform Dashboard (window 0)"; exit 1; }

TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WIN}.env"
[ ! -f "$TEAM_ENV" ] && { echo "ERROR: No team env for window ${TARGET_WIN}"; exit 1; }
tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | grep -qx "$TARGET_WIN" || { echo "ERROR: Window ${TARGET_WIN} not found"; exit 1; }

# Load team env
eval "$(grep -E '^(WORKER_PANES|WORKTREE_DIR|WORKTREE_BRANCH)=' "$TEAM_ENV" | sed 's/^/export /')"
WORKER_PANES_LIST=$(echo "$WORKER_PANES" | tr ',' ' ')
SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':.' '_')

# Reject if any worker is busy
BUSY_WORKERS=""
for i in $WORKER_PANES_LIST; do
  STATUS_FILE="${RUNTIME_DIR}/status/${SESSION_SAFE}_${TARGET_WIN}_${i}.status"
  [ -f "$STATUS_FILE" ] || continue
  PANE_STATUS=$(grep '^STATUS:' "$STATUS_FILE" | head -1 | sed 's/^STATUS: *//')
  [ "$PANE_STATUS" = "BUSY" ] && BUSY_WORKERS="$BUSY_WORKERS ${TARGET_WIN}.${i}"
done
[ -n "$BUSY_WORKERS" ] && { echo "ERROR: Busy workers:${BUSY_WORKERS} — wait or stop them first"; exit 1; }

# Validate mode vs current state
if [ "$BACK_MODE" = "true" ]; then
  [ -z "$WORKTREE_DIR" ] && { echo "ERROR: Team ${TARGET_WIN} not in a worktree"; exit 1; }
else
  [ -n "$WORKTREE_DIR" ] && { echo "ERROR: Already in worktree: ${WORKTREE_DIR}. Use --back first"; exit 1; }
fi
```

### Step 2: Create or remove worktree

Run **forward** or **back** block based on `$BACK_MODE`.

**Forward (isolate):**

```bash
BRANCH="doey/team-${TARGET_WIN}-$(date +%m%d-%H%M)"
WT_DIR="${PROJECT_DIR}/.doey-worktrees/team-${TARGET_WIN}"

[ -d "$WT_DIR" ] && git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true
mkdir -p "$(dirname "$WT_DIR")"
WT_OUTPUT=$(git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$BRANCH" 2>&1) || { echo "ERROR: $WT_OUTPUT"; exit 1; }

[ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"

# Record worktree in team env (atomic)
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
cat "$TEAM_ENV" > "$TMPENV"
printf 'WORKTREE_DIR=%s\nWORKTREE_BRANCH=%s\n' "$WT_DIR" "$BRANCH" >> "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$WT_DIR"
```

**Back (return):**

```bash
DIRTY=$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)
[ -n "$DIRTY" ] && git -C "$WORKTREE_DIR" add -A && git -C "$WORKTREE_DIR" commit -m "doey: WIP from team ${TARGET_WIN} worktree"

MAIN_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
echo "Commits on branch ${WORKTREE_BRANCH}:"
git -C "$WORKTREE_DIR" log --oneline "${MAIN_HEAD}..HEAD" 2>/dev/null || echo "  (none)"

git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>&1 || echo "WARNING: Manual removal needed: git worktree remove '$WORKTREE_DIR' --force"

# Strip worktree vars from team env (atomic)
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
grep -v '^WORKTREE_DIR=' "$TEAM_ENV" | grep -v '^WORKTREE_BRANCH=' > "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$PROJECT_DIR"
```

### Step 3: Kill workers, relaunch in TARGET_DIR

Kill by PID only — never `/exit` or `C-c`.

```bash
# Send TERM to all worker children
for i in $WORKER_PANES_LIST; do
  PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
done
sleep 3

# Force-kill stragglers (up to 5 attempts, 2s apart)
STILL_RUNNING=0; STUCK_PANES=""
for attempt in 1 2 3 4 5; do
  STILL_RUNNING=0; STUCK_PANES=""
  for i in $WORKER_PANES_LIST; do
    CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
    [ -n "$CHILD_PID" ] && { STILL_RUNNING=$((STILL_RUNNING + 1)); STUCK_PANES="$STUCK_PANES ${TARGET_WIN}.$i"; kill -9 "$CHILD_PID" 2>/dev/null; }
  done
  [ "$STILL_RUNNING" -eq 0 ] && break
  sleep 2
done
[ "$STILL_RUNNING" -ne 0 ] && { echo "FAILED: Panes${STUCK_PANES} still running. Manual intervention needed."; exit 1; }

# Clear panes and relaunch
for i in $WORKER_PANES_LIST; do
  tmux copy-mode -q -t "${SESSION_NAME}:${TARGET_WIN}.${i}" 2>/dev/null
  tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "clear" Enter 2>/dev/null
done
sleep 1
for i in $WORKER_PANES_LIST; do
  WORKER_PROMPT=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  CMD="cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus"
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "$CMD" Enter
  sleep 0.5
done
```

### Step 4: Rename window, verify boot, report

```bash
[ "$BACK_MODE" = "true" ] && tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN}" || tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN} [worktree]"

# Wait up to 50s for all workers to boot
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  NOT_READY=0; DOWN_PANES=""
  for i in $WORKER_PANES_LIST; do
    CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
    OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p 2>/dev/null)
    if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
      NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${TARGET_WIN}.$i"
    fi
  done
  [ "$NOT_READY" -eq 0 ] && break
  sleep 5
done
```

Output summary: mode (isolate/return), window, branch, directory, booted count. List any failed workers.

### Rules
- Bash 3.2 compatible (no `declare -A`, `mapfile`, `|&`, `&>>`, `[[ =~ ]]` captures, `printf '%(%s)T'`)
- Kill by PID only — never `/exit` or `send-keys C-c`
- `tmux show-environment` for DOEY_RUNTIME — never hardcode paths
- Status files: `${RUNTIME_DIR}/status/${SESSION_SAFE}_${WIN}_${PANE}.status`
- Atomic writes: temp file then `mv`
- Never transform window 0
- Worktree branch preserved on `--back` — user merges manually
- Always copy `.claude/settings.local.json` to new worktrees (gitignored)
