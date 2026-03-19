# Skill: doey-worktree

Transform a team window to/from an isolated git worktree.

## Usage
`/doey-worktree [W]` — isolate team W in a new worktree (default: current window)
`/doey-worktree [W] --back` — return team W to main project directory

## Prompt

Transform a team window to work in an isolated git worktree. **Do NOT ask for confirmation.**

### Step 1: Parse arguments and load context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
TARGET_WIN="${DOEY_WINDOW_INDEX:-1}"
BACK_MODE=false
```

Parse user args: number → TARGET_WIN, `--back`/`back` → BACK_MODE=true, no args → current window.

Validate: TARGET_WIN != 0, team env exists, window exists in tmux.

### Step 2: Check worker status and isolation state

```bash
# Read WORKER_PANES, WORKTREE_DIR, WORKTREE_BRANCH from team env
while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    WORKER_PANES)    WORKER_PANES="$value" ;;
    WORKTREE_DIR)    WORKTREE_DIR="$value" ;;
    WORKTREE_BRANCH) WORKTREE_BRANCH="$value" ;;
  esac
done < "$TEAM_ENV"
WORKER_PANES_LIST=$(echo "$WORKER_PANES" | tr ',' ' ')

# Check for busy workers — refuse if any are BUSY
PANE_SAFE=$(echo "${SESSION_NAME}:${TARGET_WIN}.X" | tr ':.' '_')
# For each worker, check status file for BUSY. Error and exit if found.
```

Validate isolation state:
- `--back` but no WORKTREE_DIR → error
- Forward but WORKTREE_DIR set → error (already isolated)

### Step 3: Create or remove worktree

**Forward mode:**

```bash
BRANCH="doey/team-${TARGET_WIN}-$(date +%m%d-%H%M)"
WT_DIR="${PROJECT_DIR}/.doey-worktrees/team-${TARGET_WIN}"

# Remove stale worktree if exists
[ -d "$WT_DIR" ] && git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true

mkdir -p "$(dirname "$WT_DIR")"
git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$BRANCH" || { echo "ERROR: Failed"; exit 1; }

# Copy settings.local.json (gitignored)
if [ -f "${PROJECT_DIR}/.claude/settings.local.json" ]; then
  mkdir -p "${WT_DIR}/.claude"
  cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"
fi

# Update team env atomically
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
cat "$TEAM_ENV" > "$TMPENV"
echo "WORKTREE_DIR=${WT_DIR}" >> "$TMPENV"
echo "WORKTREE_BRANCH=${BRANCH}" >> "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$WT_DIR"
```

**Back mode:**

```bash
# Auto-commit uncommitted changes
DIRTY=$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
  git -C "$WORKTREE_DIR" add -A
  git -C "$WORKTREE_DIR" commit -m "doey: WIP from team ${TARGET_WIN} worktree"
fi

# Show commits on branch
MAIN_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
git -C "$WORKTREE_DIR" log --oneline "${MAIN_HEAD}..HEAD" 2>/dev/null || echo "  (none)"

# Remove worktree (branch preserved for manual merge)
git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>&1 || echo "WARNING: Manual removal needed"

# Update team env — remove worktree lines
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
grep -v '^WORKTREE_DIR=' "$TEAM_ENV" | grep -v '^WORKTREE_BRANCH=' > "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$PROJECT_DIR"
```

### Step 4: Restart workers in new directory

Kill all workers (SIGTERM → sleep 3 → SIGKILL stragglers, up to 5 attempts), clear terminals, then relaunch:

```bash
for i in $WORKER_PANES_LIST; do
  WORKER_PROMPT=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus" Enter
  fi
  sleep 0.5
done
```

### Step 5: Update window name and verify boot

Rename window: `T${TARGET_WIN} [worktree]` (forward) or `T${TARGET_WIN}` (back). Poll up to 10 attempts (5s each) checking for child process + "bypass permissions" in output.

### Step 6: Report

Summary: mode, window, branch, directory, booted count. List any down panes.

### Rules
- Kill by PID only; atomic file writes (temp + mv); never transform window 0
- Worktree path: `${PROJECT_DIR}/.doey-worktrees/team-${W}`
- Branch NOT deleted on `--back` — user merges manually
- Always copy `.claude/settings.local.json` to worktrees (gitignored)
- All bash 3.2 compatible
