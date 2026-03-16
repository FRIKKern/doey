#!/bin/bash
# Doey Info Panel — full-width two-column dashboard for window 0
# Displays team status, worker counts, recent events, and usage guide.
# Runs in a loop, refreshing every 5 seconds.
set -euo pipefail

RUNTIME_DIR="${1:-${DOEY_RUNTIME:-}}"
if [ -z "$RUNTIME_DIR" ]; then
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
fi
if [ -z "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ]; then
  printf "Doey Info Panel: waiting for runtime directory...\n"
  while true; do
    sleep 5
    RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
    [ -n "$RUNTIME_DIR" ] && [ -d "$RUNTIME_DIR" ] && break
  done
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"

# ── ANSI Color Helpers ──────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_MAGENTA='\033[35m'
C_WHITE='\033[97m'
C_GRAY='\033[90m'
C_BOLD_CYAN='\033[1;36m'
C_BOLD_WHITE='\033[1;97m'
C_BOLD_GREEN='\033[1;32m'
C_BOLD_YELLOW='\033[1;33m'
C_BOLD_RED='\033[1;31m'
C_BOLD_MAGENTA='\033[1;35m'
C_BG_CYAN='\033[46m'
C_BG_GRAY='\033[100m'

# ── Existing Data-Gathering Functions (unchanged) ───────────────────

# Single-pass env file reader: reads all needed keys in one loop (0 forks).
# Sets variables named _ENV_<KEY> for each requested key.
# Usage: read_env_file <file> KEY1 KEY2 ...
read_env_file() {
  local _ref_file="$1"; shift
  # Clear output vars
  for _ref_k in "$@"; do eval "_ENV_${_ref_k}=''"; done
  [ -f "$_ref_file" ] || return 0
  while IFS='=' read -r _ref_key _ref_val; do
    _ref_val="${_ref_val%\"}" && _ref_val="${_ref_val#\"}"
    for _ref_k in "$@"; do
      [ "$_ref_key" = "$_ref_k" ] && eval "_ENV_${_ref_k}=\"\$_ref_val\"" && break
    done
  done < "$_ref_file"
}

# Format seconds into human-readable uptime
format_uptime() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%dm' "$(( secs / 60 ))"
  elif [ "$secs" -lt 86400 ]; then
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    printf '%dh%dm' "$h" "$m"
  else
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    printf '%dd%dh' "$d" "$h"
  fi
}

# Count workers in a given state for a team (0 forks — pure shell)
# Uses cached SESSION_NAME from outer scope
count_team_workers() {
  local window="$1" worker_panes="$2" state="$3"
  local count=0
  for p in $(echo "$worker_panes" | tr ',' ' '); do
    local pane_safe="${_CACHED_SESSION_NAME}_${window}_${p}"
    local status_file="${RUNTIME_DIR}/status/${pane_safe}.status"
    if [ -f "$status_file" ]; then
      local pane_status=""
      while IFS= read -r _sw_line; do
        case "$_sw_line" in
          STATUS:*) pane_status="${_sw_line#STATUS: }"; break ;;
        esac
      done < "$status_file"
      case "$state" in
        idle)
          case "$pane_status" in READY|FINISHED) count=$((count + 1)) ;; esac
          ;;
        busy)
          case "$pane_status" in BUSY|WORKING) count=$((count + 1)) ;; esac
          ;;
        reserved)
          case "$pane_status" in RESERVED) count=$((count + 1)) ;; esac
          ;;
      esac
    else
      # No status file = idle (freshly started)
      case "$state" in idle) count=$((count + 1)) ;; esac
    fi
  done
  printf '%d' "$count"
}

# ── Column Rendering Helpers ────────────────────────────────────────

