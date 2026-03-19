# Skill: doey-watchdog-compact

Send `/compact` to the Watchdog to reduce context. Watchdog restores state from `watchdog_pane_states_W${WINDOW_INDEX}.json`.

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
```

### Step 2: Verify (retry once if no activity)

Sleep 15s, capture output. If grep matches `compact|summariz|monitor|check|pane|worker` → success. Otherwise retry `/compact` once more, wait 15s, check again. If still no activity → report manual intervention needed.
