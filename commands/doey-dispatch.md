# Skill: doey-dispatch

Send a task to one or more idle worker panes reliably. This is the primary dispatch primitive for the TMUX Window Manager.

## Usage
`/doey-dispatch`

## Prompt
You are dispatching tasks to Claude Code worker instances in TMUX panes.

### Project Context

Every Bash call that touches tmux must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

This gives you `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `WINDOW_INDEX`. Always use `${SESSION_NAME}` — never hardcode session names.

### Copy-mode pattern

`tmux copy-mode -q -t "$PANE" 2>/dev/null` — exits copy-mode (idempotent, always safe). **Run this before every `paste-buffer` and `send-keys`** throughout the dispatch. Copy-mode silently swallows all input. Used repeatedly in the sequence below without further explanation.

### Auto-scale: Add workers in dynamic grid mode

In dynamic grid mode (`GRID=dynamic`), if no idle unreserved workers exist, auto-add a column. **Run BEFORE scanning for idle workers:**

```bash
GRID_MODE=$(grep '^GRID=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)
if [ "$GRID_MODE" = "dynamic" ]; then
  HAS_IDLE=false
  if [ -n "$WORKER_PANES" ]; then
    for WIDX in $(echo "$WORKER_PANES" | tr ',' ' '); do
      W_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${WIDX}" | tr ':.' '_')
      [ -f "${RUNTIME_DIR}/status/${W_SAFE}.reserved" ] && continue
      W_OUT=$(tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.${WIDX}" -p -S -3 2>/dev/null)
      case "$W_OUT" in *'❯'*) HAS_IDLE=true; break ;; esac
    done
  fi
  if [ "$HAS_IDLE" = "false" ]; then
    if [ "${WORKER_COUNT:-0}" -lt "${MAX_WORKERS:-20}" ]; then
      doey add 2>/dev/null
      sleep 10
      source "${RUNTIME_DIR}/session.env"
    else
      echo "All workers busy and max reached (${MAX_WORKERS:-20}). Queue or wait."
    fi
  fi
fi
```

### Pre-flight: Check worker availability

**Always check before dispatching.** First verify the pane is not reserved, then check if it's idle.

```bash
# Check reservation
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  echo "Pane is reserved — skip this worker, pick another"
fi

# Check idle (look for ❯ prompt; if you see thinking/working/tool output — busy)
tmux copy-mode -q -t "${SESSION_NAME}:${WINDOW_INDEX}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.X" -p -S -3
```

**Never dispatch to a RESERVED pane.** If all workers are reserved, report to the user and wait.

### Reliable Dispatch Sequence

**ALWAYS use this exact pattern.** Never use `send-keys "" Enter` — it is broken.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"

PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"

# 1. Exit copy-mode
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 1b. Readiness check — skip restart if worker is already idle
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
OUTPUT=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
ALREADY_READY=false
if [ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯'; then
  ALREADY_READY=true
fi

if [ "$ALREADY_READY" = "false" ]; then
  # 2. Kill current Claude process by PID
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
  sleep 3

  # 3. Verify it died — SIGKILL if not
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1

  # 4. Exit copy-mode (killing can trigger scroll)
  tmux copy-mode -q -t "$PANE" 2>/dev/null

  # 5. Start fresh Claude (with worker system prompt for identity + rules)
  PANE_IDX="${PANE##*.}"
  WORKER_PROMPT=$(grep -l "pane ${WINDOW_INDEX}\.${PANE_IDX} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter
  fi

  # 6. Wait for boot
  sleep 8

  # 7. Exit copy-mode
  tmux copy-mode -q -t "$PANE" 2>/dev/null
fi

# 8. Rename pane (MANDATORY — task + date for traceability)
tmux send-keys -t "$PANE" "/rename task-name_$(date +%m%d)" Enter
sleep 1

# 9-10. Write task to temp file (avoids escaping issues)
mkdir -p "${RUNTIME_DIR}"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
TASK

# 11. Exit copy-mode before paste
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 12. Load and paste
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "$PANE"

# 13. Settle, then submit (scale by prompt size: >200 lines=2s, >100=1.5s, else 0.5s)
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then SETTLE_S=2
elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then SETTLE_S=1.5
else SETTLE_S=0.5; fi
sleep $SETTLE_S
tmux send-keys -t "$PANE" Enter

# 14. Cleanup
rm "$TASKFILE"

# 15. MANDATORY VERIFICATION
sleep 5
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
if echo "$OUTPUT" | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "✓ Worker ${WINDOW_INDEX}.X started processing"
else
  echo "⚠ Worker ${WINDOW_INDEX}.X not processing — retrying..."
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  tmux send-keys -t "$PANE" Enter
  sleep 3
  OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
  if echo "$OUTPUT" | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
    echo "✓ Worker ${WINDOW_INDEX}.X started after retry"
  else
    echo "✗ Worker ${WINDOW_INDEX}.X FAILED — run unstick sequence"
  fi
fi
```

### Variants

**Batch dispatch:** For independent tasks, use **separate parallel Bash calls per worker** (not `&&`). Each call contains the full dispatch sequence with appropriate pane index and task. Filter out reserved panes before selecting workers.

**Short tasks (< 200 chars, no special chars):** Use steps 1–8 as normal (every task gets fresh context), then `send-keys` directly instead of tmpfile (skip steps 9–12). Steps 13–15 still mandatory.

### File Conflict Prevention

When dispatching multiple workers in parallel:
- **Explicit file ownership:** Tell each worker which files it owns exclusively. "Do NOT modify any other files."
- **Section ownership for shared files:** Assign non-overlapping sections. "Use Edit with targeted replacements only. Never use Write."
- **Sequential dispatch for overlapping edits:** Wait for first worker to finish before dispatching second.
- **Optional lockfiles:** Workers create `$RUNTIME_DIR/locks/<file>.lock` before editing shared files; Window Manager checks before dispatching to same file.

### Rules

1. **Never use `send-keys "" Enter`** — the empty string swallows the Enter keystroke
2. **Always sleep between `paste-buffer` and `send-keys Enter`** — auto-scales based on prompt line count (>200 lines=2s, >100=1.5s, else 0.5s)
3. **Always check idle + reservation before dispatch** — don't interrupt busy or reserved panes
4. **Always verify after dispatch (step 15)** — if it fails, run unstick before retrying
5. **Always include project context** (`PROJECT_NAME`, `PROJECT_DIR`, absolute paths) in every task prompt

### Troubleshooting: Unstick a non-responsive worker

1. Try `C-c`, `C-u`, `Enter` (with `copy-mode -q` first). Wait 3s, check output.
2. If still stuck after 2 attempts: `kill -9` the child PID (`pgrep -P $PANE_PID`), wait 2s, relaunch Claude with the worker system prompt (find it via `grep -l "pane ${WINDOW_INDEX}.${PANE_IDX}" "${RUNTIME_DIR}/worker-system-prompt-"*.md`), e.g. `send-keys "claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter`, wait 8s, then re-dispatch.
