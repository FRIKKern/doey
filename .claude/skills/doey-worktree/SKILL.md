---
name: doey-worktree
description: Isolate a team window in a git worktree, or return it.
---

## Usage
`/doey-worktree [W]` — isolate team W (default: current window)
`/doey-worktree [W] --back` — return team W to main project

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team environments: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done || true`
- Current windows: !`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null|| true`
- Worker statuses: !`W=$(tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-); for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status/*_${W}_*.status; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`

## Prompt

Transform a team window to/from an isolated git worktree. **Do NOT ask for confirmation — just do it.**

## Step 1: Parse arguments and load environment
bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && TARGET_WIN="${DOEY_WINDOW_INDEX:-1}" && BACK_MODE=false
Expected: RUNTIME_DIR set to `/tmp/doey/<project>/`, TARGET_WIN set to window number, BACK_MODE=false.

Parse user args: number → `TARGET_WIN`, `--back`/`back` → `BACK_MODE=true`, no args → current window.

**If this fails with "unknown variable DOEY_RUNTIME":** The session env is not loaded. Run `tmux show-environment -t <session>` to inspect.

## Step 2: Validate window target
bash: [ "$TARGET_WIN" = "0" ] && { echo "ERROR: Cannot transform Dashboard (window 0)"; exit 1; }; TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WIN}.env"; [ ! -f "$TEAM_ENV" ] && { echo "ERROR: No team env for window ${TARGET_WIN}"; exit 1; }
Expected: TARGET_WIN is not 0 and team env file exists.

**If this fails with "No team env for window":** The team window does not exist or was never initialized. Check `ls ${RUNTIME_DIR}/team_*.env`.

## Step 3: Verify window exists in tmux
bash: SESSION_NAME=$(grep '^SESSION_NAME=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"') && tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | grep -qx "$TARGET_WIN" || { echo "ERROR: Window ${TARGET_WIN} not found"; exit 1; }
Expected: Window TARGET_WIN found in tmux session.

**If this fails with "Window N not found":** The tmux window was destroyed. Use `/doey-list-windows` to see active windows.

## Step 4: Load team config and check for busy workers
bash: PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"') && PROJECT_NAME=$(grep '^PROJECT_NAME=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
Expected: PROJECT_DIR and PROJECT_NAME loaded from session.env.

Load team env (no `eval` — /tmp is world-writable):
```bash
_tv() { grep "^$1=" "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }
WORKER_PANES=$(_tv WORKER_PANES)
WORKTREE_DIR=$(_tv WORKTREE_DIR)
WORKTREE_BRANCH=$(_tv WORKTREE_BRANCH)
WORKER_PANES_LIST=$(echo "$WORKER_PANES" | tr ',' ' ')
SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':.' '_')
```

Then reject if any worker is busy:
```bash
BUSY_WORKERS=""
for i in $WORKER_PANES_LIST; do
  STATUS_FILE="${RUNTIME_DIR}/status/${SESSION_SAFE}_${TARGET_WIN}_${i}.status"
  [ -f "$STATUS_FILE" ] || continue
  PANE_STATUS=$(grep '^STATUS:' "$STATUS_FILE" | head -1 | sed 's/^STATUS: *//')
  [ "$PANE_STATUS" = "BUSY" ] && BUSY_WORKERS="$BUSY_WORKERS ${TARGET_WIN}.${i}"
