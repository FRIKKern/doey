---
name: doey-dispatch
description: Send tasks to idle worker panes. Use when you need to "send a task", "assign work", "delegate to workers", "dispatch to idle panes", or "give a worker something to do".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-}"|| true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

Always `copy-mode -q` before `paste-buffer`/`send-keys`.

### Auto-scale (dynamic grid, no idle workers → add column)

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
W="${DOEY_WINDOW_INDEX:-0}"
if [ "$(grep '^GRID=' "${RD}/session.env" 2>/dev/null | cut -d= -f2)" = "dynamic" ]; then
  HAS_IDLE=false
  for WIDX in $(echo "$WORKER_PANES" | tr ',' ' '); do
    W_SAFE=$(echo "${SESSION_NAME}:${W}.${WIDX}" | tr ':-.' '_')
    [ -f "${RD}/status/${W_SAFE}.reserved" ] && continue
    case "$(tmux capture-pane -t "${SESSION_NAME}:${W}.${WIDX}" -p -S -3 2>/dev/null)" in *'❯'*) HAS_IDLE=true; break ;; esac
  done
  if [ "$HAS_IDLE" = "false" ] && [ "${WORKER_COUNT:-0}" -lt "${MAX_WORKERS:-20}" ]; then
    doey add 2>/dev/null; sleep 10
    source "${RD}/session.env"; [ -f "${RD}/team_${W}.env" ] && source "${RD}/team_${W}.env"
  fi
fi
```

### Pre-flight (❯ = idle, skip reserved)

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
W="${DOEY_WINDOW_INDEX:-0}"
PANE_SAFE=$(echo "${SESSION_NAME}:${W}.X" | tr ':-.' '_')
[ -f "${RD}/status/${PANE_SAFE}.reserved" ] && echo "Reserved — skip"
tmux copy-mode -q -t "${SESSION_NAME}:${W}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${W}.X" -p -S -3
```

### Smart Context Check (≥30% overlap → delegate, else restart)

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
W="${DOEY_WINDOW_INDEX:-0}"; PANE="${SESSION_NAME}:${W}.X"
PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
STATUS_FILE="${RD}/status/${PANE_SAFE}.status"
USE_DELEGATE=false
if [ "${FORCE_RESTART:-0}" != "1" ] && [ -f "$STATUS_FILE" ]; then
  LAST_TAGS=$(grep '^LAST_TASK_TAGS: ' "$STATUS_FILE" 2>/dev/null | cut -d' ' -f2-) || LAST_TAGS=""
  LAST_TYPE=$(grep '^LAST_TASK_TYPE: ' "$STATUS_FILE" 2>/dev/null | cut -d' ' -f2-) || LAST_TYPE=""
  LAST_FILES=$(grep '^LAST_FILES: ' "$STATUS_FILE" 2>/dev/null | cut -d' ' -f2-) || LAST_FILES=""
  if [ -n "$LAST_TAGS" ] || [ -n "$LAST_TYPE" ] || [ -n "$LAST_FILES" ]; then
    source "${PROJECT_DIR}/shell/doey-task-helpers.sh" 2>/dev/null || true
    if type task_should_restart >/dev/null 2>&1; then
      if ! task_should_restart "$LAST_TAGS" "$LAST_TYPE" "$LAST_FILES" \
                               "${NEW_TASK_TAGS:-}" "${NEW_TASK_TYPE:-}" "${NEW_TASK_FILES:-}"; then
        USE_DELEGATE=true; echo "Context overlap ≥30% — delegating"
      fi
    fi
  fi
fi
```

`USE_DELEGATE=true` → skip kill+restart, jump to Rename.

### Dispatch Sequence

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
W="${DOEY_WINDOW_INDEX:-0}"; PANE="${SESSION_NAME}:${W}.X"
PANE_SAFE=$(echo "$PANE" | tr ':-.' '_')
[ -f "${RD}/status/${PANE_SAFE}.reserved" ] && { echo "Reserved — skip"; exit 0; }

# Check if Claude is at prompt
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
OUTPUT=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
ALREADY_READY=false
[ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯' && ALREADY_READY=true || true

# Not ready AND not delegating → kill + restart
if [ "$ALREADY_READY" = "false" ] && [ "$USE_DELEGATE" != "true" ]; then
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  PANE_IDX="${PANE##*.}"
  WORKER_PROMPT=$(grep -l "pane ${W}\.${PANE_IDX} " "${RD}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  CMD="claude --dangerously-skip-permissions --model ${DOEY_WORKER_MODEL:-opus}"
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "$PANE" "$CMD" Enter; sleep 8
  tmux copy-mode -q -t "$PANE" 2>/dev/null
fi

# Rename + paste task
tmux select-pane -t "$PANE" -T "task-name_$(date +%m%d)"
TASKFILE=$(mktemp "${RD}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
TASK
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE"; tmux paste-buffer -t "$PANE"

# Settle + submit (>200L=2s, >100L=1.5s, else 0.5s)
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
SETTLE_S=0.5; [ "$TASK_LINES" -gt 100 ] && SETTLE_S=1.5; [ "$TASK_LINES" -gt 200 ] && SETTLE_S=2
sleep $SETTLE_S; tmux send-keys -t "$PANE" Enter; rm "$TASKFILE"

# Verify (retry once if no activity)
sleep 5; OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
if echo "$OUTPUT" | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "✓ Worker ${W}.X started"
else
  tmux copy-mode -q -t "$PANE" 2>/dev/null; tmux send-keys -t "$PANE" Enter; sleep 3
  OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
  if echo "$OUTPUT" | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
    echo "✓ Started after retry"
  else echo "✗ FAILED — run unstick sequence"; fi
fi
```

### Variants
- **Batch:** Parallel Bash per worker | **Short (<200 chars):** `send-keys` (verify still required)
- **File conflicts:** One file per worker | **Unstick:** `copy-mode -q` → `C-c` → `C-u` → Enter, 3s. 2 fails: `kill -9`, relaunch
- **Force restart:** `FORCE_RESTART=1` | **Force delegate:** `/doey-delegate`

### Rules
Re-check `.reserved` before dispatch; verify after. One task/worker/cycle. Include `PROJECT_NAME`, `PROJECT_DIR`, absolute paths.
