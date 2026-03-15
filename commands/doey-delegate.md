# Skill: doey-delegate

Delegate a task to another Claude instance by sending it a prompt. Uses the tmpfile/load-buffer method for reliable delivery.

## Usage
`/doey-delegate`

## Prompt
You are delegating a task to another Claude Code instance in a TMUX pane.

### Project Context (read once per Bash call)

Every Bash call that touches tmux must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `PASTE_SETTLE_MS` (default 500). **Always use `${SESSION_NAME}`** — never hardcode session names.

### Copy-mode pattern

`tmux copy-mode -q -t "$PANE" 2>/dev/null` — exits copy-mode (idempotent, always safe). **Run this before every `paste-buffer` and `send-keys`** throughout the delegation. Copy-mode silently swallows all input.

### Step 1: Discover panes and identity

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
echo "I am: $MY_PANE"
```

### Step 2: Ask the user

If the user did not specify a target pane and task, ask them now. Then set `TARGET_PANE` (e.g. `${SESSION_NAME}:0.3`).

### Step 3: Pre-flight — reservation check

**Always check before delegating.** Never delegate to a RESERVED pane.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_PANE="${SESSION_NAME}:0.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  echo "RESERVED — pick another pane"
  exit 1
fi
echo "Not reserved — OK"
```

### Step 4: Pre-flight — idle check

Capture the last few lines and look for the `❯` prompt to confirm the worker is idle.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_PANE="${SESSION_NAME}:0.X"
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

Follow the `/doey-dispatch` **Reliable Dispatch Sequence** (steps 8–15), using `TARGET_PANE` as `$PANE`. The delegate workflow skips steps 1–7 (kill/restart) since the worker is already idle.

Key points:
- **Rename pane** with `/rename task-name_$(date +%m%d)` before sending
- **Use tmpfile/load-buffer** — never `send-keys "" Enter` for task text
- **Settle time auto-scales** for large prompts via `PASTE_SETTLE_MS`
- **Mandatory verification** — grep for `thinking|working|Read|Edit|Bash` after 5s; retry Enter once if not processing

### Rules

1. **Never use `send-keys "" Enter`** — the empty string swallows the Enter keystroke
2. **Always use tmpfile/load-buffer** — handles all prompt sizes and special characters reliably
3. **Always sleep between `paste-buffer` and `send-keys Enter`** — uses `PASTE_SETTLE_MS`, auto-scales for large prompts
4. **Always check idle + reservation before delegating** — don't interrupt busy or reserved panes
5. **Always verify after dispatch (step 6)** — if it fails, check the pane manually
6. **Do not delegate to your own pane** — compare `TARGET_PANE` against `MY_PANE`
