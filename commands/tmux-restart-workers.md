Restart all Claude Code worker instances (and the Watchdog) without restarting the Manager (pane 0.0). Useful when workers get logged out or need a fresh session.

## Steps

1. **Discover all panes** (excluding yourself at 0.0):
   ```bash
   tmux list-panes -s -t claude-team -F '#{pane_index} #{pane_title} #{pane_pid}'
   ```
   Identify which pane is the Watchdog (title contains "Watchdog" or "tmux-watchdog") and which are Workers. Note the watchdog pane number.

2. **Kill all Claude processes in worker + watchdog panes** by sending `/exit` to each:
   ```bash
   for i in $(seq 1 11); do
     tmux send-keys -t claude-team:0.$i "/exit" Enter 2>/dev/null
   done
   ```
   Wait for them to exit:
   ```bash
   sleep 5
   ```

3. **Verify they exited** — capture each pane and check for a shell prompt (`$` or `%`):
   ```bash
   for i in $(seq 1 11); do
     echo "=== Pane 0.$i ==="
     tmux capture-pane -t "claude-team:0.$i" -p -S -3 2>/dev/null
   done
   ```
   If any still show Claude running, send `Ctrl+C` then `/exit`:
   ```bash
   tmux send-keys -t claude-team:0.X C-c
   sleep 1
   tmux send-keys -t claude-team:0.X "/exit" Enter
   ```

4. **Clear all pane terminals** so the new sessions start clean:
   ```bash
   for i in $(seq 1 11); do
     tmux send-keys -t "claude-team:0.$i" "clear" Enter 2>/dev/null
   done
   sleep 0.5
   ```

5. **Restart the Watchdog pane first** (the pane with "Watchdog" in its title — typically pane 0.6 but confirm from step 1):
   ```bash
   WATCHDOG_PANE=6  # adjust based on step 1
   tmux send-keys -t "claude-team:0.$WATCHDOG_PANE" "claude --dangerously-skip-permissions --agent tmux-watchdog" Enter
   ```

6. **Restart all Worker panes** (every pane except 0.0 and the Watchdog):
   ```bash
   for i in $(seq 1 11); do
     [[ $i -eq $WATCHDOG_PANE ]] && continue
     tmux send-keys -t "claude-team:0.$i" "claude --dangerously-skip-permissions" Enter
     sleep 0.3
   done
   ```

7. **Wait for workers to initialize** (about 10 seconds):
   ```bash
   sleep 10
   ```

8. **Send the Watchdog its monitoring instruction**:
   ```bash
   WORKER_LIST=""
   for i in $(seq 1 11); do
     [[ $i -eq $WATCHDOG_PANE ]] && continue
     [[ -n "$WORKER_LIST" ]] && WORKER_LIST+=", "
     WORKER_LIST+="0.$i"
   done
   tmux send-keys -t "claude-team:0.$WATCHDOG_PANE" "Start monitoring. Total panes: 12. Skip pane 0.0 (Manager) and 0.$WATCHDOG_PANE (yourself). Monitor panes ${WORKER_LIST}." Enter
   ```

9. **Verify workers are up** — check panes to confirm Claude started:
   ```bash
   sleep 5
   for i in $(seq 1 11); do
     [[ $i -eq $WATCHDOG_PANE ]] && continue
     echo "=== Worker 0.$i ==="
     tmux capture-pane -t "claude-team:0.$i" -p -S -3 2>/dev/null
   done
   ```

10. **Report results** — show a summary table of each pane and whether it came back online.

## Important Notes
- NEVER restart pane 0.0 — that's you (the Manager)
- The Watchdog uses `--agent tmux-watchdog`, workers use plain `--dangerously-skip-permissions`
- If a worker shows "Not logged in", run `/login` on it: `tmux send-keys -t claude-team:0.X "/login" Enter`
- The number of panes may vary — always discover dynamically from step 1