# Strip ANSI escape codes for visible-length counting
strip_ansi() {
  # Use sed to remove ANSI escape sequences
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

# Get visible length of a string (excluding ANSI codes)
visible_len() {
  local stripped
  stripped=$(strip_ansi "$1")
  printf '%d' "${#stripped}"
}

# Add a line to the left column
add_left() {
  eval "L_${LC}=\"\$1\""
  LC=$((LC + 1))
}

# Add a line to the right column
add_right() {
  eval "R_${RC}=\"\$1\""
  RC=$((RC + 1))
}

# Generate dotted leader between name and description, fitting within width
# Usage: dotted_leader "name" "description" max_width [color]
dotted_leader() {
  local name="$1" desc="$2" max_w="$3" color="${4:-}"
  local name_vis desc_vis
  name_vis=$(visible_len "$name")
  desc_vis=$(visible_len "$desc")
  local dots_needed=$((max_w - name_vis - desc_vis - 2))
  if [ "$dots_needed" -lt 2 ]; then
    dots_needed=2
  fi
  local dots=""
  local d=0
  while [ "$d" -lt "$dots_needed" ]; do
    dots="${dots}."
    d=$((d + 1))
  done
  if [ -n "$color" ]; then
    printf '%b%s %b%s%b %s' "$color" "$name" "${C_DIM}" "$dots" "${C_RESET}" "$desc"
  else
    printf '%s %b%s%b %s' "$name" "${C_DIM}" "$dots" "${C_RESET}" "$desc"
  fi
}

# ── Cache ───────────────────────────────────────────────────────────
_CACHED_SESSION_NAME=""
_CACHED_PROJECT_NAME=""

# ── Main Loop ───────────────────────────────────────────────────────
while true; do
  # Clear screen
  printf '\033[2J\033[H'

  # Wait for session.env
  if [ ! -f "$SESSION_ENV" ]; then
    printf 'Doey Info Panel: waiting for session.env...\n'
    sleep 5
    continue
  fi

  # Detect terminal dimensions
  TERM_W=$(tput cols 2>/dev/null || echo 120)
  TERM_H=$(tput lines 2>/dev/null || echo 40)
  # Minimum width guard
  if [ "$TERM_W" -lt 80 ]; then
    TERM_W=80
  fi

  # Column widths
  LEFT_W=$((TERM_W * 55 / 100))
  RIGHT_W=$((TERM_W - LEFT_W - 3))  # 3 for " │ " gutter

  # Read session info (single-pass, cached for stable keys)
  if [ -z "$_CACHED_SESSION_NAME" ]; then
    read_env_file "$SESSION_ENV" SESSION_NAME PROJECT_NAME TEAM_WINDOWS
    _CACHED_SESSION_NAME="$_ENV_SESSION_NAME"
    _CACHED_PROJECT_NAME="$_ENV_PROJECT_NAME"
    TEAM_WINDOWS="$_ENV_TEAM_WINDOWS"
  else
    # Only re-read TEAM_WINDOWS (can change when windows are added/removed)
    read_env_file "$SESSION_ENV" TEAM_WINDOWS
    TEAM_WINDOWS="$_ENV_TEAM_WINDOWS"
  fi
  PROJECT_NAME="$_CACHED_PROJECT_NAME"
  SESSION_NAME="$_CACHED_SESSION_NAME"

  # Calculate uptime from session.env mtime
  NOW=$(date +%s)
  if [ -f "$SESSION_ENV" ]; then
    # macOS stat vs Linux stat
    if stat -f '%m' "$SESSION_ENV" >/dev/null 2>&1; then
      START_TIME=$(stat -f '%m' "$SESSION_ENV")
    else
      START_TIME=$(stat -c '%Y' "$SESSION_ENV" 2>/dev/null || echo "$NOW")
    fi
  else
    START_TIME="$NOW"
  fi
  UPTIME_SECS=$((NOW - START_TIME))
  UPTIME_STR=$(format_uptime "$UPTIME_SECS")

  # ── Gather Team Data ──────────────────────────────────────────────
  TEAM_COUNT=0
  TOTAL_WORKERS=0
  TOTAL_IDLE=0
  TOTAL_BUSY=0
  TOTAL_RESERVED=0
  TEAM_LINE_COUNT=0

  if [ -n "$TEAM_WINDOWS" ]; then
    for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
      TEAM_COUNT=$((TEAM_COUNT + 1))
      TEAM_FILE="${RUNTIME_DIR}/team_${W}.env"

      read_env_file "$TEAM_FILE" WATCHDOG_PANE WORKER_PANES WORKER_COUNT GRID_MODE
      WD_PANE="$_ENV_WATCHDOG_PANE"
      WORKER_PANES="$_ENV_WORKER_PANES"
      WORKER_COUNT="$_ENV_WORKER_COUNT"
      GRID_MODE="$_ENV_GRID_MODE"
      [ -z "$WORKER_COUNT" ] && WORKER_COUNT=0
      [ -z "$GRID_MODE" ] && GRID_MODE="dynamic"
      TOTAL_WORKERS=$((TOTAL_WORKERS + WORKER_COUNT))

      # Window Manager status
      MGR_STATUS_FILE="${RUNTIME_DIR}/status/${SESSION_NAME}_${W}_0.status"
      MGR_ST="?"
      if [ -f "$MGR_STATUS_FILE" ]; then
        while IFS= read -r _ms_line; do
          case "$_ms_line" in STATUS:*) MGR_ST="${_ms_line#STATUS: }"; break ;; esac
        done < "$MGR_STATUS_FILE"
      fi

      # Watchdog heartbeat
      WDG_ST="?"
      HEARTBEAT_FILE="${RUNTIME_DIR}/status/watchdog_W${W}.heartbeat"
      [ ! -f "$HEARTBEAT_FILE" ] && HEARTBEAT_FILE="${RUNTIME_DIR}/status/watchdog.heartbeat"
      if [ -f "$HEARTBEAT_FILE" ]; then
        BEAT=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
        BEAT_AGE=$((NOW - BEAT))
        if [ "$BEAT_AGE" -lt 120 ]; then
          WDG_ST="OK"
        else
          WDG_ST="STALE"
        fi
      fi

      # Worker counts by state
      IDLE_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "idle")
      BUSY_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "busy")
      RESV_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "reserved")
      TOTAL_IDLE=$((TOTAL_IDLE + IDLE_COUNT))
      TOTAL_BUSY=$((TOTAL_BUSY + BUSY_COUNT))
      TOTAL_RESERVED=$((TOTAL_RESERVED + RESV_COUNT))

      # Store team data in indexed variables
      eval "TEAM_WIN_${TEAM_LINE_COUNT}=\"${W}\""
      eval "TEAM_MGR_${TEAM_LINE_COUNT}=\"${MGR_ST}\""
      eval "TEAM_WDG_${TEAM_LINE_COUNT}=\"${WDG_ST}\""
      eval "TEAM_IDLE_${TEAM_LINE_COUNT}=\"${IDLE_COUNT}\""
      eval "TEAM_BUSY_${TEAM_LINE_COUNT}=\"${BUSY_COUNT}\""
      eval "TEAM_RESV_${TEAM_LINE_COUNT}=\"${RESV_COUNT}\""
      eval "TEAM_WCNT_${TEAM_LINE_COUNT}=\"${WORKER_COUNT}\""
      eval "TEAM_GRID_${TEAM_LINE_COUNT}=\"${GRID_MODE}\""
      TEAM_LINE_COUNT=$((TEAM_LINE_COUNT + 1))
    done
  else
    # Single-window fallback
    TEAM_COUNT=1
    read_env_file "$SESSION_ENV" WORKER_COUNT WORKER_PANES GRID_MODE
    WORKER_COUNT="$_ENV_WORKER_COUNT"
    WORKER_PANES="$_ENV_WORKER_PANES"
    GRID_MODE="$_ENV_GRID_MODE"
    [ -z "$WORKER_COUNT" ] && WORKER_COUNT=0
    [ -z "$GRID_MODE" ] && GRID_MODE="dynamic"
    TOTAL_WORKERS=$WORKER_COUNT

    MGR_STATUS_FILE="${RUNTIME_DIR}/status/${SESSION_NAME}_0_0.status"
    MGR_ST="?"
    if [ -f "$MGR_STATUS_FILE" ]; then
      while IFS= read -r _ms_line; do
        case "$_ms_line" in STATUS:*) MGR_ST="${_ms_line#STATUS: }"; break ;; esac
      done < "$MGR_STATUS_FILE"
    fi

    WDG_ST="?"
    HEARTBEAT_FILE="${RUNTIME_DIR}/status/watchdog.heartbeat"
    if [ -f "$HEARTBEAT_FILE" ]; then
      BEAT=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
      BEAT_AGE=$((NOW - BEAT))
      if [ "$BEAT_AGE" -lt 120 ]; then
        WDG_ST="OK"
      else
        WDG_ST="STALE"
      fi
    fi

    IDLE_COUNT=$(count_team_workers "0" "$WORKER_PANES" "idle")
    BUSY_COUNT=$(count_team_workers "0" "$WORKER_PANES" "busy")
    RESV_COUNT=$(count_team_workers "0" "$WORKER_PANES" "reserved")
    TOTAL_IDLE=$IDLE_COUNT
    TOTAL_BUSY=$BUSY_COUNT
    TOTAL_RESERVED=$RESV_COUNT

    eval "TEAM_WIN_0=\"0\""
    eval "TEAM_MGR_0=\"${MGR_ST}\""
    eval "TEAM_WDG_0=\"${WDG_ST}\""
    eval "TEAM_IDLE_0=\"${IDLE_COUNT}\""
    eval "TEAM_BUSY_0=\"${BUSY_COUNT}\""
    eval "TEAM_RESV_0=\"${RESV_COUNT}\""
    eval "TEAM_WCNT_0=\"${WORKER_COUNT}\""
    eval "TEAM_GRID_0=\"${GRID_MODE}\""
    TEAM_LINE_COUNT=1
  fi

  # ── Collect Recent Events ─────────────────────────────────────────
  EVENT_COUNT=0
  for f in "$RUNTIME_DIR/results"/pane_*.json; do
    [ -f "$f" ] || continue
    E_PANE="" E_STATUS="" E_TITLE="" E_TS=""
    while IFS= read -r _jl; do
      case "$_jl" in
        *'"pane"'*)    _jv="${_jl#*\": \"}"; E_PANE="${_jv%%\"*}" ;;
        *'"status"'*)  _jv="${_jl#*\": \"}"; E_STATUS="${_jv%%\"*}" ;;
        *'"title"'*)   _jv="${_jl#*\": \"}"; E_TITLE="${_jv%%\"*}" ;;
        *'"timestamp"'*) _jv="${_jl#*: }"; E_TS="${_jv%%[, ]*}" ;;
      esac
    done < "$f"
    [ -z "$E_TS" ] && E_TS=0
    [ -z "$E_TITLE" ] && E_TITLE="unknown"
    [ -z "$E_STATUS" ] && E_STATUS="?"
    [ -z "$E_PANE" ] && E_PANE="?"

    if [ "$E_TS" -gt 0 ] 2>/dev/null; then
      E_TIME=$(date -r "$E_TS" '+%H:%M' 2>/dev/null || date -d "@${E_TS}" '+%H:%M' 2>/dev/null || echo "??:??")
    else
      E_TIME="??:??"
    fi

    # Sanitize values before eval
    E_TITLE="${E_TITLE//\"/}"; E_TITLE="${E_TITLE//\`/}"; E_TITLE="${E_TITLE//\$/}"
    E_PANE="${E_PANE//\"/}"; E_PANE="${E_PANE//\`/}"; E_PANE="${E_PANE//\$/}"
    E_STATUS="${E_STATUS//\"/}"; E_STATUS="${E_STATUS//\`/}"; E_STATUS="${E_STATUS//\$/}"
    eval "EVENT_TS_${EVENT_COUNT}=${E_TS}"
    eval "EVENT_TIME_${EVENT_COUNT}=\"${E_TIME}\""
    eval "EVENT_PANE_${EVENT_COUNT}=\"${E_PANE}\""
    eval "EVENT_STATUS_${EVENT_COUNT}=\"${E_STATUS}\""
    eval "EVENT_TITLE_${EVENT_COUNT}=\"${E_TITLE}\""
    EVENT_COUNT=$((EVENT_COUNT + 1))
  done

  # Check crash files too
  for f in "$RUNTIME_DIR/status"/crash_pane_*; do
    [ -f "$f" ] || continue
    C_PANE=$(echo "$f" | sed 's/.*crash_pane_//' | sed 's/\..*//')
    if stat -f '%m' "$f" >/dev/null 2>&1; then
      C_TS=$(stat -f '%m' "$f")
    else
      C_TS=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
    fi
    C_TIME=$(date -r "$C_TS" '+%H:%M' 2>/dev/null || date -d "@${C_TS}" '+%H:%M' 2>/dev/null || echo "??:??")

    C_PANE="${C_PANE//\"/}"; C_PANE="${C_PANE//\`/}"; C_PANE="${C_PANE//\$/}"
    eval "EVENT_TS_${EVENT_COUNT}=${C_TS}"
    eval "EVENT_TIME_${EVENT_COUNT}=\"${C_TIME}\""
    eval "EVENT_PANE_${EVENT_COUNT}=\"pane.${C_PANE}\""
    eval "EVENT_STATUS_${EVENT_COUNT}=\"CRASH\""
    eval "EVENT_TITLE_${EVENT_COUNT}=\"\""
    EVENT_COUNT=$((EVENT_COUNT + 1))
  done

  # Sort events by timestamp (bubble sort, bash 3.2 safe)
  i=0
  while [ "$i" -lt "$EVENT_COUNT" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$EVENT_COUNT" ]; do
      eval "ts_i=\${EVENT_TS_${i}}"
      eval "ts_j=\${EVENT_TS_${j}}"
      if [ "$ts_i" -lt "$ts_j" ] 2>/dev/null; then
        # Swap all fields
        for _sf in TS TIME PANE STATUS TITLE; do
          eval "tmp=\${EVENT_${_sf}_${i}}"
          eval "EVENT_${_sf}_${i}=\${EVENT_${_sf}_${j}}"
          eval "EVENT_${_sf}_${j}=\"\${tmp}\""
        done
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  # Limit to last 10 events
  MAX_EVENTS=10
  [ "$EVENT_COUNT" -gt "$MAX_EVENTS" ] && EVENT_COUNT=$MAX_EVENTS

  # ══════════════════════════════════════════════════════════════════
  # ██  RENDER  ██
  # ══════════════════════════════════════════════════════════════════

  # Initialize column line arrays
  LC=0  # left column line count
  RC=0  # right column line count

  # ── LEFT COLUMN ───────────────────────────────────────────────────

  add_left ""
  add_left "$(printf '%b  HOW TO USE DOEY%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_left ""
  add_left "$(printf '%b  1.%b Talk to the %bSession Manager%b (right pane' "${C_BOLD_WHITE}" "${C_RESET}" "${C_CYAN}" "${C_RESET}")"
  add_left "$(printf '     in this window) %b—%b describe your task and' "${C_DIM}" "${C_RESET}")"
  add_left "     it routes work to the right team."
  add_left ""
  add_left "$(printf '%b  2.%b Switch to a team window (%bCtrl-b 1%b) and' "${C_BOLD_WHITE}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}")"
  add_left "     talk to the Window Manager directly."
  add_left ""
  add_left "$(printf '%b  3.%b Click any worker pane and run %b/doey-reserve%b' "${C_BOLD_WHITE}" "${C_RESET}" "${C_GREEN}" "${C_RESET}")"
  add_left "     to claim it for yourself."
  add_left ""
  add_left ""
  add_left "$(printf '%b  ARCHITECTURE%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_left ""
  add_left "$(printf '  %bWindow 0%b = Dashboard (this window)' "${C_WHITE}" "${C_RESET}")"
  add_left "$(printf '  %bWindow 1+%b = Team windows' "${C_WHITE}" "${C_RESET}")"
  add_left ""
  add_left "$(printf '  Each team: %bManager%b (plans) + %bWatchdog%b (monitors)' "${C_CYAN}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}")"
  add_left "$(printf '             + %bWorkers%b (execute code)' "${C_GREEN}" "${C_RESET}")"
  add_left ""
  add_left "$(printf '  Dynamic grid auto-expands when all workers busy.')"
  add_left ""
  add_left ""
  add_left "$(printf '%b  ESSENTIAL COMMANDS%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_left ""

  CMD_W=$((LEFT_W - 4))  # usable width inside the column with indent

  add_left "$(printf '  %bTasking:%b' "${C_WHITE}" "${C_RESET}")"
  add_left "  $(dotted_leader "$(printf '%b/doey-dispatch%b' "${C_GREEN}" "${C_RESET}")" "Send task to a worker" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-research%b' "${C_GREEN}" "${C_RESET}")" "Deep research with report" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-broadcast%b' "${C_GREEN}" "${C_RESET}")" "Send to all workers" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-delegate%b' "${C_GREEN}" "${C_RESET}")" "Delegate to another team" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-send%b' "${C_GREEN}" "${C_RESET}")" "Message a specific pane" "$CMD_W")"
  add_left ""
  add_left "$(printf '  %bMonitoring:%b' "${C_WHITE}" "${C_RESET}")"
  add_left "  $(dotted_leader "$(printf '%b/doey-team%b' "${C_CYAN}" "${C_RESET}")" "Show team overview" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-status%b' "${C_CYAN}" "${C_RESET}")" "Detailed worker status" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-monitor%b' "${C_CYAN}" "${C_RESET}")" "Live monitoring mode" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-inbox%b' "${C_CYAN}" "${C_RESET}")" "Check your messages" "$CMD_W")"
  add_left ""
  add_left "$(printf '  %bWorkers:%b' "${C_WHITE}" "${C_RESET}")"
  add_left "  $(dotted_leader "$(printf '%b/doey-reserve%b' "${C_MAGENTA}" "${C_RESET}")" "Claim a worker for yourself" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-stop%b' "${C_MAGENTA}" "${C_RESET}")" "Stop current worker" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-stop-all%b' "${C_MAGENTA}" "${C_RESET}")" "Stop all workers" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-restart-workers%b' "${C_MAGENTA}" "${C_RESET}")" "Restart all workers" "$CMD_W")"
  add_left ""
  add_left "$(printf '  %bTeams:%b' "${C_WHITE}" "${C_RESET}")"
  add_left "  $(dotted_leader "$(printf '%b/doey-add-window%b' "${C_YELLOW}" "${C_RESET}")" "Add a new team" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-kill-window%b' "${C_YELLOW}" "${C_RESET}")" "Remove a team" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-list-windows%b' "${C_YELLOW}" "${C_RESET}")" "List all teams" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-restart-window%b' "${C_YELLOW}" "${C_RESET}")" "Restart a team" "$CMD_W")"
  add_left ""
  add_left "$(printf '  %bSystem:%b' "${C_WHITE}" "${C_RESET}")"
  add_left "  $(dotted_leader "$(printf '%b/doey-analyze%b' "${C_RED}" "${C_RESET}")" "Analyze codebase" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-purge%b' "${C_RED}" "${C_RESET}")" "Clean runtime files" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-reinstall%b' "${C_RED}" "${C_RESET}")" "Reinstall Doey" "$CMD_W")"
  add_left "  $(dotted_leader "$(printf '%b/doey-kill-session%b' "${C_RED}" "${C_RESET}")" "Kill entire session" "$CMD_W")"

  # ── RIGHT COLUMN ──────────────────────────────────────────────────

  add_right ""
  add_right "$(printf '%b  LIVE STATUS%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_right ""

  # Per-team status blocks
  i=0
  while [ "$i" -lt "$TEAM_LINE_COUNT" ]; do
    eval "t_win=\${TEAM_WIN_${i}}"
    eval "t_mgr=\${TEAM_MGR_${i}}"
    eval "t_wdg=\${TEAM_WDG_${i}}"
    eval "t_idle=\${TEAM_IDLE_${i}}"
    eval "t_busy=\${TEAM_BUSY_${i}}"
    eval "t_resv=\${TEAM_RESV_${i}}"
    eval "t_wcnt=\${TEAM_WCNT_${i}}"
    eval "t_grid=\${TEAM_GRID_${i}}"

    add_right "$(printf '  %b Team %s%b  (window %s, %s grid)' "${C_BOLD_WHITE}" "$((i + 1))" "${C_RESET}" "$t_win" "$t_grid")"

    # Manager status with color
    case "$t_mgr" in
      READY)    mgr_color="${C_BOLD_GREEN}" ;;
      BUSY|WORKING) mgr_color="${C_BOLD_YELLOW}" ;;
      *)        mgr_color="${C_BOLD_RED}" ;;
    esac
    add_right "$(printf '    Manager %b....%b %b%s%b' "${C_DIM}" "${C_RESET}" "$mgr_color" "$t_mgr" "${C_RESET}")"

    # Watchdog status with color
    case "$t_wdg" in
      OK)    wdg_color="${C_BOLD_GREEN}" ;;
      STALE) wdg_color="${C_BOLD_RED}" ;;
      *)     wdg_color="${C_YELLOW}" ;;
    esac
    add_right "$(printf '    Watchdog %b...%b %b%s%b' "${C_DIM}" "${C_RESET}" "$wdg_color" "$t_wdg" "${C_RESET}")"

    # Worker summary
    worker_parts=""
    if [ "$t_idle" -gt 0 ]; then
      worker_parts="$(printf '%b%s idle%b' "${C_GREEN}" "$t_idle" "${C_RESET}")"
    fi
    if [ "$t_busy" -gt 0 ]; then
      if [ -n "$worker_parts" ]; then
        worker_parts="${worker_parts}, "
      fi
      worker_parts="${worker_parts}$(printf '%b%s busy%b' "${C_YELLOW}" "$t_busy" "${C_RESET}")"
    fi
    if [ "$t_resv" -gt 0 ]; then
      if [ -n "$worker_parts" ]; then
        worker_parts="${worker_parts}, "
      fi
      worker_parts="${worker_parts}$(printf '%b%s reserved%b' "${C_MAGENTA}" "$t_resv" "${C_RESET}")"
    fi
    if [ -z "$worker_parts" ]; then
      worker_parts="$(printf '%b0 idle%b' "${C_GRAY}" "${C_RESET}")"
    fi
    add_right "$(printf '    Workers %b....%b %s' "${C_DIM}" "${C_RESET}" "$worker_parts")"
    add_right ""
    i=$((i + 1))
  done

  add_right ""
  add_right "$(printf '%b  RECENT EVENTS%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_right ""

  if [ "$EVENT_COUNT" -eq 0 ]; then
    add_right "$(printf '  %b(no events yet)%b' "${C_DIM}" "${C_RESET}")"
  else
    i=0
    while [ "$i" -lt "$EVENT_COUNT" ]; do
      eval "e_time=\${EVENT_TIME_${i}}"
      eval "e_pane=\${EVENT_PANE_${i}}"
      eval "e_status=\${EVENT_STATUS_${i}}"
      eval "e_title=\${EVENT_TITLE_${i}}"

      # Color based on status
      case "$e_status" in
        *done*|*FINISHED*|*success*) evt_color="${C_GREEN}" ;;
        *error*|*ERROR*|*CRASH*|*crash*) evt_color="${C_RED}" ;;
        *) evt_color="${C_GRAY}" ;;
      esac

      # Truncate title if needed
      max_title=$((RIGHT_W - 25))
      if [ "$max_title" -lt 5 ]; then
        max_title=5
      fi
      if [ "${#e_title}" -gt "$max_title" ]; then
        e_title="$(printf '%.'"$((max_title - 3))"'s...' "$e_title")"
      fi

      if [ -n "$e_title" ]; then
        add_right "$(printf '  %b%s%b  %-8s %b%-8s%b %s' "${C_DIM}" "$e_time" "${C_RESET}" "$e_pane" "$evt_color" "$e_status" "${C_RESET}" "$e_title")"
      else
        add_right "$(printf '  %b%s%b  %-8s %b%s%b' "${C_DIM}" "$e_time" "${C_RESET}" "$e_pane" "$evt_color" "$e_status" "${C_RESET}")"
      fi
      i=$((i + 1))
    done
  fi

  add_right ""
  add_right ""
  add_right "$(printf '%b  TMUX NAVIGATION%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_right ""

  NAV_W=$((RIGHT_W - 4))

  add_right "  $(dotted_leader "$(printf '%bCtrl-b 0%b' "${C_WHITE}" "${C_RESET}")" "Dashboard" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bCtrl-b 1%b' "${C_WHITE}" "${C_RESET}")" "Team 1" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bCtrl-b arrow%b' "${C_WHITE}" "${C_RESET}")" "Switch pane" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bCtrl-b z%b' "${C_WHITE}" "${C_RESET}")" "Zoom pane" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bCtrl-b d%b' "${C_WHITE}" "${C_RESET}")" "Detach" "$NAV_W")"

  add_right ""
  add_right ""
  add_right "$(printf '%b  CLI COMMANDS%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_right ""

  add_right "  $(dotted_leader "$(printf '%bdoey%b' "${C_WHITE}" "${C_RESET}")" "Launch session" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bdoey add%b' "${C_WHITE}" "${C_RESET}")" "Add column" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bdoey add-team%b' "${C_WHITE}" "${C_RESET}")" "Add team window" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bdoey stop%b' "${C_WHITE}" "${C_RESET}")" "Stop session" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bdoey doctor%b' "${C_WHITE}" "${C_RESET}")" "Health check" "$NAV_W")"
  add_right "  $(dotted_leader "$(printf '%bdoey list%b' "${C_WHITE}" "${C_RESET}")" "List sessions" "$NAV_W")"

  # ══════════════════════════════════════════════════════════════════
  # ██  OUTPUT  ██
  # ══════════════════════════════════════════════════════════════════

  # ── Header: ASCII Art ─────────────────────────────────────────────
  # Build a full-width horizontal rule
  HR=""
  hr_i=0
  while [ "$hr_i" -lt "$TERM_W" ]; do
    HR="${HR}─"
    hr_i=$((hr_i + 1))
  done

  # Thicker horizontal rule with ═
  HR_THICK=""
  hr_i=0
  while [ "$hr_i" -lt "$TERM_W" ]; do
    HR_THICK="${HR_THICK}═"
    hr_i=$((hr_i + 1))
  done

  printf '\n'
  printf '%b' "${C_BOLD_CYAN}"
  printf '    ██████╗   ██████╗  ███████╗ ██╗   ██╗\n'
  printf '    ██╔══██╗ ██╔═══██╗ ██╔════╝ ╚██╗ ██╔╝\n'
  printf '    ██║  ██║ ██║   ██║ █████╗    ╚████╔╝ \n'
  printf '    ██║  ██║ ██║   ██║ ██╔══╝     ╚██╔╝  \n'
  printf '    ██████╔╝ ╚██████╔╝ ███████╗    ██║   \n'
  printf '    ╚═════╝   ╚═════╝  ╚══════╝    ╚═╝   \n'
  printf '%b' "${C_RESET}"
  printf '\n'

  # ── Status Bar ────────────────────────────────────────────────────
  printf '%b%s%b\n' "${C_DIM}" "$HR_THICK" "${C_RESET}"

  # Build status items
  stat_project="$(printf '%b PROJECT %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$PROJECT_NAME")"
  stat_session="$(printf '%b SESSION %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$SESSION_NAME")"
  stat_uptime="$(printf '%b UPTIME %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$UPTIME_STR")"
  stat_teams="$(printf '%b TEAMS %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$TEAM_COUNT")"

  # Worker summary with colors
  stat_workers="$(printf '%b WORKERS %b %b%s%b idle  %b%s%b busy  %b%s%b reserved' \
    "${C_BOLD_WHITE}" "${C_RESET}" \
    "${C_GREEN}" "$TOTAL_IDLE" "${C_RESET}" \
    "${C_YELLOW}" "$TOTAL_BUSY" "${C_RESET}" \
    "${C_MAGENTA}" "$TOTAL_RESERVED" "${C_RESET}")"

  printf '  %b  %b│%b  %b  %b│%b  %b  %b│%b  %b\n' \
    "$stat_project" "${C_DIM}" "${C_RESET}" \
    "$stat_session" "${C_DIM}" "${C_RESET}" \
    "$stat_uptime" "${C_DIM}" "${C_RESET}" \
    "$stat_teams"
  printf '  %b\n' "$stat_workers"

  printf '%b%s%b\n' "${C_DIM}" "$HR_THICK" "${C_RESET}"
  printf '\n'

  # ── Two-Column Body ───────────────────────────────────────────────
  # Determine max lines
  MAX_LINES=$LC
  if [ "$RC" -gt "$MAX_LINES" ]; then
    MAX_LINES=$RC
  fi

  # Render each row: left padded to LEFT_W, dim " │ ", right padded to RIGHT_W
  row=0
  while [ "$row" -lt "$MAX_LINES" ]; do
    # Get left line
    if [ "$row" -lt "$LC" ]; then
      eval "left_line=\${L_${row}}"
    else
      left_line=""
    fi

    # Get right line
    if [ "$row" -lt "$RC" ]; then
      eval "right_line=\${R_${row}}"
    else
      right_line=""
    fi

    # Calculate visible lengths for padding
    left_vis=$(visible_len "$left_line")
    right_vis=$(visible_len "$right_line")

    # Calculate padding needed
    left_pad=$((LEFT_W - left_vis))
    if [ "$left_pad" -lt 0 ]; then
      left_pad=0
    fi

    # Build padding strings
    lpad=""
    lp_i=0
    while [ "$lp_i" -lt "$left_pad" ]; do
      lpad="${lpad} "
      lp_i=$((lp_i + 1))
    done

    # Print the combined line
    printf '%b%b %b│%b %b\n' "$left_line" "$lpad" "${C_DIM}" "${C_RESET}" "$right_line"

    row=$((row + 1))
  done

  # ── Footer ────────────────────────────────────────────────────────
  printf '\n'
  printf '%b%s%b\n' "${C_DIM}" "$HR" "${C_RESET}"
  printf '%b  Refreshing every 5s  │  Ctrl+C to stop  │  %b%s%b%b\n' \
    "${C_DIM}" "${C_RESET}" "$(date '+%H:%M:%S')" "${C_DIM}" "${C_RESET}"

  sleep 5
done
