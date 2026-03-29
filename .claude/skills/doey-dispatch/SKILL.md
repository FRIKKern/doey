---
name: doey-dispatch
description: Send tasks to idle worker panes. Use when you need to "send a task", "assign work", "delegate to workers", "dispatch to idle panes", or "give a worker something to do".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-}"|| true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

## Prompt

Dispatch tasks to workers. Always `copy-mode -q` before `paste-buffer`/`send-keys`.

### Auto-scale (before scanning)

Add a column if grid is dynamic and no idle workers exist.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
if [ "$(grep '^GRID=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)" = "dynamic" ]; then
  HAS_IDLE=false
  for WIDX in $(echo "$WORKER_PANES" | tr ',' ' '); do
    W_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${WIDX}" | tr ':-.' '_')
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

❯ = idle. Never dispatch to reserved panes.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':-.' '_')
if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then echo "Reserved — skip"; fi
tmux copy-mode -q -t "${SESSION_NAME}:${WINDOW_INDEX}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.X" -p -S -3
```

### Smart Context Check

Before killing a worker, check if its previous task context is relevant to the new task.
Workers that already have useful context loaded (same tags, same files, same domain) perform
better when delegated into — no cold start, shared file caches, continuity. Workers with
unrelated context get a clean restart for best results.

**Default bias: restart.** Missing metadata, empty fields, or `FORCE_RESTART=1` all trigger a
clean restart. This is the safe default — fresh context beats stale context for unrelated work.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

USE_DELEGATE=false

# Only consider delegation if: worker is at prompt, has LAST_* metadata, no force restart
if [ "${FORCE_RESTART:-0}" != "1" ] && [ -f "$STATUS_FILE" ]; then
  LAST_TAGS=$(grep '^LAST_TASK_TAGS: ' "$STATUS_FILE" 2>/dev/null | cut -d' ' -f2-) || LAST_TAGS=""
  LAST_TYPE=$(grep '^LAST_TASK_TYPE: ' "$STATUS_FILE" 2>/dev/null | cut -d' ' -f2-) || LAST_TYPE=""
  LAST_FILES=$(grep '^LAST_FILES: ' "$STATUS_FILE" 2>/dev/null | cut -d' ' -f2-) || LAST_FILES=""

  if [ -n "$LAST_TAGS" ] || [ -n "$LAST_TYPE" ] || [ -n "$LAST_FILES" ]; then
    # NEW_TASK_TAGS, NEW_TASK_TYPE, NEW_TASK_FILES should be set by the Manager before dispatch.
    # Extract from the .task file if a TASK_ID is known:
    #   NEW_TASK_TAGS=$(grep "^TASK_TAGS=" "$PROJECT_DIR/.doey/tasks/${TASK_ID}.task" 2>/dev/null | cut -d= -f2-)
    #   NEW_TASK_TYPE=$(grep "^TASK_TYPE=" "$PROJECT_DIR/.doey/tasks/${TASK_ID}.task" 2>/dev/null | cut -d= -f2-)
    #   NEW_TASK_FILES: comma-separated list of files the task will touch (from task description or dispatch plan)
    source "${PROJECT_DIR}/shell/doey-task-helpers.sh" 2>/dev/null || true
    if type task_should_restart >/dev/null 2>&1; then
      if ! task_should_restart "$LAST_TAGS" "$LAST_TYPE" "$LAST_FILES" \
                               "${NEW_TASK_TAGS:-}" "${NEW_TASK_TYPE:-}" "${NEW_TASK_FILES:-}"; then
        USE_DELEGATE=true
        echo "Context overlap ≥30% — delegating into existing session"
      fi
    fi
  fi
fi
```

If `USE_DELEGATE=true`, skip kill+restart and go straight to step 3 (Rename) → 4 (Paste task) → 5 (Settle) → 6 (Verify). The worker keeps its loaded context.

### Dispatch Sequence

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')

# 0. Re-check reservation
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { echo "Reserved — skip"; exit 0; }

# 1. Check if Claude is at prompt (has child process + "bypass permissions" + ❯)
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
OUTPUT=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
ALREADY_READY=false
[ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯' && ALREADY_READY=true || true

# 2. Not ready AND not delegating → kill + restart
if [ "$ALREADY_READY" = "false" ] && [ "$USE_DELEGATE" != "true" ]; then
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  PANE_IDX="${PANE##*.}"
  WORKER_PROMPT=$(grep -l "pane ${WINDOW_INDEX}\.${PANE_IDX} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  CMD="claude --dangerously-skip-permissions --model ${DOEY_WORKER_MODEL:-opus}"
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "$PANE" "$CMD" Enter
  sleep 8; tmux copy-mode -q -t "$PANE" 2>/dev/null
fi

# 3. Rename pane
tmux select-pane -t "$PANE" -T "task-name_$(date +%m%d)"

# 4. Write + paste task
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
TASK
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE"; tmux paste-buffer -t "$PANE"

# 5. Settle + submit (delay: >200L=2s, >100L=1.5s, else 0.5s)
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
SETTLE_S=0.5; [ "$TASK_LINES" -gt 100 ] && SETTLE_S=1.5; [ "$TASK_LINES" -gt 200 ] && SETTLE_S=2
sleep $SETTLE_S; tmux send-keys -t "$PANE" Enter
rm "$TASKFILE"

# 6. Verify (mandatory — retry once if no activity detected)
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

**Batch:** Parallel Bash calls per worker. **Short (< 200 chars):** `send-keys` directly, settle + verify still mandatory.
**File conflicts:** One file owner per worker. Shared files: non-overlapping sections, Edit only.
**Unstick:** `copy-mode -q` → `C-c` → `C-u` → `Enter`, 3s wait. After 2 fails: `kill -9`, relaunch, re-dispatch.

### Overrides

**Force restart (ignore context overlap):** Set `FORCE_RESTART=1` before dispatching. Useful when the worker's context is known to be corrupted, or you want a clean slate regardless of overlap.

**Force delegate (skip context check):** Use `/doey-delegate` directly. Bypasses the scoring logic entirely and sends the task into the existing session as-is.

## Rules

- Re-check `.reserved` before dispatch; verify after (step 6)
- Include `PROJECT_NAME`, `PROJECT_DIR`, absolute paths in every task. One task per worker per cycle
- Smart context: delegate when overlap ≥30%, restart when <30% or metadata missing. Default: restart
