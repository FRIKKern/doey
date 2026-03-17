# Skill: doey-monitor

Smart monitoring — one-shot status or continuous watch mode, with crash alerts, deep inspect, and error recovery.

## Usage
`/doey-monitor` — one-shot status + crash alerts
`/doey-monitor watch` — continuous polling (15s interval)
`/doey-monitor deep <W.pane>` — deep inspect a specific worker

## Prompt
You are monitoring all Claude Code worker instances in the Doey team.

### Step 1: Determine mode
- No argument or empty → **One-shot** (Step 2)
- `watch` → **Watch mode** (Step 3)
- `deep <W.pane>` → **Deep inspect** (Step 4)

### Step 2: One-shot monitoring

Run the CLI command:
```bash
doey monitor
```

Present the output. Highlight:
- Any CRASHED or ERROR workers → offer to unstick them (see Error Recovery)
- Stale watchdog heartbeat → warn and suggest checking Watchdog pane
- All workers FINISHED → suggest collecting results
- Any crash alerts shown at the bottom

### Step 3: Watch mode

Run continuous monitoring:
```bash
doey monitor --watch
```

Note: This runs in a loop (15s interval) with crash alerts. It will clear the screen each cycle. Press Ctrl+C to stop.

### Step 4: Deep inspect

For a specific pane (e.g., `1.3`), capture detailed output:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
PANE="${SESSION_NAME}:$WIN.$PANE_NUM"
PANE_SAFE=$(echo "${PANE}" | tr ':.' '_')
echo "=== Deep Inspect: ${PANE} ==="
echo "--- Status file ---"
cat "${RUNTIME_DIR}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"
echo "--- Result file ---"
WIN_IDX="${WIN}"
cat "${RUNTIME_DIR}/results/pane_${WIN_IDX}_${PANE_NUM}.json" 2>/dev/null || echo "(no result file)"
echo "--- Last 20 lines ---"
tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
```

Present findings and suggest actions based on what you see.

### Error Recovery

**Unstick a worker** (ERROR or unresponsive): exit copy-mode, then send `C-c`, wait 0.5s, `C-u`, wait 0.5s, `Enter`, wait 3s, capture output. If `❯` prompt appears, worker recovered. If still stuck after 2 attempts, force-kill and restart — see `/doey-dispatch` **Troubleshooting: Unstick a non-responsive worker**.

**Nudge a dispatched worker** that hasn't started after 10s: exit copy-mode, send `Enter`, wait 5s, check for `thinking|working|Read|Edit|Bash` in captured output. If still idle, use the unstick sequence above or re-dispatch.

### Rules

1. **Never interrupt a BUSY worker** — only recover ERROR or unresponsive workers
2. **Always read status files** from `${RUNTIME_DIR}/status/` — do not parse pane output for state detection
3. **Do NOT poll more frequently than every 15 seconds** in watching mode
4. **Report errors immediately** — capture deep inspect output and include in report
5. **Always exit copy-mode** before sending keys: `tmux copy-mode -q -t "$PANE" 2>/dev/null`
