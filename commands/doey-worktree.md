# Skill: doey-worktree

Transform a team window to work in an isolated git worktree, or transform back.

## Usage
`/doey-worktree [W]` — isolate team W in a new worktree (default: current window)
`/doey-worktree [W] --back` — return team W to the main project directory

## Prompt

You are transforming a team window to work in an isolated git worktree in a running Doey tmux session. **Do NOT ask for confirmation — just do it immediately.**

### Step 1: Parse arguments and load context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_WIN="${DOEY_WINDOW_INDEX:-1}"
BACK_MODE=false

# Parse args from user message after /doey-worktree
# First numeric arg = TARGET_WIN, --back sets BACK_MODE
```

Read the user's arguments after `/doey-worktree`:
- A number → set `TARGET_WIN` to that number
- `--back` or `back` → set `BACK_MODE=true`
- No arguments → use current window index

Validate:

```bash
# (vars from above)
if [ "$TARGET_WIN" = "0" ]; then
  echo "ERROR: Cannot transform the Dashboard (window 0)"
  exit 1
fi

TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WIN}.env"
if [ ! -f "$TEAM_ENV" ]; then
  echo "ERROR: No team env file for window ${TARGET_WIN} — is it a valid team window?"
  exit 1
fi

# Verify window exists in tmux
if ! tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | grep -qx "$TARGET_WIN"; then
  echo "ERROR: Window ${TARGET_WIN} does not exist in session ${SESSION_NAME}"
  exit 1
fi

echo "Target window: ${TARGET_WIN}, Back mode: ${BACK_MODE}"
```

### Step 2: Check worker status and current state

```bash
# (vars from step 1)
WORKER_PANES=""
WORKTREE_DIR=""
WORKTREE_BRANCH=""

while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    WORKER_PANES)    WORKER_PANES="$value" ;;
    WORKTREE_DIR)    WORKTREE_DIR="$value" ;;
    WORKTREE_BRANCH) WORKTREE_BRANCH="$value" ;;
  esac
done < "$TEAM_ENV"

WORKER_PANES_LIST=$(echo "$WORKER_PANES" | tr ',' ' ')
mkdir -p "${RUNTIME_DIR}/status"

# Check if any worker is busy
BUSY_WORKERS=""
for i in $WORKER_PANES_LIST; do
  STATUS_FILE="${RUNTIME_DIR}/status/pane_${TARGET_WIN}_${i}.status"
  if [ -f "$STATUS_FILE" ]; then
    PANE_STATUS=$(grep '^STATUS:' "$STATUS_FILE" | head -1 | sed 's/^STATUS: *//')
    if [ "$PANE_STATUS" = "BUSY" ]; then
      BUSY_WORKERS="$BUSY_WORKERS ${TARGET_WIN}.${i}"
    fi
  fi
done

if [ -n "$BUSY_WORKERS" ]; then
  echo "ERROR: Cannot transform — busy workers:${BUSY_WORKERS}"
  echo "Wait for workers to finish or stop them first."
  exit 1
fi
```

Check current isolation state:

```bash
# (vars from above)
if [ "$BACK_MODE" = "true" ]; then
  if [ -z "$WORKTREE_DIR" ]; then
    echo "ERROR: Team ${TARGET_WIN} is not in a worktree — nothing to return from"
    exit 1
  fi
  echo "Returning team ${TARGET_WIN} from worktree: ${WORKTREE_DIR} (branch: ${WORKTREE_BRANCH})"
else
  if [ -n "$WORKTREE_DIR" ]; then
    echo "ERROR: Team ${TARGET_WIN} is already in a worktree: ${WORKTREE_DIR}"
    echo "Use '/doey-worktree ${TARGET_WIN} --back' to return first"
    exit 1
  fi
  echo "Isolating team ${TARGET_WIN} into a new worktree"
fi
```

### Step 3: Create or remove worktree

**Forward mode (no --back):**

```bash
# (vars from step 1)
BRANCH="doey/team-${TARGET_WIN}-$(date +%m%d-%H%M)"
WT_DIR="${PROJECT_DIR}/.doey-worktrees/team-${TARGET_WIN}"

# Clean up stale worktree at this path if it exists
if [ -d "$WT_DIR" ]; then
  git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true
fi

