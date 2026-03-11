# Skill: doey-monitor

Smart monitoring of all worker panes — detects DONE, WORKING, ERROR, and IDLE states.

## Usage
`/doey-monitor`

## Prompt
You are monitoring the status of all Claude Code worker instances in TMUX.

### Read Project Context

First, discover the runtime directory and source the session manifest:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This gives you:
- `SESSION_NAME` — tmux session name (replaces hardcoded session name)
- `WORKER_PANES` — comma-separated worker pane indices (e.g., "1,2,3,4,5,7,8,9,10,11")
- `WORKER_COUNT`, `WATCHDOG_PANE`, `TOTAL_PANES`, `PROJECT_NAME`, `PROJECT_DIR`

If the manifest is missing, fall back by detecting session name from tmux: `SESSION=$(tmux display-message -p '#S')`.

### Quick Status Check (all workers)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
# Write timestamp for statusbar countdown
date +%s > "${RUNTIME_DIR}/status/last_monitor.ts"
SESSION="${SESSION_NAME}"
PANES="${WORKER_PANES:-1,2,3,4,5,7,8,9,10,11}"
for i in $(echo "$PANES" | tr ',' ' '); do
  echo "=== Worker 0.$i ==="
  tmux capture-pane -t "$SESSION:0.$i" -p -S -5 2>/dev/null || echo "(pane not found)"
  echo ""
done
```

### State Detection

Read the last 5-10 lines of each worker's captured output and classify. **Before classifying output-based states, check for reservations first** — a reserved pane overrides other states:

```bash
# Check reservation status (do this per-pane before output-based detection)
PANE_SAFE="${SESSION}_0_${i}"
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  read -r EXPIRY < "$RESERVE_FILE" 2>/dev/null || EXPIRY=""
  NOW_TS=$(date +%s)
  if [ "$EXPIRY" = "permanent" ]; then
    STATE="RESERVED (permanent)"
  elif [ -n "$EXPIRY" ] && [ "$NOW_TS" -lt "$EXPIRY" ]; then
    REMAINING=$(( EXPIRY - NOW_TS ))
    STATE="RESERVED (${REMAINING}s)"
  fi
fi
```

Output-based states:

| State | How to detect | Display |
|-------|---------------|---------|
| **IDLE** | Shows `❯` prompt, no task text above | `⬚ IDLE` |
| **WORKING** | Shows `thinking`, `working`, tool calls in progress, spinner chars (`✳ ✶ ✻`) | `⏳ WORKING` |
| **DONE** | Shows `Worked for Xs` or `✻ Worked for` followed by `❯` prompt | `✅ DONE` |
| **ERROR** | Shows `Error`, `failed`, `SIGTERM`, or red error text | `❌ ERROR` |
| **QUEUED** | Shows pasted text but no processing started (text visible, no tool calls) | `📋 QUEUED` |
| **RESERVED** | `.reserved` file exists with valid (unexpired) timestamp or "permanent" | `🔒 RESERVED` |

### Output Format

Present a clean status table:

```
Worker Status    Task                      Time
─────  ──────   ─────────────────────────  ─────
W2     ✅ DONE  Overview + tree edits      1m 22s
W3     ✅ DONE  Packages + tech stack      50s
W4     ⏳ WORK  Getting started + scripts  ...
W5     ⬚ IDLE   -                          -
W6     ⬚ IDLE   -                          -
...
```

### Deep Inspect a Single Worker

If the user asks to inspect a specific worker, capture more lines:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -80
```

This shows the full recent history — useful for debugging errors or reviewing completed work.

### Watching (continuous monitoring)

If waiting for workers to finish, use this polling pattern:

1. Check all workers
2. If any are still WORKING, sleep 20-30s and check again
3. Once all are DONE/IDLE/ERROR, report final status

**Do NOT poll more frequently than every 15 seconds** — it wastes tokens.

### Error Recovery

When a worker shows ERROR state:

1. Capture full output: `tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -80`
2. Identify the error type:
   - **Edit conflict** (line numbers shifted) — worker usually auto-retries
   - **File not found** — bad path in task prompt, fix and re-dispatch
   - **Type error** — may need different approach, escalate to user
   - **Timeout/SIGTERM** — task was too large, break it down further
3. If worker is stuck at error with `❯` prompt, it's idle and can be re-tasked

### Rules

1. Never interrupt a WORKING worker
2. Report errors immediately — don't wait for other workers
3. Include timing info when available (workers show "Worked for Xs")
4. If a QUEUED worker hasn't started after 10s, send Enter again
