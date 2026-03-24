---
name: doey-rd-team
description: Spawn a Doey R&D team — audits, develops, and tests Doey itself in a worktree-isolated window. Use when you need to "start a doey development team", "audit and improve doey", or "spawn an R&D team".
---

## Usage
`/doey-rd-team` — spawn full R&D team (audit + dev workers)
`/doey-rd-team audit` — audit only (no dev workers, just scanning)

## Context

- Session config: !`cat /tmp/doey/*/session.env 2>/dev/null | head -20 || true`
- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`

## Prompt

Spawn a Doey R&D team in a git worktree of `~/Documents/github/doey`. **Do NOT ask for confirmation.** Live session files are READ-ONLY.

### Step 1: Resolve Doey repo and create worktree

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

DOEY_REPO="$HOME/Documents/github/doey"
[ ! -d "$DOEY_REPO/.git" ] && { echo "ERROR: Doey repo not found at $DOEY_REPO"; exit 1; }

# Create worktree for isolated development
WT_BRANCH="doey/rd-$(date +%m%d-%H%M)"
WT_DIR="/tmp/doey/${PROJECT_NAME}/worktrees/rd-$(date +%m%d-%H%M)"
mkdir -p "$(dirname "$WT_DIR")"

if ! git -C "$DOEY_REPO" worktree add "$WT_DIR" -b "$WT_BRANCH" 2>&1; then
  echo "ERROR: Failed to create worktree"
  exit 1
fi
echo "Worktree created: $WT_DIR (branch: $WT_BRANCH)"

# Copy gitignored config if present
[ -f "${DOEY_REPO}/.claude/settings.local.json" ] && mkdir -p "${WT_DIR}/.claude" && cp "${DOEY_REPO}/.claude/settings.local.json" "${WT_DIR}/.claude/settings.local.json"
```

### Step 2: Create new tmux window with dynamic grid

Use a dynamic grid: 3 columns × 2 rows = 6 workers + 1 manager = 7 panes.

```bash
GRID="dynamic"; TOTAL=7; WORKER_COUNT=6

tmux new-window -t "$SESSION_NAME" -n "RD" -c "$WT_DIR"
sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

# Add 3 columns (each: split-h from last pane, then split-v the new pane)
for _col in 1 2 3; do
  last_pane="$(tmux list-panes -t "$SESSION_NAME:$NEW_WIN" -F '#{pane_index}' | tail -1)"
  tmux split-window -h -t "$SESSION_NAME:$NEW_WIN.${last_pane}" -c "$WT_DIR"
  sleep 0.1
  new_pane_top="$(tmux list-panes -t "$SESSION_NAME:$NEW_WIN" -F '#{pane_index}' | tail -1)"
  tmux split-window -v -t "$SESSION_NAME:$NEW_WIN.${new_pane_top}" -c "$WT_DIR"
  sleep 0.1
done
sleep 0.3

# Name panes
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "RD Manager"
WORKER_PANES_LIST=""
for i in $(seq 1 $WORKER_COUNT); do
  tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -T "RD W${i}"
  [ -n "$WORKER_PANES_LIST" ] && WORKER_PANES_LIST="${WORKER_PANES_LIST},${i}" || WORKER_PANES_LIST="${i}"
done
```

### Step 3: Write team env

```bash
TEAM_FILE="${RUNTIME_DIR}/team_${NEW_WIN}.env"
cat > "${TEAM_FILE}.tmp" << TEAM_EOF
SESSION_NAME=${SESSION_NAME}
PROJECT_DIR=${WT_DIR}
PROJECT_NAME=${PROJECT_NAME}
WINDOW_INDEX=${NEW_WIN}
GRID=${GRID}
TOTAL_PANES=${TOTAL}
MANAGER_PANE=0
WORKER_PANES=${WORKER_PANES_LIST}
WORKER_COUNT=${WORKER_COUNT}
WATCHDOG_PANE=""
WORKTREE_DIR="${WT_DIR}"
WORKTREE_BRANCH="${WT_BRANCH}"
DOEY_REPO="${DOEY_REPO}"
RD_TEAM=true
TEAM_EOF
mv "${TEAM_FILE}.tmp" "$TEAM_FILE"

# Append to TEAM_WINDOWS
CURRENT_WINDOWS=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
[ -n "$CURRENT_WINDOWS" ] && NEW_WINDOWS="${CURRENT_WINDOWS},${NEW_WIN}" || NEW_WINDOWS="${NEW_WIN}"
TMPENV=$(mktemp "${RUNTIME_DIR}/session.env.tmp_XXXXXX")
if grep -q '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env"; then
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=${NEW_WINDOWS}/" "${RUNTIME_DIR}/session.env" > "$TMPENV"
else
  cat "${RUNTIME_DIR}/session.env" > "$TMPENV"
  echo "TEAM_WINDOWS=${NEW_WINDOWS}" >> "$TMPENV"
fi
mv "$TMPENV" "${RUNTIME_DIR}/session.env"
```

### Step 4: Write R&D worker system prompt

