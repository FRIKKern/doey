---
name: doey-worktree
description: Isolate a team window in a git worktree, or return it.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Teams: !`for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done || true`
- Statuses: !`W=$(tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-); for f in $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/status/*_${W}_*.status; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done 2>/dev/null || true`

`/doey-worktree [W]` (isolate) | `[W] --back` (return). **No confirmation.**

### 1. Parse + validate
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
TARGET_WIN="${DOEY_WINDOW_INDEX:-1}"; BACK_MODE=false  # parse --back from args
[ "$TARGET_WIN" = "0" ] && { echo "ERROR: Cannot transform Dashboard"; exit 1; }
TEAM_ENV="${RD}/team_${TARGET_WIN}.env"
[ ! -f "$TEAM_ENV" ] && { echo "ERROR: No team env for window ${TARGET_WIN}"; exit 1; }
SESSION_NAME=$(grep '^SESSION_NAME=' "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | grep -qx "$TARGET_WIN" || { echo "ERROR: Window ${TARGET_WIN} not found"; exit 1; }
```

### 2. Load config, reject busy workers
```bash
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
PROJECT_NAME=$(grep '^PROJECT_NAME=' "${RD}/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
_tv() { grep "^$1=" "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }
WORKER_PANES=$(_tv WORKER_PANES); WORKTREE_DIR=$(_tv WORKTREE_DIR); WORKTREE_BRANCH=$(_tv WORKTREE_BRANCH)
WPL=$(echo "$WORKER_PANES" | tr ',' ' '); SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':.-' '_')
BUSY=""
for i in $WPL; do
  SF="${RD}/status/${SESSION_SAFE}_${TARGET_WIN}_${i}.status"
  [ -f "$SF" ] && grep -q '^STATUS: *BUSY' "$SF" && BUSY="$BUSY ${TARGET_WIN}.${i}"
done
[ -n "$BUSY" ] && { echo "ERROR: Busy workers:${BUSY} — wait or /doey-stop first"; exit 1; }
# Validate mode vs state
if [ "$BACK_MODE" = "true" ]; then [ -z "$WORKTREE_DIR" ] && { echo "ERROR: Not in a worktree"; exit 1; }
else [ -n "$WORKTREE_DIR" ] && { echo "ERROR: Already in worktree — use --back first"; exit 1; }; fi
```

### 3a. Create worktree (forward)
```bash
BRANCH="doey/team-${TARGET_WIN}-$(date +%m%d-%H%M)"
WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/team-${TARGET_WIN}"
if [ -d "$WT_DIR" ]; then
  if git -C "$WT_DIR" status --porcelain 2>/dev/null | grep -q '^'; then
    echo "ERROR: Worktree $WT_DIR has uncommitted changes. Commit or stash first."
    exit 1
  fi
  git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true
fi
mkdir -p "/tmp/doey/${PROJECT_NAME}/worktrees"
WT_OUTPUT=$(git -C "$PROJECT_DIR" worktree add "$WT_DIR" -b "$BRANCH" 2>&1) || { echo "ERROR: $WT_OUTPUT"; exit 1; }
[ -f "${PROJECT_DIR}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${PROJECT_DIR}/.claude/settings.local.json" "${WT_DIR}/.claude/"
TMPENV=$(mktemp "${RD}/team_${TARGET_WIN}.env.tmp_XXXXXX")
cat "$TEAM_ENV" > "$TMPENV"; printf 'WORKTREE_DIR=%s\nWORKTREE_BRANCH=%s\n' "$WT_DIR" "$BRANCH" >> "$TMPENV"
mv "$TMPENV" "$TEAM_ENV"; TARGET_DIR="$WT_DIR"
echo "export DOEY_ALLOW_AGENT_WORKTREE=1" >> "$TEAM_ENV"
```

### 3b. Remove worktree (auto-commit dirty, log, remove, strip env)
```bash
DIRTY=$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
  # Write auto-save audit log
  AUTO_SAVE_DIR="${RD}/auto-saves"
  mkdir -p "$AUTO_SAVE_DIR"
  WT_BRANCH=$(git -C "$WORKTREE_DIR" branch --show-current 2>/dev/null || echo "unknown")
  {
    printf 'AUTO-SAVE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'WORKTREE: %s\n' "$WORKTREE_DIR"
    printf 'BRANCH: %s\n' "$WT_BRANCH"
    printf 'FILES:\n'
    git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null || true
  } > "${AUTO_SAVE_DIR}/${WT_BRANCH}_$(date +%s).log" 2>/dev/null || true
  git -C "$WORKTREE_DIR" add -A && git -C "$WORKTREE_DIR" commit -m "doey: WIP from team ${TARGET_WIN} worktree"
fi
echo "Commits on branch ${WORKTREE_BRANCH}:"
git -C "$WORKTREE_DIR" log --oneline "$(git -C "$PROJECT_DIR" rev-parse HEAD)..HEAD" 2>/dev/null || echo "  (none)"
git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>&1 || echo "WARNING: Manual removal needed"
TMPENV=$(mktemp "${RD}/team_${TARGET_WIN}.env.tmp_XXXXXX")
grep -v '^WORKTREE_DIR=\|^WORKTREE_BRANCH=' "$TEAM_ENV" > "$TMPENV"; mv "$TMPENV" "$TEAM_ENV"
TARGET_DIR="$PROJECT_DIR"
```

### 4. Kill workers → relaunch in TARGET_DIR
```bash
for i in $WPL; do
  CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
done; sleep 3
for i in $WPL; do
  CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
  [ -n "$CHILD" ] && kill -9 "$CHILD" 2>/dev/null
done; sleep 1
for i in $WPL; do
  tmux copy-mode -q -t "${SESSION_NAME}:${TARGET_WIN}.${i}" 2>/dev/null
  source "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
  doey_send_command "${SESSION_NAME}:${TARGET_WIN}.${i}" "clear"
done; sleep 1
for i in $WPL; do
  WP=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RD}/worker-system-prompt-"*.md 2>/dev/null | head -1 || true)
  CMD="cd \"${TARGET_DIR}\" && claude --dangerously-skip-permissions --model opus --name \"T${TARGET_WIN} W${i}\""
  [ -n "$WP" ] && CMD="${CMD} --append-system-prompt-file \"${WP}\""
  doey_send_command "${SESSION_NAME}:${TARGET_WIN}.${i}" "$CMD"; sleep 0.5
done
```

### 5. Rename window + verify boot (25s max)
```bash
[ "$BACK_MODE" = "true" ] && tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN}" || tmux rename-window -t "${SESSION_NAME}:${TARGET_WIN}" "T${TARGET_WIN} [worktree]"
for attempt in 1 2 3 4 5; do
  NOT_READY=0; DOWN=""
  for i in $WPL; do
    tmux capture-pane -t "${SESSION_NAME}:${TARGET_WIN}.${i}" -p 2>/dev/null | grep -q "bypass permissions" || { NOT_READY=$((NOT_READY + 1)); DOWN="$DOWN ${TARGET_WIN}.$i"; }
  done
  [ "$NOT_READY" -eq 0 ] && break; sleep 5
done
```

Output: mode, window, branch, directory, boot count. Never transform window 0.
