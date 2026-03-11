# Skill: doey-dispatch

Send a task to one or more idle worker panes reliably. This is the primary dispatch primitive for the TMUX Manager.

## Usage
`/doey-dispatch`

## Prompt
You are dispatching tasks to Claude Code worker instances in TMUX panes.

### Read Project Context

**Before dispatching any tasks**, discover the runtime directory and read the session manifest:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This gives you:
- `SESSION_NAME` — tmux session name (use instead of hardcoded session name)
- `PROJECT_DIR` — absolute path to the project directory
- `PROJECT_NAME` — human-readable project name
- `WORKER_PANES` — list of worker pane IDs
- `WATCHDOG_PANE` — the watchdog pane ID
- `PASTE_SETTLE_MS` — settle time in ms between paste-buffer and Enter (default 500)

**Always use `${SESSION_NAME}` in all tmux commands** — never hardcode the session name.

### Reliable Dispatch Sequence

**ALWAYS use this exact pattern.** Never use `send-keys "" Enter` — it is broken.

Every Bash call must start by reading the manifest, then follow all steps for the target pane `0.X`:

```bash
# (reads SESSION_NAME, PROJECT_NAME, PROJECT_DIR from manifest)
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"

# 1. Exit copy-mode (idempotent, always safe — prevents silent swallowing of input)
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 2. Kill the current Claude process by PID (reliable — /exit is not)
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3

# 3. Verify it died — if not, SIGKILL
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1

# 4. Exit copy-mode again (killing a process can trigger scroll)
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 5. Start a fresh Claude session
tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter

# 6. Wait for Claude to boot
sleep 8

# 7. Exit copy-mode before interacting
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 8. Rename the worker pane so the task is visible at a glance
tmux send-keys -t "$PANE" "/rename short-task-name" Enter
sleep 1

# 9. Ensure temp dir exists
mkdir -p "${RUNTIME_DIR}"

# 10. Write task to temp file (avoids escaping issues)
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

Your detailed task prompt here.
Multi-line is fine.
TASK

# 11. Exit copy-mode before paste (CRITICAL — prevents silent task loss)
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 12. Load into tmux buffer and paste into target pane
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "$PANE"

# 13. CRITICAL: exit copy-mode, sleep, then bare Enter — this is what actually submits
#     The settle time between paste-buffer and Enter is configurable via PASTE_SETTLE_MS
#     in session.env (default 500ms). For large prompts (>100 lines), it auto-scales to
#     1.5-2s to ensure the full prompt is pasted before submission.
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
if command -v bc >/dev/null 2>&1; then
  SETTLE_S=$(echo "scale=2; ${PASTE_SETTLE_MS:-500} / 1000" | bc)
  if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then
    MIN_SETTLE="2.0"
  elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then
    MIN_SETTLE="1.5"
  else
    MIN_SETTLE="$SETTLE_S"
  fi
  # Use the larger of configured settle time and auto-scaled minimum
  SETTLE_S=$(echo "if ($MIN_SETTLE > $SETTLE_S) $MIN_SETTLE else $SETTLE_S" | bc)
else
  # Fallback if bc is not available
  if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then
    SETTLE_S="2.0"
  elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then
    SETTLE_S="1.5"
  else
    SETTLE_S="0.5"
  fi
fi
sleep $SETTLE_S
tmux send-keys -t "$PANE" Enter

# 14. Cleanup temp file
rm "$TASKFILE"

# 15. MANDATORY VERIFICATION — confirm worker started processing
sleep 5
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "✓ Worker 0.X started processing"
else
  # Worker may be stuck — retry submission
  echo "⚠ Worker 0.X not processing yet — retrying..."
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  tmux send-keys -t "$PANE" Enter
  sleep 3
  OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
  if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
    echo "✓ Worker 0.X started processing after retry"
  else
    echo "✗ Worker 0.X FAILED to start — may need unstick sequence"
  fi
fi
```

Each dispatch starts a fresh Claude session. The old session is exited first to ensure clean context and no stale state from previous tasks.

### Pre-flight: Check if worker is idle

**Always check before dispatching.** A worker is idle when its last few lines show the `❯` or `>` prompt:

```bash
# (uses SESSION_NAME, PROJECT_NAME, PROJECT_DIR from manifest)
tmux copy-mode -q -t "${SESSION_NAME}:0.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -3
```

Look for `❯` prompt at the end. If you see `thinking`, `working`, or active tool output — the worker is busy. Do NOT send tasks to busy workers.

If the worker is idle, it still has an old session. The dispatch handles exiting and restarting automatically.

### Post-flight: Verification is mandatory

Verification is built into the dispatch sequence (step 15). It automatically:
1. Waits 5s and checks if the worker started processing
2. If not, exits copy-mode and re-sends Enter
3. Waits 3s and checks again
4. Reports success or failure