```bash
RD_PROMPT="${RUNTIME_DIR}/rd-worker-prompt.md"
cat > "$RD_PROMPT" << 'RDPROMPT'
# Doey R&D Worker

You are in a **git worktree** — an isolated copy of the Doey codebase.

## Rules
1. Changes do NOT affect the running session. Never run `doey` commands here.
2. Commit frequently: `fix(shell): <desc>`, `feat(skill): <desc>`, `test: <desc>`.
3. Stay inside the worktree directory. No remote push without approval.

## Audit format
`[SEVERITY] file:line — description` (CRITICAL > HIGH > MEDIUM > LOW)

## Dev workflow
Read → understand context → minimal fix → descriptive commit → verify (`bash -n doey.sh`)
RDPROMPT
```

### Step 5: Launch Claude instances

```bash
# Manager
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" \
  "claude --dangerously-skip-permissions --model opus --name \"RD Manager\" --agent \"t${NEW_WIN}-manager\"" Enter
sleep 1

# Workers — all get the R&D prompt extension
for i in $(seq 1 $WORKER_COUNT); do
  tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" \
    "claude --dangerously-skip-permissions --model opus --name \"RD W${i}\" --append-system-prompt-file \"${RD_PROMPT}\"" Enter
  sleep 0.5
done

# Watchdog — find free slot via session.env WDG_SLOT entries
WDG_SLOT=""
for _sn in 1 2 3 4 5 6; do
  _slot_val=$(grep "^WDG_SLOT_${_sn}=" "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
  [ -n "$_slot_val" ] || continue
  _in_use=false
  for _tf in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$_tf" ] || continue
    _tf_wdg=$(grep '^WATCHDOG_PANE=' "$_tf" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ "$_tf_wdg" = "$_slot_val" ] && { _in_use=true; break; }
  done
  [ "$_in_use" = "false" ] && { WDG_SLOT="$_slot_val"; break; }
done

# If no free slot, create new one
if [ -z "$WDG_SLOT" ]; then
  _slot_count=$(grep -c '^WDG_SLOT_[0-9]*=' "${RUNTIME_DIR}/session.env" 2>/dev/null || echo 0)
  if [ "$_slot_count" -lt 6 ]; then
    _last_wdg_slot=$(grep '^WDG_SLOT_[0-9]*=' "${RUNTIME_DIR}/session.env" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"')
    tmux split-window -h -t "${SESSION_NAME}:${_last_wdg_slot}" -c "$WT_DIR"
    sleep 0.3
    _new_slot_num=$((_slot_count + 1))
    WDG_SLOT="0.$((_new_slot_num + 1))"
    echo "WDG_SLOT_${_new_slot_num}=\"${WDG_SLOT}\"" >> "${RUNTIME_DIR}/session.env"
  fi
fi

# Launch watchdog and update team env
if [ -n "$WDG_SLOT" ]; then
  tmux select-pane -t "${SESSION_NAME}:${WDG_SLOT}" -T "RD Watchdog"
  tmux send-keys -t "${SESSION_NAME}:${WDG_SLOT}" \
    "claude --dangerously-skip-permissions --model haiku --name \"RD Watchdog\" --agent \"t${NEW_WIN}-watchdog\"" Enter
  sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=${WDG_SLOT}/" "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp"
  mv "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" "${RUNTIME_DIR}/team_${NEW_WIN}.env"
fi
```

### Step 6: Verify boot and dispatch audit

```bash
sleep 8
NOT_READY=0; DOWN_PANES=""
for i in 0 $(seq 1 $WORKER_COUNT); do
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"
  fi
done
[ "$NOT_READY" -eq 0 ] && echo "All panes booted" || echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"
```

Dispatch audit task to Manager via load-buffer:

```bash
MGR_PANE="${SESSION_NAME}:${NEW_WIN}.0"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << 'AUDIT_TASK'
Run a full Doey R&D audit. You are in a worktree — safe to read and edit.

Phase 1 — dispatch 6 workers in parallel:
- W1: shell/doey.sh — bugs, dead code, portability. Format: [SEVERITY] line:N — description
- W2: agents/*.md — frontmatter, setup blocks, model choices
- W3: .claude/skills/doey-*/ — bash correctness, variable sourcing, macOS compat
- W4: .claude/hooks/* — race conditions, file locking, error handling
- W5: README.md, CLAUDE.md, docs/ — cross-reference claims vs code
- W6: Validation — bash -n doey.sh, frontmatter checks, tests/

Phase 2: Consolidate, prioritize, assign fixes (one per worker, separate commits).
Phase 3: Verify bash -n, no regressions, report to Session Manager.
AUDIT_TASK

tmux copy-mode -q -t "$MGR_PANE" 2>/dev/null
tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$MGR_PANE"
sleep 1
tmux send-keys -t "$MGR_PANE" Enter
rm "$TASKFILE"
```

### Step 7: Report

Output: window number, worktree path + branch, pane layout, boot status. Include merge protocol:
`cd ~/Documents/github/doey && git merge ${WT_BRANCH}` → `/doey-reinstall` → `/doey-kill-window ${NEW_WIN}`

### Rules

- Always worktree the DOEY REPO, not the current project
- Pane 0 = Manager, 1-6 = Workers, Watchdog in Dashboard. Window named "RD"
- Team env includes `RD_TEAM=true` and `DOEY_REPO`
- Never hardcode window indices. Bash 3.2 compatible.
