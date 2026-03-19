# Skill: doey-list-windows

List all team windows with their status.

## Usage
`/doey-list-windows`

## Prompt

List all team windows. Read-only — never modify files or processes.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

# Check if a pane is running Claude (not just a shell)
is_up() { case "$1" in bash|zsh|sh|fish|"") return 1 ;; *) return 0 ;; esac; }

echo "Session: ${SESSION_NAME}"
echo ""
echo "WINDOW  GRID    MGR     WDG         WORKERS"
echo "------  ------  ------  ----------  -------"

for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do
  # Window 0 = Dashboard
  if [ "$w" = "0" ]; then
    SM_CMD=$(tmux display-message -t "${SESSION_NAME}:0.1" -p '#{pane_current_command}' 2>/dev/null) || SM_CMD=""
    SM_STATUS="—"; is_up "$SM_CMD" && SM_STATUS="UP"
    printf "%-7s %-7s %-7s %-11s %s\n" "0" "—" "—" "—" "Dashboard (Session Mgr: ${SM_STATUS})"
    continue
  fi

  # Load team env
  TEAM_ENV="${RUNTIME_DIR}/team_${w}.env"
  GRID="" WORKER_PANES="" WATCHDOG_PANE="" WORKER_COUNT=""
  if [ -f "$TEAM_ENV" ]; then
    while IFS='=' read -r key value; do
      value="${value%\"}" && value="${value#\"}"
      case "$key" in
        GRID) GRID="$value" ;; WORKER_PANES) WORKER_PANES="$value" ;;
        WATCHDOG_PANE) WATCHDOG_PANE="$value" ;; WORKER_COUNT) WORKER_COUNT="$value" ;;
      esac
    done < "$TEAM_ENV"
  else
    GRID="unknown" WORKER_PANES="" WATCHDOG_PANE="0.1" WORKER_COUNT="0"
  fi

  # Worktree badge
  WT_BADGE="" WT_BRANCH_INFO=""
  WT_DIR=$(grep '^WORKTREE_DIR=' "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2-)
  WT_DIR="${WT_DIR%\"}" && WT_DIR="${WT_DIR#\"}"
  if [ -n "$WT_DIR" ]; then
    WT_BADGE=" [worktree]"
    WT_BRANCH=$(grep '^WORKTREE_BRANCH=' "$TEAM_ENV" 2>/dev/null | head -1 | cut -d= -f2-)
    WT_BRANCH="${WT_BRANCH%\"}" && WT_BRANCH="${WT_BRANCH#\"}"
    [ -n "$WT_BRANCH" ] && WT_BRANCH_INFO="  branch: $WT_BRANCH"
  fi

  # Manager status
  MGR_CMD=$(tmux display-message -t "${SESSION_NAME}:${w}.0" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
  MGR_STATUS="DOWN"; is_up "$MGR_CMD" && MGR_STATUS="UP"

  # Watchdog status
  WDG_STATUS="?"
  if [ -n "$WATCHDOG_PANE" ]; then
    WDG_CMD=$(tmux display-message -t "${SESSION_NAME}:${WATCHDOG_PANE}" -p '#{pane_current_command}' 2>/dev/null) || WDG_CMD=""
    if is_up "$WDG_CMD"; then
      HEARTBEAT=$(cat "${RUNTIME_DIR}/status/watchdog_W${w}.heartbeat" 2>/dev/null) || HEARTBEAT="0"
      BEAT_AGE=$(($(date +%s) - HEARTBEAT))
      if [ "$BEAT_AGE" -gt 120 ]; then WDG_STATUS="STALE(${BEAT_AGE}s)"; else WDG_STATUS="OK"; fi
    else
      WDG_STATUS="DOWN"
    fi
  fi

  # Worker busy count
  BUSY=0 TOTAL="${WORKER_COUNT:-0}"
  SAFE=$(echo "$SESSION_NAME" | tr ':.' '_')
  for i in $(echo "$WORKER_PANES" | tr ',' ' '); do
    [ -f "${RUNTIME_DIR}/status/${SAFE}_${w}_${i}.status" ] && \
      grep -q '^STATUS: BUSY' "${RUNTIME_DIR}/status/${SAFE}_${w}_${i}.status" && BUSY=$((BUSY + 1))
  done

  printf "%-7s %-7s %-7s %-11s %s (%s busy, %s idle)%s%s\n" \
    "$w" "$GRID" "$MGR_STATUS" "$WDG_STATUS" "$TOTAL" "$BUSY" "$((TOTAL - BUSY))" "$WT_BADGE" "$WT_BRANCH_INFO"
done
```

### Rules
- Read-only — never modify files or processes
- Window 0 = Dashboard; fall back gracefully if team env missing
- Watchdog heartbeat >120s = stale
