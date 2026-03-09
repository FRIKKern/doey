# Skill: tmux-dispatch

Send a task to one or more idle worker panes reliably. This is the primary dispatch primitive for the TMUX Manager.

## Usage
`/tmux-dispatch`

## Prompt
You are dispatching tasks to Claude Code worker instances in TMUX panes.

### Read Project Context

**Before dispatching any tasks**, read the session manifest to get project info and session config:

```bash
source /tmp/claude-team/session.env
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
source /tmp/claude-team/session.env

# 1. Rename the worker pane so the task is visible at a glance
tmux send-keys -t "${SESSION_NAME}:0.X" "/rename short-task-name" Enter
sleep 1

# 2. Ensure temp dir exists
mkdir -p /tmp/claude-team

# 3. Write task to temp file (avoids escaping issues)
TASKFILE=$(mktemp /tmp/claude-team/task_XXXXXX.txt)
cat > "$TASKFILE" << TASK
You are a worker on the Claude Team for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
Multi-line is fine.
TASK

# 4. Load into tmux buffer and paste into target pane
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "${SESSION_NAME}:0.X"

# 5. CRITICAL: sleep then bare Enter — this is what actually submits
sleep 0.5
tmux send-keys -t "${SESSION_NAME}:0.X" Enter

# 6. Cleanup
rm "$TASKFILE"
```

The `/rename` sets the pane border title so you can see what each worker is doing (e.g., "bokmål-priority", "git-commits") instead of generic "Claude Code".

### Pre-flight: Check if worker is idle

**Always check before dispatching.** A worker is idle when its last few lines show the `❯` or `>` prompt:

```bash
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -3
```

Look for `❯` prompt at the end. If you see `thinking`, `working`, or active tool output — the worker is busy. Do NOT send tasks to busy workers.

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

Each Bash call should contain the full dispatch sequence for one worker (including `/rename`):

```bash
# Worker A — all in one Bash call
source /tmp/claude-team/session.env
tmux send-keys -t "${SESSION_NAME}:0.2" "/rename task-a-name" Enter
sleep 1
mkdir -p /tmp/claude-team
TASKFILE=$(mktemp /tmp/claude-team/task_XXXXXX.txt)
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
source /tmp/claude-team/session.env
tmux send-keys -t "${SESSION_NAME}:0.3" "/rename task-b-name" Enter
sleep 1
mkdir -p /tmp/claude-team
TASKFILE=$(mktemp /tmp/claude-team/task_XXXXXX.txt)
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

For very short, simple tasks you can skip the temp file:

```bash
tmux send-keys -t "${SESSION_NAME}:0.X" "Your short task here" Enter
```

This works because `send-keys` with a non-empty string + Enter is reliable. The bug only affects `"" Enter` (empty string before Enter).

### Rules

1. **Never use `send-keys "" Enter`** — the empty string swallows the Enter keystroke
2. **Always `sleep 0.5`** between `paste-buffer` and `send-keys Enter`
3. **Always check idle first** — don't interrupt a working pane
4. **Always verify after dispatch** — confirm the worker started processing
5. **Never touch pane 0.1** — that's the Watchdog
6. **Workers are 0.2 through 0.11** — 10 workers max
7. **Always include project context in every task prompt** — workers need to know the project name, directory, and that paths should be absolute
8. **Read the manifest first** — `source /tmp/claude-team/session.env` before dispatching

### Troubleshooting

If a task doesn't start after dispatch:
1. Check if the text was pasted: `tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -10`
2. If text is there but not submitted: `tmux send-keys -t "${SESSION_NAME}:0.X" Enter`
3. If text is garbled: the pane might have been busy. Wait for idle, then retry.
