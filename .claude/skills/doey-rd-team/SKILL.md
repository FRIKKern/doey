---
name: doey-rd-team
description: Spawn a Doey R&D product team — Brain, Platform Expert, Claude Expert, Critic. Works on the live codebase so it sees all changes in real time.
---

## Usage
`/doey-rd-team` — spawn full R&D product team (audit + improve)
`/doey-rd-team audit` — audit only (read, don't fix)

## Context

- Session config: !`cat /tmp/doey/*/session.env 2>/dev/null | head -20 || true`
- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`

## Prompt

Spawn the Doey R&D Product Team on the **live project directory**. No worktree — the team sees all changes in real time. **Do NOT ask for confirmation.**

### Step 1: Load session

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
echo "Project: $PROJECT_DIR (branch: $(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null))"
```

### Step 2: Create new tmux window with 2×2 grid

Brain + 3 specialists = 4 panes.

```bash
GRID="dynamic"; TOTAL=4; WORKER_COUNT=3

tmux new-window -t "$SESSION_NAME" -n "RD" -c "$PROJECT_DIR"
sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

# 2×2 grid: split horizontally, then split each half vertically
tmux split-window -h -t "$SESSION_NAME:$NEW_WIN.0" -c "$PROJECT_DIR"
sleep 0.1
tmux split-window -v -t "$SESSION_NAME:$NEW_WIN.0" -c "$PROJECT_DIR"
sleep 0.1
tmux split-window -v -t "$SESSION_NAME:$NEW_WIN.1" -c "$PROJECT_DIR"
sleep 0.3

# Name panes
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.0" -T "Brain"
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.1" -T "Platform"
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.2" -T "Claude"
tmux select-pane -t "${SESSION_NAME}:${NEW_WIN}.3" -T "Critic"
WORKER_PANES_LIST="1,2,3"
```

### Step 3: Write team env

```bash
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
WATCHDOG_PANE=""
WORKTREE_DIR=""
WORKTREE_BRANCH=""
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
# Doey R&D Product Team Member

You are working on the **live project directory** — the same codebase other teams are editing.

## Rules
1. Coordinate edits carefully — other workers may be editing files concurrently.
2. Read the error log at $RUNTIME_DIR/errors/errors.log for live runtime issues.
3. Check `git diff` and `git log` to see what other teams have changed recently.
4. No remote push without approval from the Brain.

## Specialists
Each team member has a specialized agent defining their domain expertise and review criteria.

## Dev workflow
Read current state → check recent changes → analyze in your domain → propose or fix → verify (`bash -n` for .sh files)

## Error logs
The live error log at `$RUNTIME_DIR/errors/errors.log` contains runtime errors from the current session.
Format: `[timestamp] CATEGORY | pane_id | role | hook | tool | detail | message`
Categories: TOOL_BLOCKED, LINT_ERROR, ANOMALY, HOOK_ERROR, DELIVERY_FAILED
RDPROMPT
```

### Step 5: Launch Claude instances

Use 3s stagger to prevent auth session exhaustion.

```bash
# Brain (pane 0)
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" \
  "claude --dangerously-skip-permissions --model opus --name \"Brain\" --agent \"doey-product-brain\"" Enter
sleep 3

# Platform Expert (pane 1)
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.1" \
  "claude --dangerously-skip-permissions --model opus --name \"Platform\" --agent \"doey-platform-expert\" --append-system-prompt-file \"${RD_PROMPT}\"" Enter
sleep 3

# Claude Expert (pane 2)
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.2" \
  "claude --dangerously-skip-permissions --model opus --name \"Claude\" --agent \"doey-claude-expert\" --append-system-prompt-file \"${RD_PROMPT}\"" Enter
sleep 3

# Critic (pane 3)
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.3" \
  "claude --dangerously-skip-permissions --model opus --name \"Critic\" --agent \"doey-critic\" --append-system-prompt-file \"${RD_PROMPT}\"" Enter
sleep 1

# RD teams are short-lived and human-directed.
# The Brain coordinates specialists directly.
```

### Step 6: Verify boot and dispatch audit

```bash
sleep 8
NOT_READY=0; DOWN_PANES=""
for i in 0 1 2 3; do
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"
  fi
done
if [ "$NOT_READY" -eq 0 ]; then echo "All panes booted"; else echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"; fi
```

Dispatch audit task to Brain via load-buffer:

```bash
MGR_PANE="${SESSION_NAME}:${NEW_WIN}.0"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << 'AUDIT_TASK'
Run a Doey R&D audit on the live codebase. You can read everything, and see real-time changes from other teams.

You have 3 specialist workers:
- Pane 1 (Platform Expert): tmux internals, bash 3.2 portability, shell scripts, race conditions
- Pane 2 (Claude Expert): hooks (lifecycle, exit codes, ordering), agents, skills, settings overlays
- Pane 3 (Critic): regression checks, output quality validation, before/after comparison

Phase 1 — dispatch specialists in parallel:
- Platform Expert (pane 1): audit shell/doey.sh, shell/*.sh, .claude/hooks/* for tmux races, bash 3.2 violations, portability issues
- Claude Expert (pane 2): audit .claude/hooks/* (hook semantics, exit codes), agents/*.md, .claude/skills/doey-*/ for correctness
- Critic (pane 3): run bash -n on all .sh files, validate agent frontmatter, run tests/, check docs/ vs code accuracy

Check the live error log at /tmp/doey/*/errors/errors.log for runtime issues:
Platform Expert focuses on tmux/bash errors, Claude Expert on hook/agent errors.
Critic validates the error categorization and proposes product fixes.

Also check `git log --oneline -10` and `git diff` to see what other teams are working on right now.

Phase 2: Consolidate findings. Each specialist proposes fixes in their domain. Critic reviews all proposals.
Phase 3: Implement fixes (one specialist per file, separate commits). Critic runs regression checks. Report to Session Manager.
AUDIT_TASK

tmux copy-mode -q -t "$MGR_PANE" 2>/dev/null
tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$MGR_PANE"
sleep 1
tmux send-keys -t "$MGR_PANE" Enter
rm "$TASKFILE"
```

### Step 7: Report

Output: window number, project dir, pane layout, boot status. Include teardown command: `/doey-kill-window ${NEW_WIN}`

### Rules

- Work on the LIVE project directory, not a worktree — the team needs to see real-time changes
- Pane 0 = Brain, 1 = Platform Expert, 2 = Claude Expert, 3 = Critic. Reports to SM, SM reports to Boss. Window named "RD"
- Team env includes `RD_TEAM=true`
- 3s stagger between Claude launches to prevent auth exhaustion
- Never hardcode window indices. Bash 3.2 compatible.
