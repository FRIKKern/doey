---
name: doey-rd-team
description: Spawn a Doey R&D team — audits, develops, and tests Doey itself in a worktree-isolated window.
---

## Usage
`/doey-rd-team` — spawn full R&D team (audit + dev workers)
`/doey-rd-team audit` — audit only (no dev workers, just scanning)

## Context

- Session config: !`cat /tmp/doey/*/session.env 2>/dev/null | head -20 || true`
- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`

## Prompt

Spawn a Doey R&D team window for safely improving Doey itself. **Do NOT ask for confirmation — just do it.**

The team always operates in a **git worktree** of the Doey repo (`~/Documents/github/doey`), never editing live files. The running session's doey.sh, agents, hooks, and skills are READ-ONLY.

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

### Step 2: Create new tmux window with grid

Use a 4x2 grid (7 workers + 1 manager = 8 panes).

```bash
GRID="4x2"; COLS=4; ROWS=2; TOTAL=8; WORKER_COUNT=7

tmux new-window -t "$SESSION_NAME" -n "RD" -c "$WT_DIR"
sleep 0.5
NEW_WIN=$(tmux display-message -t "$SESSION_NAME" -p '#{window_index}')

for _s in $(seq 1 $((TOTAL - 1))); do
  tmux split-window -t "${SESSION_NAME}:${NEW_WIN}" -c "$WT_DIR"
done
tmux select-layout -t "${SESSION_NAME}:${NEW_WIN}" tiled
sleep 0.5

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
WATCHDOG_PANE=
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

Create a system prompt extension for R&D workers with safety rules:

```bash
RD_PROMPT="${RUNTIME_DIR}/rd-worker-prompt.md"
cat > "$RD_PROMPT" << 'RDPROMPT'
# Doey R&D Worker

You are developing on the Doey codebase. You are working in a **git worktree** — an isolated copy.

## Safety Rules (MANDATORY)

1. **You are in a worktree.** Your changes do NOT affect the running Doey session.
2. **Never run `doey` commands** from within the worktree — they could affect the live session.
3. **Commit frequently.** Small, focused commits: `fix(shell): <desc>`, `feat(skill): <desc>`, `test: <desc>`.
4. **Do NOT modify files outside the worktree directory.**
5. **Do NOT push to remote** without explicit approval.

## Doey Architecture

```
shell/doey.sh          — Main script (1455 lines). All shell functions.
agents/                — Agent definitions (manager, session-manager, watchdog, test-driver)
.claude/skills/        — 20 Doey skills (slash commands)
.claude/hooks/         — 13 hooks (pre-tool-use, stop-notify, watchdog-scan, etc.)
install.sh             — Installer script
CLAUDE.md              — Project instructions
```

## Key Functions in doey.sh

- `launch_session()` / `launch_with_grid()` — Session startup
- `setup_dashboard()` — Dashboard window creation
- `install_doey_hooks()` — Copy hooks/skills to project
- `write_team_env()` / `write_worker_system_prompt()` — Runtime config
- `show_menu()` — Interactive project menu
- `check_claude_auth()` — Auth verification

## When Auditing

Report findings as:
```
[SEVERITY] file:line — description
  Current: <problematic code>
  Suggested: <fix>
```

Severity: CRITICAL > HIGH > MEDIUM > LOW

## When Developing

1. Read the issue/finding first
2. Understand the surrounding code
3. Make the minimal fix
4. Commit with descriptive message
5. Verify no regressions (bash -n doey.sh, check related functions)
RDPROMPT
```

### Step 5: Launch Claude instances

```bash
# Manager
tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.0" \
  "claude --dangerously-skip-permissions --model opus --name \"RD Manager\" --agent \"t${NEW_WIN}-manager\"" Enter
sleep 1

# Workers — all get the R&D prompt extension
for i in $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  tmux send-keys -t "${SESSION_NAME}:${NEW_WIN}.${i}" \
    "claude --dangerously-skip-permissions --model opus --name \"RD W${i}\" --append-system-prompt-file \"${RD_PROMPT}\"" Enter
  sleep 0.5
done

# Watchdog — find Dashboard slot
WDG_SLOT=""
for slot in 2 3 4 5 6 7; do
  SLOT_CHILD=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:0.${slot}" -p '#{pane_pid}' 2>/dev/null || echo 0)" 2>/dev/null || true)
  [ -z "$SLOT_CHILD" ] && { WDG_SLOT="$slot"; break; }
done
if [ -n "$WDG_SLOT" ]; then
  tmux select-pane -t "${SESSION_NAME}:0.${WDG_SLOT}" -T "RD Watchdog"
  tmux send-keys -t "${SESSION_NAME}:0.${WDG_SLOT}" \
    "claude --dangerously-skip-permissions --model haiku --name \"RD Watchdog\" --agent \"t${NEW_WIN}-watchdog\"" Enter
  sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=0.${WDG_SLOT}/" "${RUNTIME_DIR}/team_${NEW_WIN}.env" > "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" && mv "${RUNTIME_DIR}/team_${NEW_WIN}.env.tmp" "${RUNTIME_DIR}/team_${NEW_WIN}.env"
fi
```

