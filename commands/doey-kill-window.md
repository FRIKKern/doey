# Skill: doey-kill-window

Kill a team window — stops processes, removes tmux window, cleans up runtime files.

## Usage
`/doey-kill-window [window_index]` — kill specific team window (default: current)

## Prompt

### Step 1: Parse and validate

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
TARGET_WIN="${1:-${DOEY_WINDOW_INDEX:-0}}"
[ "$TARGET_WIN" = "0" ] && echo "ERROR: Cannot kill Dashboard. Use /doey-kill-session." && exit 1
tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | grep -qx "$TARGET_WIN" || { echo "ERROR: Window not found"; exit 1; }
```

### Step 2: Kill all processes

SIGTERM all pane children, sleep 3, SIGKILL stragglers.

### Step 3: Worktree cleanup

Run BEFORE deleting team env. If team has WORKTREE_DIR:
1. Auto-commit uncommitted changes
2. Show commits ahead of main
3. Remove worktree (`git worktree remove --force` + prune)

```bash
_wt_dir=$(grep '^WORKTREE_DIR=' "${RUNTIME_DIR}/team_${TARGET_WIN}.env" 2>/dev/null | head -1 | cut -d= -f2-)
_wt_dir="${_wt_dir%\"}"; _wt_dir="${_wt_dir#\"}"
if [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ]; then
  _dirty=$(git -C "$_wt_dir" status --porcelain 2>/dev/null) || true
  [ -n "$_dirty" ] && { git -C "$_wt_dir" add -A && git -C "$_wt_dir" commit -m "doey: auto-save before teardown" 2>/dev/null || true; }
  git -C "$PROJECT_DIR" worktree remove "$_wt_dir" --force 2>/dev/null || true
  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
fi
```

### Step 4: Kill window and clean runtime

```bash
tmux kill-window -t "${SESSION_NAME}:${TARGET_WIN}"
rm -f "${RUNTIME_DIR}/team_${TARGET_WIN}.env"

PANE_SAFE_PREFIX=$(echo "${SESSION_NAME}" | tr ':.' '_')
for pattern in \
  "${RUNTIME_DIR}/status/${PANE_SAFE_PREFIX}_${TARGET_WIN}_"* \
  "${RUNTIME_DIR}/results/pane_${TARGET_WIN}_"*.json \
  "${RUNTIME_DIR}/status/completion_pane_${TARGET_WIN}_"* \
  "${RUNTIME_DIR}/status/crash_pane_${TARGET_WIN}_"*; do
  for f in $pattern; do [ -f "$f" ] && rm -f "$f"; done
done
rm -f "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WIN}.json"
rm -f "${RUNTIME_DIR}/status/watchdog_W${TARGET_WIN}.heartbeat"

# Update TEAM_WINDOWS atomically
CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" | cut -d= -f2 | tr -d '"')
NEW_WINDOWS=$(echo "$CURRENT_WINDOWS" | tr ',' '\n' | grep -v "^${TARGET_WIN}$" | tr '\n' ',' | sed 's/,$//')
TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX")
sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"
mv "$TMPENV" "${RUNTIME_DIR}/session.env"
```

### Step 5: Report

Processes stopped, runtime cleaned, TEAM_WINDOWS updated.

### Rules
- Never kill window 0; kill processes before window; clean runtime after; atomic TEAM_WINDOWS update
- All bash 3.2 compatible
