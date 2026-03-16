# Skill: doey-watchdog-compact

Send `/compact` to the Watchdog to reduce its context window. After compaction, the watchdog restores pane state from `watchdog_pane_states_W${WINDOW_INDEX}.json` in the runtime status directory. Monitoring uses a shell pre-filter (`watchdog-scan.sh`) to minimize per-cycle token usage.

## Usage
`/doey-watchdog-compact`

## Prompt
Send `/compact` to the Watchdog and verify it resumes monitoring.

### Step 1: Send compact command

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
WATCHDOG="${SESSION_NAME}:${WINDOW_INDEX}.${WATCHDOG_PANE}"

tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
tmux send-keys -t "$WATCHDOG" "/compact" Enter
echo "Sent /compact to Watchdog pane ${WATCHDOG}"
```

### Step 2: Wait and verify output

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
WATCHDOG="${SESSION_NAME}:${WINDOW_INDEX}.${WATCHDOG_PANE}"

sleep 15
OUTPUT=$(tmux capture-pane -t "$WATCHDOG" -p -S -20)
echo "$OUTPUT"

if echo "$OUTPUT" | grep -qiE '(compact|summariz|monitor|check|pane|worker)'; then
  echo "---"
  echo "SUCCESS: Watchdog shows activity after compact"
else
  echo "---"
  echo "RETRY: No activity detected — re-sending /compact to Watchdog"
  tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
  tmux send-keys -t "$WATCHDOG" "/compact" Enter
  sleep 15
  OUTPUT=$(tmux capture-pane -t "$WATCHDOG" -p -S -20)
  echo "$OUTPUT"
  if echo "$OUTPUT" | grep -qiE '(compact|summariz|monitor|check|pane|worker)'; then
    echo "SUCCESS: Watchdog resumed after retry"
  else
    echo "FAILED: Watchdog not responding — manual intervention needed"
  fi
fi
```

Report the result. Success means the Watchdog pane shows new monitoring output within 15 seconds of compact.
