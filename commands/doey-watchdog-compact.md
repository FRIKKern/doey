# Skill: doey-watchdog-compact

Send `/compact` to the Watchdog to reduce its context window.

## Usage
`/doey-watchdog-compact`

## Prompt

### Step 1: Send compact

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
WATCHDOG="${SESSION_NAME}:${WATCHDOG_PANE}"
tmux copy-mode -q -t "$WATCHDOG" 2>/dev/null
tmux send-keys -t "$WATCHDOG" "/compact" Enter
echo "Sent /compact to ${WATCHDOG}"
```

### Step 2: Verify (wait 15s, retry once if no activity)

```bash
sleep 15
OUTPUT=$(tmux capture-pane -t "$WATCHDOG" -p -S -20)
echo "$OUTPUT"
if echo "$OUTPUT" | grep -qiE '(compact|summariz|monitor|check|pane|worker)'; then
  echo "SUCCESS: Watchdog active after compact"
else
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

Report result.
