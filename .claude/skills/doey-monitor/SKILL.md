---
name: doey-monitor
description: Monitor worker panes — reads status files (FINISHED, BUSY, ERROR, READY, RESERVED)
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team config: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; [ -f "$RD/team_${W}.env" ] && cat "$RD/team_${W}.env" 2>/dev/null|| true`
- Worker statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`
- Results: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/results/pane_${W}_*.json; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`
- Crash alerts: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/crash_pane_*; do [ -f "$f" ] && echo "CRASH:" && cat "$f"; done 2>/dev/null || true`
- Watchdog heartbeat: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; HB="$RD/status/watchdog_W${W}.heartbeat"; [ -f "$HB" ] && echo "heartbeat: $(cat $HB) age: $(( $(date +%s) - $(cat $HB) ))s" || echo "No watchdog heartbeat"`
- Pane titles: !`SESSION=$(grep '^SESSION_NAME=' $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2- | tr -d '"'); W="${DOEY_WINDOW_INDEX:-0}"; for p in $(tmux list-panes -t "$SESSION:$W" -F '#{pane_index}' 2>/dev/null); do TITLE=$(tmux display-message -t "$SESSION:$W.$p" -p '#{pane_title}' 2>/dev/null); echo "$W.$p: $TITLE"; done || true`

## Step 1: Build Status Table

Build a summary table from the injected context data above: `PANE | STATUS | RESERVED | TASK | UPDATED`.

For each worker pane (from WORKER_PANES in team config):
- Read status from the `.status` file
- Enrich FINISHED status with result data from the `.json` result file
- Check for `.reserved` flag
- Get task name from pane title
- Show age of the status file

Expected: A formatted table showing all worker panes with their current state.

## Step 2: Deep Inspect a Specific Pane

When deeper investigation is needed for pane X (replace X with the pane index):

bash: PANE="${SESSION_NAME}:${DOEY_WINDOW_INDEX:-0}.X"; PANE_SAFE=$(echo "$PANE" | tr ':.' '_'); cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status" 2>/dev/null || echo "(no status file)"; echo "--- Last 20 lines ---"; tmux capture-pane -t "$PANE" -p -S -20 2>/dev/null || echo "(pane not found)"
Expected: Status file contents followed by last 20 lines of pane output.

**If this fails with "(pane not found)":** The pane may have crashed or been killed. Check crash alerts in the context data above.

**If this fails with "(no status file)":** The worker may not have started yet or the status directory is missing. Verify `${DOEY_RUNTIME}/status/` exists.

## Step 3: Watching Mode (Polling)

Poll every 15 seconds with a `[%H:%M:%S]` timestamp header. Track ALL_DONE state across iterations.

bash: # On each poll cycle, re-read all status files and display the table from Step 1
Expected: Repeating status updates every 15s. Break automatically when all non-reserved workers are FINISHED or READY.

## Step 4: Error Recovery — Unstick a Stuck Pane

When a pane is unresponsive or stuck:

bash: # Exit copy-mode first, then:
tmux send-keys -t "$PANE" C-c
# Wait 0.5s
tmux send-keys -t "$PANE" C-u
# Wait 0.5s
tmux send-keys -t "$PANE" Enter
# Wait 3s, then check for ❯ prompt
Expected: The pane should show a `❯` prompt indicating it is responsive again.

**If this fails after 2 attempts:** Refer to `/doey-dispatch` Unstick section for further recovery.

## Step 5: Error Recovery — Nudge Idle Pane

When a pane appears idle but not explicitly in an error state:

bash: # Exit copy-mode first, then:
tmux send-keys -t "$PANE" Enter
# Wait 5s, then check output
tmux capture-pane -t "$PANE" -p -S -5 2>/dev/null | grep -iE 'thinking|working|Read|Edit|Bash'
Expected: Output indicating the worker is actively processing (thinking, working, or using tools).

**If this fails with no activity detected:** Worker is truly idle. Either unstick (Step 4) or re-dispatch the task.

## Gotchas

- Do NOT interrupt BUSY workers — only recover ERROR or unresponsive panes
- Do NOT parse pane output for status — always read from `.status` files
- Do NOT poll faster than every 15 seconds
- Do NOT send keys without exiting copy-mode first

### Rules
1. **Never interrupt BUSY** — only recover ERROR/unresponsive
2. **Status from files** — never parse pane output
3. **Min 15s poll** | **Always exit copy-mode before send-keys**

Total: 5 commands, 0 errors expected.