done
[ -n "$BUSY_WORKERS" ] && { echo "ERROR: Busy workers:${BUSY_WORKERS} — wait or stop them first"; exit 1; }
```
Expected: No busy workers. WORKER_PANES, WORKTREE_DIR, WORKTREE_BRANCH loaded.

**If this fails with "Busy workers:":** Wait for workers to finish or use `/doey-stop` to stop them first.

## Step 5: Validate mode vs current state
bash: if [ "$BACK_MODE" = "true" ]; then [ -z "$WORKTREE_DIR" ] && { echo "ERROR: Team ${TARGET_WIN} not in a worktree"; exit 1; }; else [ -n "$WORKTREE_DIR" ] && { echo "ERROR: Already in worktree: ${WORKTREE_DIR}. Use --back first"; exit 1; }; fi
Expected: Forward mode requires no existing worktree; back mode requires an existing worktree.

**If this fails with "Already in worktree":** Run `/doey-worktree --back` first to return before re-isolating.
**If this fails with "not in a worktree":** The team is already on the main project directory. Nothing to return from.

## Step 6a: Create worktree (forward mode only)
bash: BRANCH="doey/team-${TARGET_WIN}-$(date +%m%d-%H%M)" && WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/team-${TARGET_WIN}" && [ -d "$WT_DIR" ] && git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true && mkdir -p "/tmp/doey/${PROJECT_NAME}/worktrees" && WT_OUTPUT=$(git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$BRANCH" 2>&1) || { echo "ERROR: $WT_OUTPUT"; exit 1; }
Expected: New worktree created at `/tmp/doey/<project>/worktrees/team-<N>` on branch `doey/team-<N>-MMDD-HHMM`.

Then copy settings and update team env:
```bash
[ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"

# Record worktree in team env (atomic)
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
cat "$TEAM_ENV" > "$TMPENV"
printf 'WORKTREE_DIR=%s\nWORKTREE_BRANCH=%s\n' "$WT_DIR" "$BRANCH" >> "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$WT_DIR"
```
Expected: `.claude/settings.local.json` copied, team env updated with WORKTREE_DIR and WORKTREE_BRANCH.

**If this fails with "fatal: '$WT_DIR' already exists":** A stale worktree exists. Run `git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force` manually.
**If this fails with "fatal: A branch named 'doey/team-...' already exists":** Delete the branch first: `git -C "$PROJECT_DIR" branch -D <branch>`.

## Step 6b: Remove worktree (back mode only)
bash: DIRTY=$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null) && [ -n "$DIRTY" ] && git -C "$WORKTREE_DIR" add -A && git -C "$WORKTREE_DIR" commit -m "doey: WIP from team ${TARGET_WIN} worktree"
Expected: Any uncommitted changes auto-committed before removal.

Then log commits and remove:
```bash
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
Expected: Worktree removed, team env cleaned, TARGET_DIR set back to PROJECT_DIR.

**If this fails with "fatal: '$WORKTREE_DIR' is not a working tree":** The worktree was already removed. Manually clean team env by stripping WORKTREE_DIR and WORKTREE_BRANCH lines.

## Step 7: Kill worker processes
bash: for i in $WORKER_PANES_LIST; do PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null); CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null); [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; done; sleep 3
Expected: All worker Claude processes receive SIGTERM and begin shutting down.

Then force-kill stragglers:
```bash
for i in $WORKER_PANES_LIST; do
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
done
sleep 1
```
Expected: All worker processes terminated. No Claude processes left in worker panes.

**If this fails with "No such session":** The tmux pane was already destroyed. Skip that pane and continue.

## Step 8: Clear panes and relaunch workers
bash: for i in $WORKER_PANES_LIST; do tmux copy-mode -q -t "${SESSION_NAME}:${TARGET_WIN}.${i}" 2>/dev/null; tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "clear" Enter 2>/dev/null; done; sleep 1
Expected: All worker pane terminals cleared.

Then relaunch each worker in TARGET_DIR:
```bash
for i in $WORKER_PANES_LIST; do
  WORKER_PROMPT=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1 || true)
  CMD="cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus --name \"T${TARGET_WIN} W${i}\""
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "$CMD" Enter
  sleep 0.5
done
```
Expected: All workers relaunched in TARGET_DIR with correct names and system prompts.

**If this fails with "no server running":** tmux session died. The entire session needs restarting.

## Step 9: Rename window and verify boot
bash: [ "$BACK_MODE" = "true" ] && tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN}" || tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN} [worktree]"
Expected: Window renamed to "T<N> [worktree]" (forward) or "T<N>" (back).

Then wait up to 25s for workers to boot:
```bash
for attempt in 1 2 3 4 5; do
  NOT_READY=0; DOWN_PANES=""
  for i in $WORKER_PANES_LIST; do
    OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p 2>/dev/null)
    echo "$OUTPUT" | grep -q "bypass permissions" || { NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${TARGET_WIN}.$i"; }
  done
  [ "$NOT_READY" -eq 0 ] && break
  sleep 5
done
```
Expected: All workers show "bypass permissions" in their pane output within 25 seconds.

**If this fails with workers not booting after 25s:** Check `tmux capture-pane -t <pane> -p` for error messages. Common cause: invalid system prompt path or missing claude binary.

## Step 10: Report summary
Output summary: mode (isolate/return), window, branch, directory, booted count. List any failed workers.
Expected: Clear summary of what was done and current state.

## Gotchas

- Do NOT transform window 0 (Dashboard) — always reject TARGET_WIN=0
- Do NOT use `eval` or `source` on team env files — /tmp is world-writable, parse with grep only
- Do NOT use `/exit` or `send-keys C-c` to kill workers — always kill by PID (SIGTERM then SIGKILL)
- Do NOT hardcode RUNTIME_DIR — always read from `tmux show-environment DOEY_RUNTIME`
- Do NOT forget to copy `.claude/settings.local.json` to new worktrees (it's gitignored)
- Do NOT delete the worktree branch on `--back` — user merges manually
- Do NOT skip atomic writes (temp file + mv) for team env updates

Total: 10 commands, 0 errors expected.

### Rules
- Bash 3.2 compatible (no `declare -A`, `mapfile`, `|&`, `&>>`, `[[ =~ ]]` captures, `printf '%(%s)T'`)
- Kill by PID only — never `/exit` or `send-keys C-c`
- `tmux show-environment` for DOEY_RUNTIME — never hardcode paths
- Status files: `${RUNTIME_DIR}/status/${SESSION_SAFE}_${WIN}_${PANE}.status`
- Atomic writes: temp file then `mv`
- Never transform window 0
- Worktree branch preserved on `--back` — user merges manually
- Always copy `.claude/settings.local.json` to new worktrees (gitignored)
