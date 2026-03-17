# Skill: doey-restart-window

Restart all workers in a specific team window. Does not restart the Window Manager (W.0) or the Watchdog (in Dashboard). Uses process-based killing and deterministic verify loops.

## Usage
`/doey-restart-window [window_index]` — restart a specific team window (default: current window)

## Prompt
You are restarting workers in a team window. The Watchdog runs in Dashboard (pane 0.2-0.4), not in the team window.

### Step 1: Read project context and determine target window

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TARGET_WIN="${1:-$WINDOW_INDEX}"

TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WIN}.env"
if [ -f "$TEAM_ENV" ]; then
  while IFS='=' read -r key value; do
    value="${value%\"}" && value="${value#\"}"
    case "$key" in WORKER_PANES) WORKER_PANES="$value" ;; esac
  done < "$TEAM_ENV"
fi

ALL_PANES=$(echo "$WORKER_PANES" | tr ',' ' ')
WORKER_PANES_LIST="$ALL_PANES"

SKIP_PANES=""
for i in $WORKER_PANES_LIST; do
  PANE_PID=$(tmux display-message -t "$SESSION_NAME:${TARGET_WIN}.$i" -p '#{pane_pid}')
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:${TARGET_WIN}.$i" -p 2>/dev/null)
  if [ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯'; then
    SKIP_PANES="$SKIP_PANES $i"
  fi
done

echo "Target window: ${TARGET_WIN}"
echo "Workers: ${WORKER_PANES} (Watchdog runs in Dashboard, not restarted here)"
[ -n "$SKIP_PANES" ] && echo "Skipping (already ready):${SKIP_PANES}"
```

### Step 2: Kill processes

Kill Claude processes by PID. Skip ready workers. Uses vars from Step 1.

```bash
# (vars from step 1)
for i in $ALL_PANES; do
  if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
  PANE_PID=$(tmux display-message -t "$SESSION_NAME:${TARGET_WIN}.$i" -p '#{pane_pid}')
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
done
sleep 3

for attempt in 1 2 3 4 5; do
  STILL_RUNNING=0; STUCK_PANES=""
  for i in $ALL_PANES; do
    if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
    PANE_PID=$(tmux display-message -t "$SESSION_NAME:${TARGET_WIN}.$i" -p '#{pane_pid}')
    CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
    if [ -n "$CHILD_PID" ]; then
      STILL_RUNNING=$((STILL_RUNNING + 1)); STUCK_PANES="$STUCK_PANES ${TARGET_WIN}.$i"
      kill -9 "$CHILD_PID" 2>/dev/null
    fi
  done
  [ "$STILL_RUNNING" -eq 0 ] && break
  sleep 2
done
```

If `$STILL_RUNNING` != 0 after loop: report "FAILED: Panes $STUCK_PANES still have processes after 5 kill attempts. Manual intervention needed." and **STOP**.

### Step 3: Clear terminals

```bash
# (vars from step 1)
for i in $ALL_PANES; do
  if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
  tmux copy-mode -q -t "$SESSION_NAME:${TARGET_WIN}.$i" 2>/dev/null
  tmux send-keys -t "$SESSION_NAME:${TARGET_WIN}.$i" "clear" Enter 2>/dev/null
done
sleep 1
```

### Step 4: Launch instances

Launch workers with 0.5s gaps. Skip already-ready workers.

```bash
# (vars from step 1)
for i in $WORKER_PANES_LIST; do
  if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
  WORKER_PROMPT=$(grep -l "pane ${TARGET_WIN}\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
  if [ -n "$WORKER_PROMPT" ]; then
    tmux send-keys -t "$SESSION_NAME:${TARGET_WIN}.$i" "claude --dangerously-skip-permissions --model opus --append-system-prompt-file \"${WORKER_PROMPT}\"" Enter
  else
    tmux send-keys -t "$SESSION_NAME:${TARGET_WIN}.$i" "claude --dangerously-skip-permissions --model opus" Enter
  fi
  sleep 0.5
done
```

### Step 5: Verify boot

```bash
# (vars from step 1)
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  NOT_READY=0; DOWN_PANES=""
  for i in $ALL_PANES; do
    PANE_PID=$(tmux display-message -t "$SESSION_NAME:${TARGET_WIN}.$i" -p '#{pane_pid}')
    CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
    OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:${TARGET_WIN}.$i" -p 2>/dev/null)
    if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
      NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES ${TARGET_WIN}.$i"
    fi
  done
  [ "$NOT_READY" -eq 0 ] && break
  sleep 5
done
```

### Step 6: Final report

Show status table distinguishing skipped (already ready) from restarted panes:
```
Pane          Role        Status
${TARGET_WIN}.1     Worker      UP (already ready — skipped)
${TARGET_WIN}.2     Worker      UP (restarted)
${TARGET_WIN}.3     Worker      UP (restarted)
```

All panes are Workers (Watchdog is in Dashboard). Check `$SKIP_PANES`.

### Rules
- **Never restart the Window Manager** (pane W.0) — only workers
- **Watchdog is in Dashboard** (pane 0.2-0.4) — not restarted by this command
- **Always kill by PID** — never use `/exit` or `send-keys` to stop Claude
- **Skip workers that are already ready** (has child process + bypass permissions + prompt visible)
- **If VERIFY KILLED fails, STOP** — do not proceed to launch
- **All sleep durations are intentional** — do not shorten
- All bash must be 3.2 compatible
- Pane indices come from team_W.env — never hardcode
