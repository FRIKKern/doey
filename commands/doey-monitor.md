# Skill: doey-monitor

Smart monitoring of all worker panes — detects DONE, WORKING, ERROR, and IDLE states.

## Usage
`/doey-monitor`

## Prompt
You are monitoring the status of all Claude Code worker instances in TMUX.

### Read Project Context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This gives you `SESSION_NAME`, `WORKER_PANES`, `WORKER_COUNT`, `WATCHDOG_PANE`, `TOTAL_PANES`, `PROJECT_NAME`, `PROJECT_DIR`. If missing, fall back: `SESSION=$(tmux display-message -p '#S')`.

### Quick Status Check

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
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

**Before output-based detection, check reservations per pane:**
```bash
PANE_SAFE="${SESSION}_0_${i}"
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  read -r EXPIRY < "$RESERVE_FILE" 2>/dev/null || EXPIRY=""
  NOW_TS=$(date +%s)
  if [ "$EXPIRY" = "permanent" ]; then STATE="RESERVED (permanent)"
  elif [ -n "$EXPIRY" ] && [ "$NOW_TS" -lt "$EXPIRY" ]; then STATE="RESERVED ($((EXPIRY-NOW_TS))s)"
  fi
fi
```

**Output-based states** (from last 5-10 lines):

| State | Detection | Display |
|-------|-----------|---------|
| IDLE | `❯` prompt, no task text | `⬚ IDLE` |
| WORKING | `thinking`/`working`/tool calls/spinners (`✳ ✶ ✻`) | `⏳ WORKING` |
| DONE | `Worked for Xs` or `✻ Worked for` + `❯` | `✅ DONE` |
| ERROR | `Error`/`failed`/`SIGTERM`/red text | `❌ ERROR` |
| QUEUED | Pasted text visible, no processing | `📋 QUEUED` |
| RESERVED | `.reserved` file with valid/unexpired entry | `🔒 RESERVED` |

### Output Format

```
Worker Status    Task                      Time
─────  ──────   ─────────────────────────  ─────
W2     ✅ DONE  Overview + tree edits      1m 22s
W3     ⏳ WORK  Getting started + scripts  ...
W4     ⬚ IDLE   -                          -
```

### Deep Inspect

For a specific worker: `tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -80`

### Watching (continuous)

1. Check all workers
2. If any WORKING, sleep 20-30s and recheck
3. Once all DONE/IDLE/ERROR, report final status

**Do NOT poll more frequently than every 15 seconds.**

### Error Recovery

On ERROR: capture full output (`-S -80`), identify type (edit conflict → auto-retry, file not found → fix path, type error → escalate, timeout → break down task). If worker shows `❯` after error, it's idle and can be re-tasked.

### Rules

1. Never interrupt a WORKING worker
2. Report errors immediately
3. Include timing info when available
4. If QUEUED worker hasn't started after 10s, send Enter again
