# Skill: doey-list-windows

List all team windows with their status.

## Usage
`/doey-list-windows`

## Prompt

List all team windows. Read-only — never modify files or processes.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

is_up() { case "$1" in bash|zsh|sh|fish|"") return 1 ;; *) return 0 ;; esac; }
pane_cmd() { tmux display-message -t "$1" -p '#{pane_current_command}' 2>/dev/null; }
env_val() { grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }

echo "Session: ${SESSION_NAME}"
echo ""
printf "%-7s %-7s %-7s %-11s %s\n" "WINDOW" "GRID" "MGR" "WDG" "WORKERS"
printf "%-7s %-7s %-7s %-11s %s\n" "------" "------" "------" "----------" "-------"

for w in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null); do
  if [ "$w" = "0" ]; then
    SM_STATUS="—"; is_up "$(pane_cmd "${SESSION_NAME}:0.1")" && SM_STATUS="UP"
    printf "%-7s %-7s %-7s %-11s %s\n" "0" "—" "—" "—" "Dashboard (Session Mgr: ${SM_STATUS})"
    continue
  fi

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
  WT_DIR=$(env_val "$TEAM_ENV" WORKTREE_DIR)
  if [ -n "$WT_DIR" ]; then
    WT_BADGE=" [worktree]"
    WT_BRANCH=$(env_val "$TEAM_ENV" WORKTREE_BRANCH)
    [ -n "$WT_BRANCH" ] && WT_BRANCH_INFO="  branch: $WT_BRANCH"
  fi

  MGR_STATUS="DOWN"; is_up "$(pane_cmd "${SESSION_NAME}:${w}.0")" && MGR_STATUS="UP"

  WDG_STATUS="?"
  if [ -n "$WATCHDOG_PANE" ]; then
    if is_up "$(pane_cmd "${SESSION_NAME}:${WATCHDOG_PANE}")"; then
      HEARTBEAT=$(cat "${RUNTIME_DIR}/status/watchdog_W${w}.heartbeat" 2>/dev/null) || HEARTBEAT="0"
      BEAT_AGE=$(($(date +%s) - HEARTBEAT))
      [ "$BEAT_AGE" -gt 120 ] && WDG_STATUS="STALE(${BEAT_AGE}s)" || WDG_STATUS="OK"
    else WDG_STATUS="DOWN"; fi
  fi

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
- **Read-only** — never modify files or processes
- Window 0 = Dashboard; graceful fallback if team env missing
