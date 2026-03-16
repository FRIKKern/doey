# Skill: doey-dispatch

Primary dispatch primitive — send tasks to idle worker panes.

## Usage
`/doey-dispatch`

## Prompt

You are dispatching tasks to Claude Code worker instances in tmux panes.

### Project Context

Every Bash call must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

Provides `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `WINDOW_INDEX`.

**Copy-mode:** Always `tmux copy-mode -q -t "$PANE" 2>/dev/null` before `paste-buffer`/`send-keys` — copy-mode swallows input.

### Auto-scale (dynamic grid, run BEFORE scanning)

```bash
if [ "$(grep '^GRID=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)" = "dynamic" ]; then
  HAS_IDLE=false
  for WIDX in $(echo "$WORKER_PANES" | tr ',' ' '); do
    W_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${WIDX}" | tr ':.' '_')
    [ -f "${RUNTIME_DIR}/status/${W_SAFE}.reserved" ] && continue
    case "$(tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.${WIDX}" -p -S -3 2>/dev/null)" in *'❯'*) HAS_IDLE=true; break ;; esac
  done
  if [ "$HAS_IDLE" = "false" ] && [ "${WORKER_COUNT:-0}" -lt "${MAX_WORKERS:-20}" ]; then
    doey add 2>/dev/null; sleep 10
    source "${RUNTIME_DIR}/session.env"
    [ -f "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" ] && source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  fi
fi
```

### Pre-flight

❯ = idle. **Never dispatch to RESERVED panes.**

```bash
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && echo "Reserved — skip"
tmux copy-mode -q -t "${SESSION_NAME}:${WINDOW_INDEX}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.X" -p -S -3
```

### Dispatch Sequence (never `send-keys "" Enter`)

```bash
# Load env (see Project Context)
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"

# 1. Check if already idle
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
OUTPUT=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
ALREADY_READY=false
[ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯' && ALREADY_READY=true

if [ "$ALREADY_READY" = "false" ]; then
  # 2-3. Kill Claude (SIGTERM→SIGKILL)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1
  # 4-5. Restart Claude with worker system prompt
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  PANE_IDX="${PANE##*.}"
  WORKER_PROMPT=$(grep -l "pane ${WINDOW_INDEX}\.${PANE_IDX} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter
  fi
  # 6-7. Boot wait
  sleep 8; tmux copy-mode -q -t "$PANE" 2>/dev/null
fi

# 8. Rename pane (task + date)
tmux send-keys -t "$PANE" "/rename task-name_$(date +%m%d)" Enter; sleep 1

# 9-10. Write task to temp file
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
TASK

# 11-12. Paste task
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE"; tmux paste-buffer -t "$PANE"

# 13. Settle + submit (>200=2s, >100=1.5s, else 0.5s)
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then SETTLE_S=2
elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then SETTLE_S=1.5
else SETTLE_S=0.5; fi
sleep $SETTLE_S; tmux send-keys -t "$PANE" Enter
rm "$TASKFILE"

# 15. MANDATORY VERIFICATION
sleep 5; OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
if echo "$OUTPUT" | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "✓ Worker ${WINDOW_INDEX}.X started"
else
  tmux copy-mode -q -t "$PANE" 2>/dev/null; tmux send-keys -t "$PANE" Enter; sleep 3
  OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
  if echo "$OUTPUT" | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
    echo "✓ Started after retry"
  else
    echo "✗ FAILED — run unstick sequence"
  fi
fi
```

### Variants

**Batch:** Parallel Bash calls per worker (not `&&`). Skip reserved panes.
**Short tasks (< 200 chars):** Steps 1–8, then `send-keys` directly (skip 9–12). Steps 13–15 mandatory.

### File Conflicts

Assign explicit file ownership per worker. Shared files: non-overlapping sections, Edit only. Overlapping edits: dispatch sequentially.

### Rules

1. Never `send-keys "" Enter` — empty string swallows Enter
2. Always `sleep 0.5` between paste-buffer and Enter
3. Check idle + reservation before dispatching
4. Verify after dispatch (step 15) — mandatory
5. Include `PROJECT_NAME`, `PROJECT_DIR`, absolute paths in every task

### Unstick

`copy-mode -q` → `C-c` → `C-u` → `Enter`, wait 3s. After 2 fails: `kill -9` child, relaunch Claude with system prompt, wait 8s, re-dispatch.
