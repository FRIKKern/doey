# Skill: doey-list-windows

List all team windows in the current Doey session with their status.

## Usage
`/doey-list-windows`

## Prompt
You are listing all team windows in the current Doey session.

### Step 1: Read context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

### Step 2: Discover all windows and collect status

```bash
# (vars from step 1)

echo "Session: ${SESSION_NAME}"
echo ""
echo "WINDOW  GRID    MGR     WDG         WORKERS"
echo "------  ------  ------  ----------  -------"

WINDOWS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null)

for w in $WINDOWS; do
  if [ "$w" = "0" ]; then
    SM_CMD=$(tmux display-message -t "${SESSION_NAME}:0.1" -p '#{pane_current_command}' 2>/dev/null) || SM_CMD=""
    case "$SM_CMD" in
      bash|zsh|sh|fish|"") SM_STATUS="—" ;;
      *) SM_STATUS="UP" ;;
    esac
    printf "%-7s %-7s %-7s %-11s %s\n" \
      "0" "—" "—" "—" "Dashboard (Session Mgr: ${SM_STATUS})"
    continue
  fi

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
    W_GRID="unknown"; W_WORKER_PANES=""; W_WATCHDOG="0.1"; W_WORKER_COUNT="0"
  fi

  # Check for worktree
  _wt_badge=""
  _wt_branch_info=""
  if [ -f "${RUNTIME_DIR}/team_${w}.env" ]; then
    _wt_dir=$(grep '^WORKTREE_DIR=' "${RUNTIME_DIR}/team_${w}.env" 2>/dev/null | head -1 | cut -d= -f2-)
    _wt_dir="${_wt_dir%\"}"
    _wt_dir="${_wt_dir#\"}"
    if [ -n "$_wt_dir" ]; then
      _wt_badge=" [worktree]"
      _wt_branch=$(grep '^WORKTREE_BRANCH=' "${RUNTIME_DIR}/team_${w}.env" 2>/dev/null | head -1 | cut -d= -f2-)
      _wt_branch="${_wt_branch%\"}"
      _wt_branch="${_wt_branch#\"}"
      [ -n "$_wt_branch" ] && _wt_branch_info="  branch: $_wt_branch"
    fi
  fi

  MGR_CMD=$(tmux display-message -t "${SESSION_NAME}:${w}.0" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
  case "$MGR_CMD" in
    bash|zsh|sh|fish) MGR_STATUS="DOWN" ;;
    *) MGR_STATUS="UP" ;;
  esac

  WDG_STATUS="?"
  if [ -n "$W_WATCHDOG" ]; then
    WDG_CMD=$(tmux display-message -t "${SESSION_NAME}:${W_WATCHDOG}" -p '#{pane_current_command}' 2>/dev/null) || WDG_CMD=""
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

  BUSY_COUNT=0
  TOTAL_W="${W_WORKER_COUNT:-0}"
  SESSION_SAFE=$(echo "$SESSION_NAME" | tr ':.' '_')
  for i in $(echo "$W_WORKER_PANES" | tr ',' ' '); do
    PANE_SAFE="${SESSION_SAFE}_${w}_${i}"
    STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if [ -f "$STATUS_FILE" ] && grep -q '^STATUS: BUSY' "$STATUS_FILE"; then
      BUSY_COUNT=$((BUSY_COUNT + 1))
    fi
  done

  IDLE_COUNT=$((TOTAL_W - BUSY_COUNT))

  printf "%-7s %-7s %-7s %-11s %s (%s busy, %s idle)%s%s\n" \
    "$w" "$W_GRID" "$MGR_STATUS" "$WDG_STATUS" "$TOTAL_W" "$BUSY_COUNT" "$IDLE_COUNT" "$_wt_badge" "$_wt_branch_info"
done
```

### Rules
- **Read-only** — never modifies files or processes
- Window 0 is always Dashboard. Fall back gracefully if team_W.env missing.
- Check watchdog heartbeat age: >120s = stale. All bash must be 3.2 compatible.
