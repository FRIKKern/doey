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

## Step 1: Parse arguments
bash: `RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && TARGET_WIN="${DOEY_WINDOW_INDEX:-1}" && BACK_MODE=false`

Parse: number → `TARGET_WIN`, `--back`/`back` → `BACK_MODE=true`, no args → current window.

## Step 2: Validate target
bash: `[ "$TARGET_WIN" = "0" ] && { echo "ERROR: Cannot transform Dashboard"; exit 1; }; TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WIN}.env"; [ ! -f "$TEAM_ENV" ] && { echo "ERROR: No team env for window ${TARGET_WIN}"; exit 1; }`

## Step 3: Verify window exists
bash: `SESSION_NAME=$(grep '^SESSION_NAME=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"') && tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | grep -qx "$TARGET_WIN" || { echo "ERROR: Window ${TARGET_WIN} not found"; exit 1; }`

## Step 4: Load config, reject busy workers

```bash
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
PROJECT_NAME=$(grep '^PROJECT_NAME=' "${RUNTIME_DIR}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
_tv() { grep "^$1=" "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }
WORKER_PANES=$(_tv WORKER_PANES); WORKTREE_DIR=$(_tv WORKTREE_DIR); WORKTREE_BRANCH=$(_tv WORKTREE_BRANCH)
WORKER_PANES_LIST=$(echo "$WORKER_PANES" | tr ',' ' ')
SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':-.' '_')

BUSY_WORKERS=""
for i in $WORKER_PANES_LIST; do
  STATUS_FILE="${RUNTIME_DIR}/status/${SESSION_SAFE}_${TARGET_WIN}_${i}.status"
  [ -f "$STATUS_FILE" ] || continue
  PANE_STATUS=$(grep '^STATUS:' "$STATUS_FILE" | head -1 | sed 's/^STATUS: *//')
  [ "$PANE_STATUS" = "BUSY" ] && BUSY_WORKERS="$BUSY_WORKERS ${TARGET_WIN}.${i}"
done
[ -n "$BUSY_WORKERS" ] && { echo "ERROR: Busy workers:${BUSY_WORKERS} — wait or /doey-stop first"; exit 1; }
```

## Step 5: Validate mode vs state
bash: `if [ "$BACK_MODE" = "true" ]; then [ -z "$WORKTREE_DIR" ] && { echo "ERROR: Not in a worktree"; exit 1; }; else [ -n "$WORKTREE_DIR" ] && { echo "ERROR: Already in worktree — use --back first"; exit 1; }; fi`

## Step 6a: Create worktree (forward)
bash: `BRANCH="doey/team-${TARGET_WIN}-$(date +%m%d-%H%M)" && WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/team-${TARGET_WIN}" && if [ -d "$WT_DIR" ]; then git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true; fi && mkdir -p "/tmp/doey/${PROJECT_NAME}/worktrees" && WT_OUTPUT=$(git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$BRANCH" 2>&1) || { echo "ERROR: $WT_OUTPUT"; exit 1; }`

Then copy settings and update team env:
```bash
[ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"
TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
cat "$TEAM_ENV" > "$TMPENV"
printf 'WORKTREE_DIR=%s\nWORKTREE_BRANCH=%s\n' "$WT_DIR" "$BRANCH" >> "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$WT_DIR"
```

## Step 6b: Remove worktree (back)

Auto-commit dirty state, log branch commits, remove worktree, strip vars from team env:
```bash
DIRTY=$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)
[ -n "$DIRTY" ] && git -C "$WORKTREE_DIR" add -A && git -C "$WORKTREE_DIR" commit -m "doey: WIP from team ${TARGET_WIN} worktree"

MAIN_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
echo "Commits on branch ${WORKTREE_BRANCH}:"
git -C "$WORKTREE_DIR" log --oneline "${MAIN_HEAD}..HEAD" 2>/dev/null || echo "  (none)"
git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>&1 || echo "WARNING: Manual removal needed"

TMPENV=$(mktemp "${RUNTIME_DIR}/team_${TARGET_WIN}.env.tmp_XXXXXX")
grep -v '^WORKTREE_DIR=' "$TEAM_ENV" | grep -v '^WORKTREE_BRANCH=' > "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$PROJECT_DIR"
```

## Step 7: Kill workers (SIGTERM → SIGKILL)
```bash
for i in $WORKER_PANES_LIST; do
  PANE_PID=$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null); [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
done; sleep 3
for i in $WORKER_PANES_LIST; do
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
done; sleep 1
```

## Step 8: Clear and relaunch in TARGET_DIR
```bash
for i in $WORKER_PANES_LIST; do
  tmux copy-mode -q -t "${SESSION_NAME}:${TARGET_WIN}.${i}" 2>/dev/null
  tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "clear" Enter 2>/dev/null
done; sleep 1
for i in $WORKER_PANES_LIST; do
  WORKER_PROMPT=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1 || true)
  CMD="cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus --name \"T${TARGET_WIN} W${i}\""
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "${SESSION_NAME}:${TARGET_WIN}.${i}" "$CMD" Enter; sleep 0.5
done
```

## Step 9: Rename window, verify boot (25s max)
```bash
[ "$BACK_MODE" = "true" ] && tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN}" || tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN} [worktree]"
for attempt in 1 2 3 4 5; do
  NOT_READY=0; DOWN_PANES=""
  for i in $WORKER_PANES_LIST; do
    OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p 2>/dev/null)
    echo "$OUTPUT" | grep -q "bypass permissions" || { NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${TARGET_WIN}.$i"; }
  done
  [ "$NOT_READY" -eq 0 ] && break; sleep 5
done
```

## Step 10: Report
Output: mode (isolate/return), window, branch, directory, booted/failed count.

### Rules
- Never transform window 0. Kill by PID only (SIGTERM → SIGKILL). No `eval`/`source` on team env.
- Atomic writes (temp file + mv). Copy `.claude/settings.local.json` to worktrees.
- Branch preserved on `--back` — user merges manually. Bash 3.2 compatible.
