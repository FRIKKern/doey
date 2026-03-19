# Skill: doey-kill-window

Kill a team window — stop processes, remove tmux window, clean runtime files.

## Usage
`/doey-kill-window [window_index]` — kill specific or current team window

## Prompt
Kill a team window and clean up.

### Step 1: Parse and validate

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TARGET_WIN="${1:-$WINDOW_INDEX}"
[ "$TARGET_WIN" = "0" ] && echo "ERROR: Cannot kill window 0 (Dashboard). Use /doey-kill-session." && exit 1
tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | grep -qx "$TARGET_WIN" || { echo "ERROR: Window ${TARGET_WIN} not found"; exit 1; }
echo "Target: window ${TARGET_WIN}"
```

### Step 2: Kill all processes

```bash
# (vars from step 1)
KILLED=0
for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do
  CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null && KILLED=$((KILLED + 1))
done
echo "Sent SIGTERM to ${KILLED} processes"
sleep 3
for pane_pid in $(tmux list-panes -t "${SESSION_NAME}:${TARGET_WIN}" -F '#{pane_pid}' 2>/dev/null); do
  CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
done
sleep 1
```

### Step 3: Worktree cleanup

Must run BEFORE deleting team env files.

```bash
# (vars from step 1)
_wt_dir="" _wt_branch=""
if [ -f "${RUNTIME_DIR}/team_${TARGET_WIN}.env" ]; then
  _wt_dir=$(grep '^WORKTREE_DIR=' "${RUNTIME_DIR}/team_${TARGET_WIN}.env" 2>/dev/null | head -1 | cut -d= -f2-)
  _wt_dir="${_wt_dir%\"}" && _wt_dir="${_wt_dir#\"}"
  _wt_branch=$(grep '^WORKTREE_BRANCH=' "${RUNTIME_DIR}/team_${TARGET_WIN}.env" 2>/dev/null | head -1 | cut -d= -f2-)
  _wt_branch="${_wt_branch%\"}" && _wt_branch="${_wt_branch#\"}"
fi
if [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ]; then
  echo "Worktree detected: $_wt_dir (branch: $_wt_branch)"
  _dirty=$(git -C "$_wt_dir" status --porcelain 2>/dev/null) || true
  if [ -n "$_dirty" ]; then
    git -C "$_wt_dir" add -A 2>/dev/null || true
    git -C "$_wt_dir" commit -m "doey: auto-save before teardown $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
    echo "  Auto-saved to branch: $_wt_branch"
  fi
  if [ -n "$_wt_branch" ]; then
    _ahead=$(git -C "$PROJECT_DIR" rev-list --count "HEAD..${_wt_branch}" 2>/dev/null || echo "0")
    [ "$_ahead" -gt 0 ] 2>/dev/null && echo "  Branch $_wt_branch has $_ahead commit(s). Merge with: git merge $_wt_branch"
  fi
  git -C "$PROJECT_DIR" worktree remove "$_wt_dir" --force 2>/dev/null || true
  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
  echo "  Worktree removed."
fi
```

### Step 4: Kill window + clean runtime

```bash
# (vars from step 1)
tmux kill-window -t "${SESSION_NAME}:${TARGET_WIN}"
echo "Window ${TARGET_WIN} killed"

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
echo "Runtime files cleaned"
```

### Step 5: Report

```
Window ${TARGET_WIN} killed. Processes stopped: ${KILLED}. TEAM_WINDOWS: ${NEW_WINDOWS}
```

### Rules
- **NEVER kill window 0** — use `/doey-kill-session` for full teardown
- **Kill processes before window** — prevents orphans
- **Clean runtime files + update TEAM_WINDOWS** (atomic write)
- **Kill by PID** — never `/exit` or `send-keys`
- Bash 3.2 compatible
