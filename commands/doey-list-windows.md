# Skill: doey-list-windows

List all team windows in the current Doey session with their status.

## Usage
`/doey-list-windows`

## Prompt
You are listing all team windows in the current Doey session.

### Project Context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

### Step 1: Discover all windows and collect status

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

echo "Session: ${SESSION_NAME}"
echo ""
echo "WINDOW  GRID    MGR     WDG         WORKERS"
echo "------  ------  ------  ----------  -------"

WINDOWS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null)

for w in $WINDOWS; do
  TEAM_ENV="${RUNTIME_DIR}/team_${w}.env"
  W_GRID="" W_WORKER_PANES="" W_WATCHDOG="" W_WORKER_COUNT=""

  if [ -f "$TEAM_ENV" ]; then
    while IFS='=' read -r key value; do
      value="${value%\"}" && value="${value#\"}"
      case "$key" in
        GRID) W_GRID="$value" ;;
        WORKER_PANES) W_WORKER_PANES="$value" ;;
        WATCHDOG_PANE) W_WATCHDOG="$value" ;;
        WORKER_COUNT) W_WORKER_COUNT="$value" ;;
      esac
    done < "$TEAM_ENV"
  else
    # Fallback for window 0 without team file
    W_GRID="${GRID:-unknown}"
    W_WORKER_PANES="${WORKER_PANES:-}"
    W_WATCHDOG="${WATCHDOG_PANE:-1}"
    W_WORKER_COUNT="${WORKER_COUNT:-0}"
  fi

  # Window Manager status
  MGR_CMD=$(tmux display-message -t "${SESSION_NAME}:${w}.0" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
  case "$MGR_CMD" in
    bash|zsh|sh|fish) MGR_STATUS="DOWN" ;;
    *) MGR_STATUS="UP" ;;
  esac

  # Watchdog status (check heartbeat age)
  WDG_STATUS="?"
  if [ -n "$W_WATCHDOG" ]; then
    WDG_CMD=$(tmux display-message -t "${SESSION_NAME}:${w}.${W_WATCHDOG}" -p '#{pane_current_command}' 2>/dev/null) || WDG_CMD=""
    case "$WDG_CMD" in
      bash|zsh|sh|fish) WDG_STATUS="DOWN" ;;
      *)
        HEARTBEAT=$(cat "${RUNTIME_DIR}/status/watchdog_W${w}.heartbeat" 2>/dev/null) || HEARTBEAT="0"
        NOW=$(date +%s)
        BEAT_AGE=$((NOW - HEARTBEAT))
        if [ "$BEAT_AGE" -gt 120 ]; then
          WDG_STATUS="STALE(${BEAT_AGE}s)"
        else
          WDG_STATUS="OK"
        fi
        ;;
    esac
  fi

  # Worker status: count busy vs total
  BUSY_COUNT=0
  TOTAL_W="${W_WORKER_COUNT:-0}"
  SESSION_SAFE="${SESSION_NAME//[:.]/_}"
  for i in $(echo "$W_WORKER_PANES" | tr ',' ' '); do
    PANE_SAFE="${SESSION_SAFE}_${w}_${i}"
    STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if [ -f "$STATUS_FILE" ] && grep -q '^STATUS: BUSY' "$STATUS_FILE"; then
      BUSY_COUNT=$((BUSY_COUNT + 1))
    fi
  done

  IDLE_COUNT=$((TOTAL_W - BUSY_COUNT))

  printf "%-7s %-7s %-7s %-11s %s (%s busy, %s idle)\n" \
    "$w" "$W_GRID" "$MGR_STATUS" "$WDG_STATUS" "$TOTAL_W" "$BUSY_COUNT" "$IDLE_COUNT"
done
```

### Rules
- **Read-only operation** — this command never modifies any files or processes
- **Fall back gracefully** if team_W.env doesn't exist (window 0 may use session.env)
- **Check watchdog heartbeat age** to detect stale watchdogs (>120s = stale)
- All bash must be 3.2 compatible
