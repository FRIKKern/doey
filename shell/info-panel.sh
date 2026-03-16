#!/bin/bash
# Doey Info Panel — dashboard for window 0
# Displays team status, worker counts, and recent events.
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

# Pre-compute border strings (WIDTH=40 is constant)
WIDTH=40
BORDER_STR="════════════════════════════════════════"

# Cache: SESSION_NAME and PROJECT_NAME are stable across cycles
_CACHED_SESSION_NAME=""
_CACHED_PROJECT_NAME=""

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
      esac
    else
      # No status file = idle (freshly started)
      case "$state" in idle) count=$((count + 1)) ;; esac
    fi
  done
  printf '%d' "$count"
}

# Main loop
while true; do
  # Clear screen
  printf '\033[2J\033[H'

  # Wait for session.env
  if [ ! -f "$SESSION_ENV" ]; then
    printf 'Doey Info Panel: waiting for session.env...\n'
    sleep 5
    continue
  fi

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

  # Count teams and total workers
  TEAM_COUNT=0
  TOTAL_WORKERS=0
  TOTAL_IDLE=0

  # Build team lines (stored in indexed variables for bash 3.2)
  TEAM_LINE_COUNT=0

  if [ -n "$TEAM_WINDOWS" ]; then
    for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
      TEAM_COUNT=$((TEAM_COUNT + 1))
      TEAM_FILE="${RUNTIME_DIR}/team_${W}.env"

      read_env_file "$TEAM_FILE" WATCHDOG_PANE WORKER_PANES WORKER_COUNT
      WD_PANE="$_ENV_WATCHDOG_PANE"
      WORKER_PANES="$_ENV_WORKER_PANES"
      WORKER_COUNT="$_ENV_WORKER_COUNT"
      [ -z "$WORKER_COUNT" ] && WORKER_COUNT=0
      TOTAL_WORKERS=$((TOTAL_WORKERS + WORKER_COUNT))

      # Window Manager status (no forks — pure shell read)
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
      # Fall back to legacy name for single-window
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

      # Worker idle count
      IDLE_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "idle")
      TOTAL_IDLE=$((TOTAL_IDLE + IDLE_COUNT))

      # Store line
      eval "TEAM_LINE_${TEAM_LINE_COUNT}=\"Team ${W} (W${W}) MGR:${MGR_ST} WDG:${WDG_ST} ${IDLE_COUNT}/${WORKER_COUNT}\""
      TEAM_LINE_COUNT=$((TEAM_LINE_COUNT + 1))
    done
  else
    # Single-window fallback
    TEAM_COUNT=1
    read_env_file "$SESSION_ENV" WORKER_COUNT WORKER_PANES
    WORKER_COUNT="$_ENV_WORKER_COUNT"
    WORKER_PANES="$_ENV_WORKER_PANES"
    [ -z "$WORKER_COUNT" ] && WORKER_COUNT=0
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
    TOTAL_IDLE=$IDLE_COUNT

    eval "TEAM_LINE_0=\"Team 0 (W0) MGR:${MGR_ST} WDG:${WDG_ST} ${IDLE_COUNT}/${WORKER_COUNT}\""
    TEAM_LINE_COUNT=1
  fi

  # Collect recent events (completions and crashes, last 10)
  EVENT_COUNT=0
  for f in "$RUNTIME_DIR/results"/pane_*.json; do
    [ -f "$f" ] || continue
    # Single-pass JSON field extraction (0 forks — pure shell)
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

    # Format time as HH:MM
    if [ "$E_TS" -gt 0 ] 2>/dev/null; then
      E_TIME=$(date -r "$E_TS" '+%H:%M' 2>/dev/null || date -d "@${E_TS}" '+%H:%M' 2>/dev/null || echo "??:??")
    else
      E_TIME="??:??"
    fi

    # Sanitize values before eval to prevent injection from malformed JSON
    E_TITLE="${E_TITLE//\"/}"; E_TITLE="${E_TITLE//\`/}"; E_TITLE="${E_TITLE//\$/}"
    E_PANE="${E_PANE//\"/}"; E_PANE="${E_PANE//\`/}"; E_PANE="${E_PANE//\$/}"
    E_STATUS="${E_STATUS//\"/}"; E_STATUS="${E_STATUS//\`/}"; E_STATUS="${E_STATUS//\$/}"
    eval "EVENT_TS_${EVENT_COUNT}=${E_TS}"
    eval "EVENT_LINE_${EVENT_COUNT}=\"${E_TIME} ${E_PANE} ${E_STATUS} (${E_TITLE})\""
    EVENT_COUNT=$((EVENT_COUNT + 1))
  done

  # Check crash files too
  for f in "$RUNTIME_DIR/status"/crash_pane_*; do
    [ -f "$f" ] || continue
    C_PANE=$(echo "$f" | sed 's/.*crash_pane_//' | sed 's/\..*//')
    # Use file mtime for timestamp
    if stat -f '%m' "$f" >/dev/null 2>&1; then
      C_TS=$(stat -f '%m' "$f")
    else
      C_TS=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
    fi
    C_TIME=$(date -r "$C_TS" '+%H:%M' 2>/dev/null || date -d "@${C_TS}" '+%H:%M' 2>/dev/null || echo "??:??")

    # Sanitize before eval
    C_PANE="${C_PANE//\"/}"; C_PANE="${C_PANE//\`/}"; C_PANE="${C_PANE//\$/}"
    eval "EVENT_TS_${EVENT_COUNT}=${C_TS}"
    eval "EVENT_LINE_${EVENT_COUNT}=\"${C_TIME} pane.${C_PANE} CRASH\""
    EVENT_COUNT=$((EVENT_COUNT + 1))
  done

  # Sort events by timestamp (simple bubble sort, bash 3.2 safe)
  i=0
  while [ "$i" -lt "$EVENT_COUNT" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$EVENT_COUNT" ]; do
      eval "ts_i=\${EVENT_TS_${i}}"
      eval "ts_j=\${EVENT_TS_${j}}"
      if [ "$ts_i" -lt "$ts_j" ] 2>/dev/null; then
        # Swap
        eval "tmp_ts=\${EVENT_TS_${i}}"
        eval "tmp_line=\${EVENT_LINE_${i}}"
        eval "EVENT_TS_${i}=\${EVENT_TS_${j}}"
        eval "EVENT_LINE_${i}=\${EVENT_LINE_${j}}"
        eval "EVENT_TS_${j}=${tmp_ts}"
        eval "EVENT_LINE_${j}=\"${tmp_line}\""
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  # Limit to last 8 events
  MAX_EVENTS=8
  [ "$EVENT_COUNT" -gt "$MAX_EVENTS" ] && EVENT_COUNT=$MAX_EVENTS

  # --- Render (borders pre-computed above main loop) ---
  printf '╔═══ DOEY: %-*s╗\n' "$((WIDTH - 10))" "$PROJECT_NAME "
  printf '║ Teams: %-2s │ Workers: %-3s │ Up %-5s║\n' "$TEAM_COUNT" "$TOTAL_WORKERS" "$UPTIME_STR"
  printf '╠%s╣\n' "$BORDER_STR"

  # Team lines
  i=0
  while [ "$i" -lt "$TEAM_LINE_COUNT" ]; do
    eval "line=\${TEAM_LINE_${i}}"
    printf '║ %-*s║\n' "$((WIDTH - 1))" "$line"
    i=$((i + 1))
  done

  printf '╠%s╣\n' "$BORDER_STR"
  printf '║ %-*s║\n' "$((WIDTH - 1))" "Recent:"

  if [ "$EVENT_COUNT" -eq 0 ]; then
    printf '║ %-*s║\n' "$((WIDTH - 1))" " (no events yet)"
  else
    i=0
    while [ "$i" -lt "$EVENT_COUNT" ]; do
      eval "line=\${EVENT_LINE_${i}}"
      # Truncate if too long
      if [ "${#line}" -gt "$((WIDTH - 3))" ]; then
        line="$(printf '%.'"$((WIDTH - 6))"'s...' "$line")"
      fi
      printf '║  %-*s║\n' "$((WIDTH - 2))" "$line"
      i=$((i + 1))
    done
  fi

  printf '╚%s╝\n' "$BORDER_STR"
  printf '\nRefreshing every 5s... (Ctrl+C to stop)\n'

  sleep 5
done
