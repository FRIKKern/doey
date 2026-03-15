# Skill: doey-restart-workers

Restart all Claude Code worker instances (and the Watchdog) without restarting the Manager (pane 0.0). Uses process-based killing (not keystrokes) and deterministic verify loops.

## Usage
`/doey-restart-workers`

## Prompt

### Steps

1. **Read Project Context + Check Readiness:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   ALL_PANES="$WATCHDOG_PANE $(echo "$WORKER_PANES" | tr ',' ' ')"
   WORKER_PANES_LIST=$(echo "$WORKER_PANES" | tr ',' ' ')

   # Detect already-ready workers (has child process + "bypass permissions" + prompt visible) — skip them.
   # Watchdog is ALWAYS restarted regardless.
   SKIP_PANES=""
   for i in $WORKER_PANES_LIST; do
     PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
     CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
     OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$i" -p 2>/dev/null)
     if [ -n "$CHILD_PID" ] && echo "$OUTPUT" | grep -q "bypass permissions" && echo "$OUTPUT" | grep -q '❯'; then
       SKIP_PANES="$SKIP_PANES $i"
     fi
   done
   ```

2. **KILL + VERIFY** — Kill Claude processes by PID, then verify. Do NOT use `/exit` or `send-keys` — they are unreliable mid-tool-call. Skip worker panes that are already ready (in `$SKIP_PANES`). Watchdog is always killed.
   ```bash
   # Kill child process of each pane's shell (skip ready workers)
   for i in $ALL_PANES; do
     if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
     PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
     CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
     [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
   done
   sleep 3

   # Verify killed — max 5 attempts, escalate to SIGKILL (only check non-skipped panes)
   for attempt in 1 2 3 4 5; do
     STILL_RUNNING=0; STUCK_PANES=""
     for i in $ALL_PANES; do
       if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
       PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
       CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
       if [ -n "$CHILD_PID" ]; then
         STILL_RUNNING=$((STILL_RUNNING + 1)); STUCK_PANES="$STUCK_PANES 0.$i"
         kill -9 "$CHILD_PID" 2>/dev/null
       fi
     done
     [ "$STILL_RUNNING" -eq 0 ] && break
     sleep 2
   done
   ```
   If `$STILL_RUNNING` != 0 after loop: report "FAILED: Panes $STUCK_PANES still have processes after 5 kill attempts. Manual intervention needed." and **STOP**.

3. **CLEAR** — Clean terminals (skip ready workers):
   ```bash
   for i in $ALL_PANES; do
     if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
     tmux send-keys -t "$SESSION_NAME:0.$i" "clear" Enter 2>/dev/null
   done
   sleep 1
   ```

4. **START + VERIFY** — Launch killed instances, then verify boot. Watchdog first, then workers with 0.5s gaps. Skip workers that were already ready.
   ```bash
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "claude --dangerously-skip-permissions --model haiku --agent doey-watchdog" Enter
   sleep 1
   for i in $WORKER_PANES_LIST; do
     if echo "$SKIP_PANES" | grep -qw "$i"; then continue; fi
     WORKER_PROMPT=$(grep -l "pane 0\.${i} " "${RUNTIME_DIR}/worker-system-prompt-"*.md 2>/dev/null | head -1)
     WORKER_CMD="claude --dangerously-skip-permissions --model opus"
     if [ -n "$WORKER_PROMPT" ]; then
       WORKER_CMD="$WORKER_CMD --append-system-prompt-file \"$WORKER_PROMPT\""
     else
       echo "WARNING: No system prompt file found for pane 0.$i — launching without Doey identity"
     fi
     tmux send-keys -t "$SESSION_NAME:0.$i" "$WORKER_CMD" Enter
     sleep 0.5
   done

   # Verify started — max 10 attempts, 5s apart
   # Ready = child process exists AND visible pane contains "bypass permissions"
   for attempt in 1 2 3 4 5 6 7 8 9 10; do
     NOT_READY=0; DOWN_PANES=""
     for i in $ALL_PANES; do
       PANE_PID=$(tmux display-message -t "$SESSION_NAME:0.$i" -p '#{pane_pid}')
       CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
       OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0.$i" -p 2>/dev/null)
       if [ -z "$CHILD_PID" ] || ! echo "$OUTPUT" | grep -q "bypass permissions"; then
         NOT_READY=$((NOT_READY + 1)); DOWN_PANES="$DOWN_PANES 0.$i"
       fi
     done
     [ "$NOT_READY" -eq 0 ] && break
     sleep 5
   done
   ```

5. **INSTRUCT WATCHDOG** — Build comma-separated worker pane list from `$WORKER_PANES` and send monitoring start command:
   ```bash
   WORKER_LIST=""; for i in $(echo "$WORKER_PANES" | tr ',' ' '); do [[ -n "$WORKER_LIST" ]] && WORKER_LIST+=", "; WORKER_LIST+="0.$i"; done
   tmux send-keys -t "$SESSION_NAME:0.$WATCHDOG_PANE" "Start monitoring. Skip pane 0.0 and 0.$WATCHDOG_PANE. Monitor panes ${WORKER_LIST}." Enter
   ```

6. **FINAL REPORT** — Show status for each pane. Distinguish skipped (already ready) from restarted panes:
   ```
   Pane    Role        Status
   0.1     Worker      ✅ UP (already ready — skipped)
   0.2     Worker      ✅ UP (restarted)
   0.N     Watchdog    ✅ UP (restarted)
   ```
   Use `$WATCHDOG_PANE` to label "Watchdog"; all others are "Worker". Check `$SKIP_PANES` to determine if a worker was skipped or restarted.

## Important Notes
- Restarting clears timed reservations; permanent ones (`.reserved` with `permanent`) survive
- NEVER restart pane 0.0 — that's the Manager
- Watchdog: `--model haiku --agent doey-watchdog`, Workers: `--model opus`
- If "Not logged in" appears, run `/login`: `tmux send-keys -t "$SESSION_NAME:0.X" "/login" Enter`
- Pane indices are dynamic — always read from manifest, never hardcode
- If VERIFY KILLED fails, do NOT proceed
- All `sleep` durations are intentional — do not shorten
- **NEVER use `/exit` or `send-keys` to kill Claude** — always kill by PID
- **NEVER use `tmux capture-pane -S -N`** for detection — use `-p` (full visible pane)
