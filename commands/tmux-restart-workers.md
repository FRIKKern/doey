Restart all Claude Code worker instances (and the Watchdog) without restarting the Manager (pane 0.0). Useful when workers get logged out or need a fresh session.

## Steps

1. **Read Project Context** — source the session manifest to get dynamic values:
   ```bash
   cat /tmp/claude-team/session.env
   ```
   Extract these variables for use in all subsequent commands:
   ```bash
   SESSION=$(grep '^SESSION_NAME=' /tmp/claude-team/session.env | cut -d= -f2)
   WD_PANE=$(grep '^WATCHDOG_PANE=' /tmp/claude-team/session.env | cut -d= -f2)
   WORKER_PANES=$(grep '^WORKER_PANES=' /tmp/claude-team/session.env | cut -d= -f2)
   TOTAL_PANES=$(grep '^TOTAL_PANES=' /tmp/claude-team/session.env | cut -d= -f2)
   ```
   Use `$SESSION` for all tmux `-t` targets below. Use `$WD_PANE` for the Watchdog pane index. Use `$WORKER_PANES` (comma-separated) for all worker pane loops.

2. **Discover all panes** (excluding yourself at 0.0):
   ```bash
   tmux list-panes -s -t "$SESSION" -F '#{pane_index} #{pane_title} #{pane_pid}'
   ```
   Confirm the Watchdog and Worker pane indices match the manifest.

3. **Kill all Claude processes in worker + watchdog panes** by sending `/exit` to each:
   ```bash
   # Build list of all non-manager panes (watchdog + workers)
   ALL_PANES="$WD_PANE $(echo "$WORKER_PANES" | tr ',' ' ')"
   for i in $ALL_PANES; do
     tmux send-keys -t "$SESSION:0.$i" "/exit" Enter 2>/dev/null
   done
   ```
   Wait a few seconds for them to exit:
   ```bash
   sleep 5
   ```

4. **Verify they exited** — capture each pane and check for a shell prompt (`$` or `%`):
   ```bash
   for i in $ALL_PANES; do
     echo "=== Pane 0.$i ==="
     tmux capture-pane -t "$SESSION:0.$i" -p -S -3 2>/dev/null
   done
   ```
   If any still show Claude running, send `Ctrl+C` then `/exit`:
   ```bash
   tmux send-keys -t "$SESSION:0.X" C-c
   sleep 1
   tmux send-keys -t "$SESSION:0.X" "/exit" Enter
   ```

5. **Clear all pane terminals** so the new sessions start clean:
   ```bash
   for i in $ALL_PANES; do
     tmux send-keys -t "$SESSION:0.$i" "clear" Enter 2>/dev/null
   done
   sleep 0.5
   ```

6. **Restart the Watchdog pane first**:
   ```bash
   tmux send-keys -t "$SESSION:0.$WD_PANE" "claude --dangerously-skip-permissions --agent tmux-watchdog" Enter
   ```

7. **Restart all Worker panes**:
   ```bash
   for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
     tmux send-keys -t "$SESSION:0.$i" "claude --dangerously-skip-permissions" Enter
     sleep 0.3
   done
   ```

8. **Wait for workers to initialize** (about 10 seconds):
   ```bash
   sleep 10
   ```

9. **Send the Watchdog its monitoring instruction** — tell it which panes to monitor:
   ```bash
   # Build human-readable list of worker panes
   WORKER_LIST=""
   for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
     [[ -n "$WORKER_LIST" ]] && WORKER_LIST+=", "
     WORKER_LIST+="0.$i"
   done
   tmux send-keys -t "$SESSION:0.$WD_PANE" "Start monitoring. Total panes: $TOTAL_PANES. Skip pane 0.0 (Manager) and 0.$WD_PANE (yourself). Monitor panes ${WORKER_LIST}." Enter
   ```

10. **Verify workers are up** — check panes to confirm Claude started:
    ```bash
    sleep 5
    for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
      echo "=== Worker 0.$i ==="
      tmux capture-pane -t "$SESSION:0.$i" -p -S -3 2>/dev/null
    done
    ```

11. **Report results** — show a summary table of each pane and whether it came back online.

## Important Notes
- NEVER restart pane 0.0 — that's you (the Manager)
- The Watchdog uses `--agent tmux-watchdog`, workers use plain `--dangerously-skip-permissions`
- If a worker shows "Not logged in", run `/login` on it: `tmux send-keys -t "$SESSION:0.X" "/login" Enter`
- Pane counts and indices are dynamic — always read from the manifest, never hardcode