mkdir -p "$(dirname "$WT_DIR")"
WT_OUTPUT=$(git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$BRANCH" 2>&1)
WT_EXIT=$?

if [ "$WT_EXIT" -ne 0 ]; then
  echo "ERROR: Failed to create worktree:"
  echo "$WT_OUTPUT"
  exit 1
fi

echo "Worktree created: $WT_DIR (branch: $BRANCH)"

# Copy settings.local.json (gitignored — won't be in worktree)
if [ -f "${PROJECT_DIR}/.claude/settings.local.json" ]; then
  mkdir -p "${WT_DIR}/.claude"
  cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"
  echo "Copied .claude/settings.local.json to worktree"
fi

# Update team_W.env atomically — append worktree vars
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
cat "$TEAM_ENV" > "$TMPENV"
echo "WORKTREE_DIR=${WT_DIR}" >> "$TMPENV"
echo "WORKTREE_BRANCH=${BRANCH}" >> "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"

TARGET_DIR="$WT_DIR"
echo "team_${TARGET_WIN}.env updated with worktree info"
```

**Back mode (--back):**

```bash
# (vars from step 1, step 2)
# Check for uncommitted changes
DIRTY=$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
  echo "Uncommitted changes detected — auto-committing..."
  git -C "$WORKTREE_DIR" add -A
  git -C "$WORKTREE_DIR" commit -m "doey: WIP from team ${TARGET_WIN} worktree"
  echo "Auto-committed WIP changes"
fi

# Show commits made on this branch
MAIN_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
echo ""
echo "Commits on branch ${WORKTREE_BRANCH}:"
git -C "$WORKTREE_DIR" log --oneline "${MAIN_HEAD}..HEAD" 2>/dev/null || echo "  (none)"
echo ""

# Remove worktree
WT_RM_OUTPUT=$(git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>&1)
WT_RM_EXIT=$?
if [ "$WT_RM_EXIT" -ne 0 ]; then
  echo "WARNING: Failed to remove worktree: $WT_RM_OUTPUT"
  echo "You may need to manually run: git worktree remove '$WORKTREE_DIR' --force"
fi

# Update team_W.env — remove worktree lines
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
grep -v '^WORKTREE_DIR=' "$TEAM_ENV" | grep -v '^WORKTREE_BRANCH=' > "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"

TARGET_DIR="$PROJECT_DIR"
echo "team_${TARGET_WIN}.env cleaned — worktree references removed"
```

Determine which block to run based on `$BACK_MODE`.

### Step 4: Restart workers in new directory

Kill all worker processes and relaunch them with the new working directory.

```bash
# (vars from step 1) — TARGET_DIR set in step 3

# Kill worker processes
for i in $WORKER_PANES_LIST; do
  PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
done
sleep 3

# Verify killed — force kill if needed
for attempt in 1 2 3 4 5; do
  STILL_RUNNING=0; STUCK_PANES=""
  for i in $WORKER_PANES_LIST; do
    PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)
    CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
    if [ -n "$CHILD_PID" ]; then
      STILL_RUNNING=$((STILL_RUNNING + 1)); STUCK_PANES="$STUCK_PANES ${TARGET_WIN}.$i"
      kill -9 "$CHILD_PID" 2>/dev/null
    fi
  done
  [ "$STILL_RUNNING" -eq 0 ] && break
  sleep 2
done

if [ "$STILL_RUNNING" -ne 0 ]; then
  echo "FAILED: Panes${STUCK_PANES} still have processes after 5 kill attempts. Manual intervention needed."
  exit 1
fi

# Clear terminals
for i in $WORKER_PANES_LIST; do
  tmux copy-mode -q -t "${SESSION_NAME}:${TARGET_WIN}.${i}" 2>/dev/null
  tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "clear" Enter 2>/dev/null
done
sleep 1

# Relaunch workers in the target directory
for i in $WORKER_PANES_LIST; do
  WORKER_PROMPT=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus" Enter
  fi
  sleep 0.5
done

echo "Workers relaunched in: ${TARGET_DIR}"
```

### Step 5: Update window name and verify boot

```bash
# (vars from step 1)
if [ "$BACK_MODE" = "true" ]; then
  tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN}"
else
  tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN} [worktree]"
fi

# Verify boot
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  NOT_READY=0; DOWN_PANES=""
  for i in $WORKER_PANES_LIST; do
    PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)
    CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
    OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p 2>/dev/null)
    if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
      NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${TARGET_WIN}.$i"
    fi
  done
  [ "$NOT_READY" -eq 0 ] && break
  sleep 5
done
```

### Step 6: Final report

Output a summary:

If forward mode:
```
Worktree transformation complete:
  Mode:       isolate
  Window:     ${TARGET_WIN}
  Branch:     ${BRANCH}
  Directory:  ${WT_DIR}
  Workers:    N/N booted
```

If back mode:
```
Worktree transformation complete:
  Mode:       return
  Window:     ${TARGET_WIN}
  Branch:     ${WORKTREE_BRANCH} (preserved — merge manually when ready)
  Directory:  ${PROJECT_DIR}
  Workers:    N/N booted
```

Include booted count from verify step. If any workers failed to boot, list the down panes.

### Rules
- All bash MUST be 3.2 compatible: NO `declare -A`, NO `mapfile`/`readarray`, NO `|&`, NO `&>>`, NO `[[ =~ ]]` capture groups, NO `printf '%(%s)T'`
- Each step is a self-contained bash block — variables cascade with `# (vars from step 1)` comments
- Kill by PID only — never use `/exit` or `send-keys C-c` to stop Claude
- Use `tmux show-environment` for DOEY_RUNTIME — never hardcode paths
- Status files: `${RUNTIME_DIR}/status/pane_${WIN}_${PANE}.status`
- Atomic file writes: write to temp file, then `mv`
- Never transform window 0
- The worktree branch is NOT deleted on `--back` — user merges manually when ready
- Worktree path: `${PROJECT_DIR}/.doey-worktrees/team-${W}`
- Always copy `.claude/settings.local.json` to new worktrees (it is gitignored)