### Step 6: Verify boot and dispatch audit tasks

```bash
sleep 8
NOT_READY=0; DOWN_PANES=""
for i in 0 $(echo "$WORKER_PANES_LIST" | tr ',' ' '); do
  CHILD_PID=$(pgrep -P "$(tmux display-message -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p '#{pane_pid}')" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "${SESSION_NAME}:${NEW_WIN}.${i}" -p 2>/dev/null)
  if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
    NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${NEW_WIN}.$i"
  fi
done
[ "$NOT_READY" -eq 0 ] && echo "All panes booted" || echo "WARNING: ${NOT_READY} not ready:${DOWN_PANES}"
```

After verification, send the audit task to the Manager. Use the dispatch pattern (load-buffer for long prompts):

```bash
MGR_PANE="${SESSION_NAME}:${NEW_WIN}.0"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << 'AUDIT_TASK'
Run a full Doey R&D audit. You are in a worktree of the Doey repo — safe to read and edit.

Dispatch 6 workers in parallel for Phase 1 (audit):
- W1: Shell script audit — read shell/doey.sh fully. Report bugs, dead code, portability issues, missing error handling. Format: [SEVERITY] line:N — description.
- W2: Agent definition audit — read agents/*.md. Check frontmatter, setup blocks, coordination rules, model choices.
- W3: Skill audit — read .claude/skills/doey-*/ (all 20). Check bash correctness, variable sourcing, tmux commands, macOS compat.
- W4: Hook audit — read .claude/hooks/* (all 13). Check race conditions, file locking, performance, error handling.
- W5: Documentation audit — read README.md, CLAUDE.md, docs/. Cross-reference claims vs code.
- W6: Validation — run bash -n shell/doey.sh, check skill frontmatter, check agent frontmatter, run any tests in tests/.

Phase 2 (after audit): Consolidate findings, prioritize by severity, assign fixes to workers. One fix per worker. Commit each fix separately.

Phase 3 (after fixes): Verify bash -n still passes, no regressions. Report back to Session Manager.
AUDIT_TASK

tmux copy-mode -q -t "$MGR_PANE" 2>/dev/null
tmux load-buffer "$TASKFILE" && tmux paste-buffer -t "$MGR_PANE"
sleep 1
tmux send-keys -t "$MGR_PANE" Enter
rm "$TASKFILE"
```

### Step 7: Report

Output summary:
```
## Doey R&D Team Spawned
- **Window:** ${NEW_WIN} (RD)
- **Worktree:** ${WT_DIR} (branch: ${WT_BRANCH})
- **Doey repo:** ${DOEY_REPO}
- **Manager:** ${NEW_WIN}.0
- **Workers:** ${NEW_WIN}.1-${NEW_WIN}.${WORKER_COUNT}
- **Watchdog:** 0.${WDG_SLOT} (if available)
- **Phase 1:** Full codebase audit dispatched to Manager

### Merge Protocol (after fixes are validated)
1. Commit all local changes on main
2. cd ~/Documents/github/doey && git merge ${WT_BRANCH}
3. /doey-reinstall to apply changes
4. /doey-kill-window ${NEW_WIN} to clean up
```

### Rules

- Always creates a worktree of the DOEY REPO, not the current project
- Workers get R&D-specific system prompt with safety rules
- Manager auto-dispatches Phase 1 audit on boot
- Pane 0 = Manager, 1-7 = Workers, Watchdog in Dashboard
- Window named "RD" for easy identification
- Team env includes `RD_TEAM=true` and `DOEY_REPO` path
- Never hardcode window indices. Bash 3.2 compatible.
