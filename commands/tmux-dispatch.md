# Skill: tmux-dispatch

Send a task to one or more idle worker panes reliably. This is the primary dispatch primitive for the TMUX Manager.

## Usage
`/tmux-dispatch`

## Prompt
You are dispatching tasks to Claude Code worker instances in TMUX panes.

### Read Project Context

**Before dispatching any tasks**, discover the runtime directory and read the session manifest:

```bash
RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This gives you:
- `SESSION_NAME` — tmux session name (use instead of hardcoded "claude-team")
- `PROJECT_DIR` — absolute path to the project directory
- `PROJECT_NAME` — human-readable project name
- `WORKER_PANES` — list of worker pane IDs
- `WATCHDOG_PANE` — the watchdog pane ID

**Always use `${SESSION_NAME}` in all tmux commands** — never hardcode "claude-team".

### Reliable Dispatch Function

**ALWAYS use this exact pattern.** Never use `send-keys "" Enter` — it is broken.

```bash
# 0. Load session config
RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# 1. Kill the current Claude process by PID (reliable — /exit is not)
PANE_PID=$(tmux display-message -t "${SESSION_NAME}:0.X" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3

# 2. Verify it died — if not, SIGKILL
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1

# 3. Start a fresh Claude session
tmux send-keys -t "${SESSION_NAME}:0.X" "claude --dangerously-skip-permissions --model opus" Enter

# 4. Wait for Claude to boot
sleep 8

# 5. Rename the worker pane so the task is visible at a glance
tmux send-keys -t "${SESSION_NAME}:0.X" "/rename short-task-name" Enter
sleep 1

# 6. Ensure temp dir exists
mkdir -p "${RUNTIME_DIR}"

# 7. Write task to temp file (avoids escaping issues)
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Claude Team for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
Multi-line is fine.
TASK

# 8. Load into tmux buffer and paste into target pane
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "${SESSION_NAME}:0.X"

# 9. CRITICAL: sleep then bare Enter — this is what actually submits
sleep 0.5
tmux send-keys -t "${SESSION_NAME}:0.X" Enter

# 10. Cleanup
rm "$TASKFILE"
```

Each dispatch starts a fresh Claude session. The old session is exited first to ensure clean context and no stale state from previous tasks.

### Pre-flight: Check if worker is idle

**Always check before dispatching.** A worker is idle when its last few lines show the `❯` or `>` prompt:

```bash
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -3
```

Look for `❯` prompt at the end. If you see `thinking`, `working`, or active tool output — the worker is busy. Do NOT send tasks to busy workers.

If the worker is idle, it still has an old session. The dispatch handles exiting and restarting automatically.

### Post-flight: Verify task was received

After dispatching, wait 5 seconds and verify the worker started processing:

```bash
sleep 5
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -5
```

You should see the pasted text and/or the worker beginning to process. If you still see just the idle prompt with your pasted text but no processing, the Enter didn't fire — send it again:

```bash
tmux send-keys -t "${SESSION_NAME}:0.X" Enter
```

### Batch Dispatch (multiple workers)

For independent tasks, dispatch to multiple workers in a single message. Use separate Bash calls per worker — do NOT chain them with `&&` since they are independent.

Each Bash call should contain the full dispatch sequence for one worker (exit, fresh start, `/rename`):

```bash
# Worker A — all in one Bash call
RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
PANE_PID=$(tmux display-message -t "${SESSION_NAME}:0.2" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3
tmux send-keys -t "${SESSION_NAME}:0.2" "claude --dangerously-skip-permissions --model opus" Enter
sleep 8
tmux send-keys -t "${SESSION_NAME}:0.2" "/rename task-a-name" Enter
sleep 1
mkdir -p "${RUNTIME_DIR}"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Claude Team for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

... task for worker A ...
TASK
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "${SESSION_NAME}:0.2"
sleep 0.5
tmux send-keys -t "${SESSION_NAME}:0.2" Enter
rm "$TASKFILE"
```

```bash
# Worker B — separate Bash call, runs in parallel
RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
PANE_PID=$(tmux display-message -t "${SESSION_NAME}:0.3" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3
tmux send-keys -t "${SESSION_NAME}:0.3" "claude --dangerously-skip-permissions --model opus" Enter
sleep 8
tmux send-keys -t "${SESSION_NAME}:0.3" "/rename task-b-name" Enter
sleep 1
mkdir -p "${RUNTIME_DIR}"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Claude Team for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

... task for worker B ...
TASK
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "${SESSION_NAME}:0.3"
sleep 0.5
tmux send-keys -t "${SESSION_NAME}:0.3" Enter
rm "$TASKFILE"
```

### Short tasks (< 200 chars, no special chars)

Even short tasks need a fresh Claude session. Exit and restart before dispatching:

```bash
RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
PANE_PID=$(tmux display-message -t "${SESSION_NAME}:0.X" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3
tmux send-keys -t "${SESSION_NAME}:0.X" "claude --dangerously-skip-permissions --model opus" Enter
sleep 8
tmux send-keys -t "${SESSION_NAME}:0.X" "Your short task here" Enter
```

This ensures every task — even short ones — gets a clean context with no stale state.

### Rules

1. **Never use `send-keys "" Enter`** — the empty string swallows the Enter keystroke
2. **Always `sleep 0.5`** between `paste-buffer` and `send-keys Enter`
3. **Always check idle first** — don't interrupt a working pane
4. **Always verify after dispatch** — confirm the worker started processing
5. **Never touch the Watchdog pane** — its index is in the manifest as `WATCHDOG_PANE`
6. **Worker pane indices are in the manifest** as `WORKER_PANES` — always read from manifest, never hardcode
7. **Always include project context in every task prompt** — workers need to know the project name, directory, and that paths should be absolute
8. **Read the manifest first** — discover runtime dir and source session.env before dispatching
9. **Always exit the old session before dispatching** — every task gets a fresh Claude context

### Troubleshooting

If a task doesn't start after dispatch:
1. Check if the text was pasted: `tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -10`
2. If text is there but not submitted: `tmux send-keys -t "${SESSION_NAME}:0.X" Enter`
3. If text is garbled: the pane might have been busy. Wait for idle, then retry.