**Do NOT skip verification.** If step 15 reports failure, run the unstick sequence (see Troubleshooting) before retrying dispatch.

### Batch Dispatch (multiple workers)

For independent tasks, dispatch to multiple workers in a single message. Use **separate Bash calls per worker** — do NOT chain them with `&&` since they are independent.

Each Bash call contains the full dispatch sequence (steps 1–15) for one worker, with the appropriate pane index and task content. Repeat for each additional worker in parallel Bash calls — same pattern, different pane index and task content.

### Short tasks (< 200 chars, no special chars)

Use the same dispatch sequence above (steps 1–8 are mandatory — every task gets a fresh Claude context), but you can skip the tmpfile (steps 9–12) and use `send-keys` directly after step 8. Steps 13–15 (submit + verify) are still mandatory. The settle time (step 13) still applies but will use the default since short tasks are small — no auto-scaling kicks in.

### Rules

1. **Never use `send-keys "" Enter`** — the empty string swallows the Enter keystroke
2. **Always sleep between `paste-buffer` and `send-keys Enter`** — uses `PASTE_SETTLE_MS` from session.env (default 500ms), auto-scales for large prompts
3. **Always exit copy-mode before every `paste-buffer` and `send-keys`** — copy-mode silently swallows all input
4. **Always check idle first** — don't interrupt a working pane
5. **Always verify after dispatch** — step 15 is mandatory, not optional
6. **Always include project context in every task prompt** — workers need to know the project name, directory, and that paths should be absolute
7. **Always exit the old session before dispatching** — every task gets a fresh Claude context
8. **If verification fails, run the unstick sequence** before retrying dispatch
9. See also: Manager agent definition rules (always active in your context)

### File Conflict Prevention

When dispatching multiple workers in parallel, prevent file conflicts:

**1. Explicit file ownership in task prompts**
Always tell each worker which files it owns. Example:
```
You own these files exclusively:
- /path/to/project/src/components/Footer.tsx
- /path/to/project/src/styles/footer.css

Do NOT modify any other files. Use the Edit tool with targeted replacements — never use Write on files other workers may be editing.
```

**2. Section ownership for shared files**
If multiple workers must edit the same file, assign non-overlapping sections:
```
You own the <footer> section of index.html (lines ~150-200).
Do NOT modify <nav>, <header>, or any other section.
Use Edit with targeted old_string/new_string replacements only.
Never use the Write tool on this file.
```

**3. Sequential dispatch for same-file edits**
If two workers must edit overlapping sections of the same file, dispatch them sequentially — wait for the first to finish before dispatching the second.

**4. Lockfile mechanism (optional extra safety)**
Workers can create a lockfile before editing shared files:
```bash
# Before editing
LOCK="$RUNTIME_DIR/locks/$(echo "filename" | tr '/' '_').lock"
mkdir -p "$RUNTIME_DIR/locks"
touch "$LOCK"

# After editing
rm -f "$LOCK"
```
The Manager should check for active locks before dispatching a new worker to the same file. This is secondary to clear ownership — ownership in the prompt is the primary defense.

### Troubleshooting: Unstick a non-responsive worker

If dispatch verification (step 15) reports failure, or a worker appears stuck/non-responsive, run this unstick sequence:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"

# 1. Exit copy-mode
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 2. Cancel any pending input (Ctrl+C)
tmux send-keys -t "$PANE" C-c
sleep 0.5

# 3. Clear the input line (Ctrl+U)
tmux send-keys -t "$PANE" C-u
sleep 0.5

# 4. Try Enter to submit any remaining pasted text
tmux send-keys -t "$PANE" Enter

# 5. Wait and check if the worker is now responsive
sleep 3
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
echo "$OUTPUT"
```

If the unstick sequence doesn't work (worker still non-responsive after 2 attempts), **kill and restart the Claude process on that pane:**

```bash
PANE="${SESSION_NAME}:0.X"

# Force-kill the Claude process
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
sleep 2

# Restart Claude
tmux copy-mode -q -t "$PANE" 2>/dev/null
tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter
sleep 8

# Then re-dispatch the task using the full dispatch sequence
```

### Diagnostic checks

If you need to investigate why a worker is stuck:
1. Check pane mode: `tmux display-message -t "${SESSION_NAME}:0.X" -p '#{pane_mode}'` (should be empty, not "copy-mode")
2. Check if Claude is running: `pgrep -P $(tmux display-message -t "${SESSION_NAME}:0.X" -p '#{pane_pid}') 2>/dev/null`
3. Capture pane content: `tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -10`
4. If text is garbled: the pane might have been busy. Run unstick sequence, wait for idle, then retry.
