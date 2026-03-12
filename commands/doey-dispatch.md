# Skill: doey-dispatch

Send a task to one or more idle worker panes reliably. This is the primary dispatch primitive for the TMUX Manager.

## Usage
`/doey-dispatch`

## Prompt
You are dispatching tasks to Claude Code worker instances in TMUX panes.

### Project Context (read once per Bash call)

Every Bash call that touches tmux must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `PASTE_SETTLE_MS` (default 500). **Always use `${SESSION_NAME}`** — never hardcode session names.

### Copy-mode pattern

`tmux copy-mode -q -t "$PANE" 2>/dev/null` — exits copy-mode (idempotent, always safe). **Run this before every `paste-buffer` and `send-keys`** throughout the dispatch. Copy-mode silently swallows all input. Used repeatedly in the sequence below without further explanation.

### Pre-flight: Check worker availability

**Always check before dispatching.** First verify the pane is not reserved, then check if it's idle.

```bash
# Check reservation
PANE_SAFE=$(echo "${SESSION_NAME}:0.X" | tr ':.' '_')
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  EXPIRY=$(head -1 "$RESERVE_FILE")
  if [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ]; then
    echo "Pane is reserved — skip this worker, pick another"
  fi
fi

# Check idle (look for ❯ prompt; if you see thinking/working/tool output — busy)
tmux copy-mode -q -t "${SESSION_NAME}:0.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -3
```

**Never dispatch to a RESERVED pane.** If all workers are reserved, report to the user and wait.

### Reliable Dispatch Sequence

**ALWAYS use this exact pattern.** Never use `send-keys "" Enter` — it is broken.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"

# 1. Exit copy-mode
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 2. Kill current Claude process by PID
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3

# 3. Verify it died — SIGKILL if not
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1

# 4. Exit copy-mode (killing can trigger scroll)
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 5. Start fresh Claude
tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter

# 6. Wait for boot
sleep 8

# 7. Exit copy-mode
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 8. Rename pane
tmux send-keys -t "$PANE" "/rename short-task-name" Enter
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

# 13. Settle, then submit — auto-scales for large prompts
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
if command -v bc >/dev/null 2>&1; then
  SETTLE_S=$(echo "scale=2; ${PASTE_SETTLE_MS:-500} / 1000" | bc)
  if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then MIN_SETTLE="2.0"
  elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then MIN_SETTLE="1.5"
  else MIN_SETTLE="$SETTLE_S"; fi
  SETTLE_S=$(echo "if ($MIN_SETTLE > $SETTLE_S) $MIN_SETTLE else $SETTLE_S" | bc)
else
  if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then SETTLE_S="2.0"
  elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then SETTLE_S="1.5"
  else SETTLE_S="0.5"; fi
fi
sleep $SETTLE_S
tmux send-keys -t "$PANE" Enter

# 14. Cleanup
rm "$TASKFILE"

# 15. MANDATORY VERIFICATION
sleep 5
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "✓ Worker 0.X started processing"
else
  echo "⚠ Worker 0.X not processing — retrying..."
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  tmux send-keys -t "$PANE" Enter
  sleep 3
  OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
  if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
    echo "✓ Worker 0.X started after retry"
  else
    echo "✗ Worker 0.X FAILED — run unstick sequence"
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
- **Optional lockfiles:** Workers create `$RUNTIME_DIR/locks/<file>.lock` before editing shared files; Manager checks before dispatching to same file.

### Rules

1. **Never use `send-keys "" Enter`** — the empty string swallows the Enter keystroke
2. **Always sleep between `paste-buffer` and `send-keys Enter`** — uses `PASTE_SETTLE_MS`, auto-scales for large prompts
3. **Always check idle + reservation before dispatch** — don't interrupt busy or reserved panes
4. **Always verify after dispatch (step 15)** — if it fails, run unstick before retrying
5. **Always include project context** (`PROJECT_NAME`, `PROJECT_DIR`, absolute paths) in every task prompt

### Troubleshooting: Unstick a non-responsive worker

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
PANE="${SESSION_NAME}:0.X"

# Try Ctrl+C, Ctrl+U, Enter
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" C-c
sleep 0.5
tmux send-keys -t "$PANE" C-u
sleep 0.5
tmux send-keys -t "$PANE" Enter
sleep 3
tmux capture-pane -t "$PANE" -p -S -5
```

If still stuck after 2 attempts, force-kill and restart:

```bash
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
sleep 2
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter
sleep 8
# Then re-dispatch using the full sequence
```

**Diagnostic checks:** `tmux display-message -t "$PANE" -p '#{pane_mode}'` (should be empty), `pgrep -P $(tmux display-message -t "$PANE" -p '#{pane_pid}')`, `tmux capture-pane -t "$PANE" -p -S -10`.
