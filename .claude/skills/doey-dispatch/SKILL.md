---
name: doey-dispatch
description: Send tasks to idle worker panes. Use when you need to "send a task", "assign work", "delegate to workers", or "dispatch to idle panes".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-}"|| true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

**Expected:** 4-6 bash commands per worker, ~15 seconds each.

Total: 6 steps per worker (pre-flight through verify), 0 errors expected.

## Prompt

Dispatch tasks to Claude Code workers in tmux panes. Always `copy-mode -q` before `paste-buffer`/`send-keys`. Use injected config variables (SESSION_NAME, PROJECT_NAME, PROJECT_DIR, WINDOW_INDEX, WORKER_PANES, WORKER_COUNT, etc.).

## Step 0: Auto-scale (before scanning)

Add a column if grid is dynamic and no idle workers exist.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
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

Expected: either an idle worker found or a new column added.
**If error:** check `WORKER_PANES` and `SESSION_NAME` are set from Context injection.

## Step 1: Pre-flight — check readiness

Check if pane shows ❯ (idle). Never dispatch to reserved panes.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.X" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && echo "Reserved — skip"
tmux copy-mode -q -t "${SESSION_NAME}:${WINDOW_INDEX}.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:${WINDOW_INDEX}.X" -p -S -3
```

Expected: captured pane output showing ❯ prompt, or "Reserved — skip".
**If error:** pane may not exist — verify WORKER_PANES list.

## Step 2: Check if Claude is at prompt, kill + restart if not

Re-check reservation, detect running Claude, restart if needed.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')

# Re-check reservation (may have changed since pre-flight)
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { echo "Reserved — skip"; exit 0; }

# Check if Claude is at prompt
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
OUTPUT=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
ALREADY_READY=false
[ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯' && ALREADY_READY=true

# Not ready → kill + restart
if [ "$ALREADY_READY" = "false" ]; then
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  PANE_IDX="${PANE##*.}"
  WORKER_PROMPT=$(grep -l "pane ${WINDOW_INDEX}\.${PANE_IDX} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  CMD="claude --dangerously-skip-permissions --model opus"
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "$PANE" "$CMD" Enter
  sleep 8; tmux copy-mode -q -t "$PANE" 2>/dev/null
fi
```

Expected: Claude running at ❯ prompt, ready for input.
**If error:** if kill fails, use `kill -9`. If Claude won't start, check `~/.local/bin/claude` exists.

## Step 3: Rename pane

Set a descriptive pane title for the task.

```bash
tmux send-keys -t "$PANE" "/rename task-name_$(date +%m%d)" Enter; sleep 1
```

Expected: pane title updated.
**If error:** harmless — continue to next step.

## Step 4: Write + paste task

Write the task to a temp file and paste it into the pane. Never use `send-keys "" Enter`.

```bash
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
TASK
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE"; tmux paste-buffer -t "$PANE"
```

Expected: task text visible in the pane input area.
**If error:** check `RUNTIME_DIR` is writable and `mktemp` succeeded.

## Step 5: Settle + submit

Wait for paste to render, then press Enter to submit.

```bash
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
SETTLE_S=0.5; [ "$TASK_LINES" -gt 100 ] && SETTLE_S=1.5; [ "$TASK_LINES" -gt 200 ] && SETTLE_S=2
sleep $SETTLE_S; tmux send-keys -t "$PANE" Enter
rm "$TASKFILE"
```

Expected: task submitted, worker begins processing.
**If error:** if Enter doesn't register, retry with `tmux send-keys -t "$PANE" Enter`.

## Step 6: Verify (mandatory)

Confirm the worker started processing. Do NOT skip this step.

```bash
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

Expected: "✓ Worker X started" confirmation.
**If error:** run the Unstick sequence below.

## Variants

- **Batch:** Parallel Bash calls per worker.
- **Short tasks (< 200 chars):** `send-keys` directly (skip tmpfile), but settle + verify still mandatory.

## File Conflicts

Assign file ownership per worker. Shared files: non-overlapping sections, Edit only. Overlapping: sequential dispatch.

## Rules

1. Never `send-keys "" Enter` — settle before Enter after paste
2. Re-check reservation before dispatch (`.reserved` file); verify after (Step 6) — both mandatory
3. Include `PROJECT_NAME`, `PROJECT_DIR`, absolute paths in every task

## Unstick

`copy-mode -q` → `C-c` → `C-u` → `Enter`, wait 3s. After 2 fails: `kill -9`, relaunch, wait 8s, re-dispatch.

## Gotchas

- Do NOT send empty string via send-keys — it swallows the Enter
- Do NOT dispatch to reserved panes — check `.reserved` file first
- Do NOT use relative paths in task prompts — workers have no shared context
- Do NOT dispatch multiple tasks to the same worker — one task per worker
- Do NOT skip the verify step — workers silently fail without it
