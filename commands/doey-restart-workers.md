# Skill: doey-restart-workers

Restart all Claude Code worker instances (and the Watchdog) without restarting the Manager (pane 0.0). Uses process-based killing (not keystrokes) and deterministic verify loops.

## Usage
`/doey-restart-workers`

## Prompt

### Steps

1. **Read Project Context** — discover the runtime directory and source the session manifest:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   ```
   This gives you:
   - `SESSION_NAME` — tmux session name
   - `WATCHDOG_PANE` — watchdog pane index
   - `WORKER_PANES` — comma-separated worker pane indices
   - `TOTAL_PANES` — total pane count

   Build the combined pane list for all subsequent steps:
   ```bash
   ALL_PANES="$WATCHDOG_PANE $(echo "$WORKER_PANES" | tr ',' ' ')"
   ```

2. **Phase 1: KILL — Kill Claude processes by PID.** Do NOT use `/exit` or `send-keys` — they are unreliable (Claude may be mid-tool-call, stuck, or unresponsive, and the `/exit` gets silently dropped). Instead, kill the child process of each pane's shell:
   ```bash
   for i in $ALL_PANES; do
     PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
     CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
     if [ -n "$CHILD_PID" ]; then
       kill "$CHILD_PID" 2>/dev/null
     fi
   done
   ```
   Wait for processes to die:
   ```bash
   sleep 3
   ```

3. **Phase 2: VERIFY KILLED — Retry loop confirming no child processes remain.** Run this loop with max 5 attempts, 2 seconds apart. Check using `pgrep` (process-based), NOT by grepping pane output (which is unreliable). If any remain after SIGTERM, escalate to SIGKILL:
   ```bash
   for attempt in 1 2 3 4 5; do
     STILL_RUNNING=0
     STUCK_PANES=""
     for i in $ALL_PANES; do
       PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
       CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
       if [ -n "$CHILD_PID" ]; then
         STILL_RUNNING=$((STILL_RUNNING + 1))
         STUCK_PANES="$STUCK_PANES 0.$i"
         kill -9 "$CHILD_PID" 2>/dev/null
       fi
     done
     if [ "$STILL_RUNNING" -eq 0 ]; then
       break
     fi
     sleep 2
   done
   ```
   After the loop, check `$STILL_RUNNING`. If it is NOT 0, report: "FAILED: Panes $STUCK_PANES still have processes after 5 kill attempts. Manual intervention needed." and STOP here — do not continue.

4. **Phase 3: CLEAR — Clean all pane terminals** so new sessions start fresh:
   ```bash
   for i in $ALL_PANES; do
     tmux send-keys -t "$SESSION_NAME:0.$i" "clear" Enter 2>/dev/null
   done
   sleep 1
   ```

5. **Phase 4: START — Launch all instances.** Start the Watchdog first, then workers with 0.5s gaps:
   ```bash
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "claude --dangerously-skip-permissions --model haiku --agent doey-watchdog" Enter
   sleep 1
   for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
     tmux send-keys -t "$SESSION_NAME:0.$i" "claude --dangerously-skip-permissions --model opus" Enter
     sleep 0.5
   done
   ```

6. **Phase 5: VERIFY STARTED — Retry loop confirming Claude is running in all panes.** Claude can take 30–60s to boot. Run this loop with max 10 attempts, 5 seconds apart. Use `pgrep` to check for a child process, AND capture pane output to confirm Claude's UI is visible. A pane is ready when it has a child process AND `tmux capture-pane -t "$SESSION_NAME:0.$i" -p` (full visible pane, no `-S` flag) contains `bypass permissions`:
   ```bash
   for attempt in 1 2 3 4 5 6 7 8 9 10; do
     NOT_READY=0
     DOWN_PANES=""
     for i in $ALL_PANES; do
       PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
       CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
       OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$i" -p 2>/dev/null)
       if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
         NOT_READY=$((NOT_READY + 1))
         DOWN_PANES="$DOWN_PANES 0.$i"
       fi
     done
     if [ "$NOT_READY" -eq 0 ]; then
       break
     fi
     sleep 5
   done
   ```
   Report which panes came up and which didn't.

7. **Phase 6: INSTRUCT WATCHDOG** — Send the monitoring instruction to the Watchdog pane:
   ```bash
   WORKER_LIST=""
   for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
     [[ -n "$WORKER_LIST" ]] && WORKER_LIST+=", "
     WORKER_LIST+="0.$i"
   done
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "Start monitoring. Total panes: $TOTAL_PANES. Skip pane 0.0 (Manager) and 0.$WATCHDOG_PANE (yourself). Monitor panes ${WORKER_LIST}." Enter
   ```

8. **Phase 7: FINAL REPORT** — Show a clean status table. For each pane in `$ALL_PANES`, use the verified state from Phase 5:
   ```
   Pane    Role        Status
   0.1     Worker      ✅ UP  (or ❌ DOWN)
   0.2     Worker      ✅ UP
   ...
   0.N     Watchdog    ✅ UP
   ```
   Use the Watchdog pane index to label it "Watchdog"; all others are "Worker".

## Important Notes
- Restarting workers clears timed reservations (they expire naturally). Permanent reservations (`.reserved` files with `permanent`) survive restarts.
- NEVER restart pane 0.0 — that's you (the Manager)
- The Watchdog uses `--model haiku --agent doey-watchdog`, workers use `--model opus`
- If a worker shows "Not logged in", run `/login` on it: `tmux send-keys -t "$SESSION_NAME:0.X" "/login" Enter`
- Pane counts and indices are dynamic — always read from the manifest, never hardcode
- If the VERIFY KILLED phase fails, do NOT proceed — report the stuck panes and stop
- All `sleep` durations are intentional — do not shorten them
- **NEVER use `/exit` or `send-keys` to kill Claude** — it is unreliable. Always kill by PID using `pgrep -P #{pane_pid}` + `kill`
- **NEVER use `tmux capture-pane -S -N`** for detection — it captures scroll buffer which may be empty. Use `tmux capture-pane -p` (full visible pane) instead
