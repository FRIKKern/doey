# Skill: doey-delegate

Delegate a task to another Claude instance via tmpfile/load-buffer.

## Usage
`/doey-delegate`

## Prompt
You are delegating a task to another Claude Code instance in a tmux pane.

### Project Context

Every Bash call that touches tmux must start with:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```
Provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `WINDOW_INDEX`. Always use `${SESSION_NAME}` — never hardcode session names.

### Copy-mode pattern

`tmux copy-mode -q -t "$PANE" 2>/dev/null` — exits copy-mode (idempotent). **Run before every `paste-buffer` and `send-keys`.**

### Step 1: Discover panes and identity

```bash
# (project context vars)
tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
echo "I am: $MY_PANE"
```

### Step 2: Ask the user

If target pane and task not specified, ask now. Set `TARGET_PANE` (e.g. `${SESSION_NAME}:${WINDOW_INDEX}.3`).

### Step 3: Reservation check

```bash
# (project context vars)
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  echo "RESERVED — pick another pane"
  exit 1
fi
echo "Not reserved — OK"
```

### Step 4: Idle check

```bash
# (project context vars)
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5)
echo "$OUTPUT"
if echo "$OUTPUT" | grep -q '❯'; then
  echo "Idle — OK"
else
  echo "Pane may be busy — check output above"
fi
```

### Step 5: Rename, send task, settle, verify

Follow `/doey-dispatch` **Reliable Dispatch Sequence** (steps 8-15) using `TARGET_PANE` as `$PANE`. Skips steps 1-7 (kill/restart) since worker is already idle.

Key points:
- Rename pane with `/rename task-name_$(date +%m%d)` before sending
- Use tmpfile/load-buffer — never `send-keys "" Enter` for task text
- Settle time auto-scales by line count (>200=2s, >100=1.5s, else 0.5s)
- Verify after 5s — grep for `thinking|working|Read|Edit|Bash`; retry Enter once if not processing

### Rules

1. **Never `send-keys "" Enter`** — empty string swallows the Enter
2. **Always tmpfile/load-buffer** — handles all sizes and special chars
3. **Always sleep between paste-buffer and send-keys Enter** — auto-scales by line count
4. **Check idle + reservation before delegating**
5. **Verify after dispatch (per /doey-dispatch step 15)**
6. **Never delegate to your own pane** — compare `TARGET_PANE` vs `MY_PANE`
