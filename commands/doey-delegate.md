# Skill: doey-delegate

Delegate a task to an idle Claude instance (no kill/restart).

## Usage
`/doey-delegate`

## Prompt

### Step 1: Discover panes

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
echo "I am: $MY_PANE"
```

### Step 2: Ask user for target pane and task if not provided

### Step 3: Check reservation + idle

```bash
TARGET_PANE="${SESSION_NAME}:${WINDOW_INDEX}.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then echo "RESERVED — pick another"; exit 1; fi
tmux copy-mode -q -t "$TARGET_PANE" 2>/dev/null
OUTPUT=$(tmux capture-pane -t "$TARGET_PANE" -p -S -5)
echo "$OUTPUT"
if echo "$OUTPUT" | grep -q '❯'; then echo "Idle — OK"; else echo "May be busy"; fi
```

### Step 4: Send task

Follow `/doey-dispatch` **Reliable Dispatch Sequence** (steps 8-15) using `TARGET_PANE` as `$PANE`. Skips steps 1-7 since worker is already idle.

### Rules
1. **Never `send-keys "" Enter`** — empty string swallows Enter
2. **Always tmpfile/load-buffer** for task text
3. **Sleep between paste-buffer and send-keys Enter** (auto-scales by line count)
4. **Verify after dispatch** (per /doey-dispatch step 15)
5. **Never delegate to your own pane**
