# Skill: doey-dispatch

Primary dispatch primitive — send tasks to idle worker panes.

## Usage
`/doey-dispatch`

## Prompt

You are dispatching tasks to Claude Code worker instances in tmux panes.

### Step 1: Get project context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
echo "PROJECT_NAME=$PROJECT_NAME"
echo "PROJECT_DIR=$PROJECT_DIR"
```

You need PROJECT_NAME and PROJECT_DIR for crafting task prompts.

### Step 2: Auto-scale (dynamic grid)

Before scanning for idle workers, check if we need to expand:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
if [ "$(grep '^GRID=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)" = "dynamic" ]; then
  IDLE_COUNT=$(doey status 2>/dev/null | grep -c "IDLE" || true)
  if [ "$IDLE_COUNT" -eq 0 ]; then
    doey add 2>/dev/null; sleep 10
  fi
fi
```

### Step 3: Find idle worker

Run `doey status` to see all workers, their state, and reservations:

```bash
doey status
```

Pick an idle, unreserved worker pane (e.g. `1.3`). If all workers are busy or reserved, report and wait. **Never dispatch to RESERVED panes.**

### Step 4: Craft task prompt

Build a self-contained task prompt. Every task prompt MUST include:
- Worker identity: "You are a worker on Doey for project: PROJECT_NAME"
- Project dir: "Project directory: PROJECT_DIR"
- "All file paths should be absolute."
- Detailed instructions

### Step 5: Dispatch

Rename the pane, then use `doey dispatch`:

```bash
# Rename first (mandatory for traceability)
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" "/rename task-name_$(date +%m%d)" Enter
sleep 1

# Dispatch the task
doey dispatch "Your full task prompt here" ${WINDOW_INDEX}.X
```

The CLI handles: tmpfile creation, load-buffer/paste-buffer, settle timing, Enter, 5s verification, cleanup. It reports success or warning.

### Variants

**Batch:** Dispatch to multiple workers using parallel Bash calls. Each call: rename + `doey dispatch`.

**Short tasks (< 200 chars):** Same flow — `doey dispatch` handles both long and short.

### File Conflicts

Assign explicit file ownership per worker. Shared files: non-overlapping sections, Edit only. Overlapping edits: dispatch sequentially.

### Unstick

If dispatch fails or worker is stuck:

`copy-mode -q` → `C-c` → `C-u` → `Enter`, wait 3s. After 2 fails: kill child process, relaunch Claude with system prompt, wait 8s, re-dispatch.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" C-c
sleep 0.5
tmux send-keys -t "$PANE" C-u
sleep 0.5
tmux send-keys -t "$PANE" Enter
```

Wait for ❯ prompt, then re-dispatch. If still stuck after 2 attempts:

```bash
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; sleep 3
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1
PANE_IDX="${PANE##*.}"
WORKER_PROMPT=$(grep -l "pane ${WINDOW_INDEX}\.${PANE_IDX} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
if [ -n "$WORKER_PROMPT" ]; then
  tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
else
  tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter
fi
sleep 8
```

### Rules

1. Never `send-keys "" Enter` — empty string swallows Enter
2. Always rename pane before dispatching
3. Check idle + reservation via `doey status` before dispatching
4. Include `PROJECT_NAME`, `PROJECT_DIR`, absolute paths in every task
5. `doey dispatch` handles verification — check its output
