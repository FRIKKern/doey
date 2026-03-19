---
name: doey-dispatch
description: Send tasks to idle worker panes.
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-|| true`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_$(tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-).env 2>/dev/null || true`

## Prompt

Dispatch tasks to Claude Code workers in tmux panes. Always `copy-mode -q` before `paste-buffer`/`send-keys`. Use injected config variables (SESSION_NAME, PROJECT_NAME, PROJECT_DIR, WINDOW_INDEX, WORKER_PANES, WORKER_COUNT, etc.).

### Common setup

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
is_pane_idle() {  # checks reservation + idle (❯)
  local P="$1" P_SAFE; P_SAFE=$(echo "$P" | tr ':.' '_')
  [ -f "${RUNTIME_DIR}/status/${P_SAFE}.reserved" ] && return 1
  tmux copy-mode -q -t "$P" 2>/dev/null
  case "$(tmux capture-pane -t "$P" -p -S -3 2>/dev/null)" in *'❯'*) return 0 ;; esac; return 1
}
is_working() { tmux capture-pane -t "$1" -p -S -5 2>/dev/null | grep -q -E '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; }
```

### Auto-scale (before scanning)

Add a column if grid is dynamic and no idle workers exist.

```bash
if [ "$(grep '^GRID=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)" = "dynamic" ]; then
  HAS_IDLE=false
  for WIDX in $(echo "$WORKER_PANES" | tr ',' ' '); do
    is_pane_idle "${SESSION_NAME}:${WINDOW_INDEX}.${WIDX}" && { HAS_IDLE=true; break; }
  done
  if [ "$HAS_IDLE" = "false" ] && [ "${WORKER_COUNT:-0}" -lt "${MAX_WORKERS:-20}" ]; then
    doey add 2>/dev/null; sleep 10
    source "${RUNTIME_DIR}/session.env"
    [ -f "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" ] && source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  fi
fi
```

### Pre-flight

Check each target pane with `is_pane_idle` — skip reserved, dispatch only to idle (❯).

### Dispatch Sequence

```bash
PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { echo "Reserved — skip"; exit 0; }

# 0. Check readiness
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
OUTPUT=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
READY=false
[ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯' && READY=true

# 1. Not ready → kill + restart
if [ "$READY" = "false" ]; then
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1
  PANE_IDX="${PANE##*.}"
  WORKER_PROMPT=$(grep -l "pane ${WINDOW_INDEX}\.${PANE_IDX} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  CMD="claude --dangerously-skip-permissions --model opus"
  [ -n "$WORKER_PROMPT" ] && CMD="${CMD} --append-system-prompt-file \"${WORKER_PROMPT}\""
  tmux send-keys -t "$PANE" "$CMD" Enter; sleep 8
fi

# 2. Rename + write task + paste
tmux send-keys -t "$PANE" "/rename task-name_$(date +%m%d)" Enter; sleep 1
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
TASK
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux load-buffer "$TASKFILE"; tmux paste-buffer -t "$PANE"

# 3. Settle + submit (delay: >200 lines=2s, >100=1.5s, else 0.5s)
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
SETTLE_S=0.5; [ "$TASK_LINES" -gt 100 ] && SETTLE_S=1.5; [ "$TASK_LINES" -gt 200 ] && SETTLE_S=2
sleep $SETTLE_S; tmux send-keys -t "$PANE" Enter; rm "$TASKFILE"

# 4. Verify (mandatory) — retry once on failure
sleep 5
if is_working "$PANE"; then echo "✓ Worker ${WINDOW_INDEX}.X started"
else
  tmux copy-mode -q -t "$PANE" 2>/dev/null; tmux send-keys -t "$PANE" Enter; sleep 3
  if is_working "$PANE"; then echo "✓ Started after retry"
  else echo "✗ FAILED — run unstick sequence"; fi
fi
```

### Rules

1. Never `send-keys "" Enter` — settle before Enter after paste
2. Re-check reservation before dispatch; verify after (step 4) — both mandatory
3. Include `PROJECT_NAME`, `PROJECT_DIR`, absolute paths in every task
4. **Batch:** parallel Bash calls per worker. **Short tasks (< 200 chars):** `send-keys` directly (skip tmpfile), settle + verify still mandatory
5. **File conflicts:** assign file ownership per worker; shared files use non-overlapping sections with Edit only; overlapping edits require sequential dispatch
6. **Unstick:** `copy-mode -q` -> `C-c` -> `C-u` -> `Enter`, wait 3s. After 2 fails: `kill -9`, relaunch, wait 8s, re-dispatch
