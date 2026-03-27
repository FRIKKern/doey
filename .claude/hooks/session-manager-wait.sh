#!/usr/bin/env bash
# Session Manager wait — short pause utility. Checks for pending work,
# sleeps briefly if idle, returns a reason string for compatibility.
set -euo pipefail

# Resolve runtime directory
if [ -n "${DOEY_RUNTIME:-}" ]; then
  RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then
  RUNTIME_DIR="$1"
else
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 5; exit 0; }
fi
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true

# Source common.sh for write_pane_status (skip init_hook — we set our own vars)
source "$(dirname "$0")/common.sh" 2>/dev/null || true

# SM identity
SM_PANE="${SM_PANE:-0.2}"
SM_SAFE="${SESSION_NAME//[-:.]/_}_${SM_PANE//[-:.]/_}"

# Heartbeat: update SM status file on every cycle (including idle) via EXIT trap.
# Sets PANE/PANE_SAFE for write_pane_status, which expects these globals.
PANE="${SESSION_NAME}:${SM_PANE}"
PANE_SAFE="$SM_SAFE"
_SM_STATUS_FILE="${RUNTIME_DIR}/status/${SM_SAFE}.status"
_sm_heartbeat() {
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')
  write_pane_status "$_SM_STATUS_FILE" "BUSY" "Session Manager idle — listening" 2>/dev/null || true
}
trap _sm_heartbeat EXIT
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/session_manager_trigger"
TRIGGER2="${RUNTIME_DIR}/triggers/${SM_SAFE}.trigger"
TRIGGER3="${RUNTIME_DIR}/status/sm_trigger"

# Debug logging
_SM_DBG=false
[ -f "${RUNTIME_DIR}/debug.conf" ] && _SM_DBG=true
_SM_DBG_FILE="${RUNTIME_DIR}/debug/session_manager.jsonl"

_sm_dbg_wake() {
  [ "$_SM_DBG" = "true" ] || return 0
  local reason="$1" elapsed="$2"
  [ -d "$(dirname "$_SM_DBG_FILE")" ] || mkdir -p "$(dirname "$_SM_DBG_FILE")" 2>/dev/null
  printf '{"ts":%s,"cat":"watchdog","msg":"sm_wake","reason":"%s","wait_s":%s}\n' \
    "$(date +%s)" "$reason" "$elapsed" \
    >> "$_SM_DBG_FILE" 2>/dev/null
  return 0
}

# Track last-seen results to avoid re-triggering on stale files
SEEN_FILE="${RUNTIME_DIR}/status/sm_seen_results"
_seen_results=""
[ -f "$SEEN_FILE" ] && _seen_results=$(cat "$SEEN_FILE" 2>/dev/null || true)

_new_result_files=""
_has_new_results() {
  local _f _base _found=false
  _new_result_files=""
  for _f in "$RUNTIME_DIR/results"/pane_*.json; do
    [ -f "$_f" ] || continue
    _base=$(basename "$_f")
    case " $_seen_results " in
      *" ${_base} "*) continue ;;
    esac
    _new_result_files="${_new_result_files} ${_base}"
    _found=true
  done
  [ "$_found" = true ]
}
_mark_results_seen() {
  _seen_results="${_seen_results}${_new_result_files}"
  echo "$_seen_results" > "$SEEN_FILE"
}

# Compact cycle counter
CYCLE_FILE="${RUNTIME_DIR}/status/sm_cycle_count"
COMPACT_INTERVAL="${DOEY_SM_COMPACT_INTERVAL:-20}"
_sm_cycle=0
[ -f "$CYCLE_FILE" ] && _sm_cycle=$(cat "$CYCLE_FILE" 2>/dev/null || echo 0)

_sm_bump_cycle() {
  _sm_cycle=$((_sm_cycle + 1))
  echo "$_sm_cycle" > "$CYCLE_FILE"
}

# --- Check for work (before sleeping) ---

# Compact cycle check
if [ "$((_sm_cycle + 1))" -ge "$COMPACT_INTERVAL" ]; then
  echo "0" > "$CYCLE_FILE"
  _sm_dbg_wake "compact_cycle" "0"
  echo "COMPACT_CYCLE"
  exit 0
fi

# Trigger files
if [ -f "$TRIGGER" ] || [ -f "$TRIGGER2" ] || [ -f "$TRIGGER3" ]; then
  rm -f "$TRIGGER" "$TRIGGER2" "$TRIGGER3" 2>/dev/null
  _sm_bump_cycle
  _sm_dbg_wake "trigger" "0"
  echo "TRIGGERED"
  exit 0
fi

# Messages for SM
set -- "$MSG_DIR"/${SM_SAFE}_*.msg
if [ -f "${1:-}" ]; then
  _sm_bump_cycle
  _sm_dbg_wake "new_messages" "0"
  echo "NEW_MESSAGES"
  exit 0
fi

# New result files
if _has_new_results; then
  _mark_results_seen
  _sm_bump_cycle
  _sm_dbg_wake "new_results" "0"
  echo "NEW_RESULTS"
  exit 0
fi

# Crash alerts
set -- "$RUNTIME_DIR/status"/crash_pane_*
if [ -f "${1:-}" ]; then
  _sm_bump_cycle
  _sm_dbg_wake "crash_alert" "0"
  echo "CRASH_ALERT"
  exit 0
fi

# --- No immediate work: short pause, then re-check ---

sleep 3

# Re-check after sleep
if [ -f "$TRIGGER" ] || [ -f "$TRIGGER2" ] || [ -f "$TRIGGER3" ]; then
  rm -f "$TRIGGER" "$TRIGGER2" "$TRIGGER3" 2>/dev/null
  _sm_bump_cycle
  _sm_dbg_wake "trigger" "3"
  echo "TRIGGERED"
  exit 0
fi
set -- "$MSG_DIR"/${SM_SAFE}_*.msg
if [ -f "${1:-}" ]; then
  _sm_bump_cycle
  _sm_dbg_wake "new_messages" "3"
  echo "NEW_MESSAGES"
  exit 0
fi
if _has_new_results; then
  _mark_results_seen
  _sm_bump_cycle
  _sm_dbg_wake "new_results" "3"
  echo "NEW_RESULTS"
  exit 0
fi
set -- "$RUNTIME_DIR/status"/crash_pane_*
if [ -f "${1:-}" ]; then
  _sm_bump_cycle
  _sm_dbg_wake "crash_alert" "3"
  echo "CRASH_ALERT"
  exit 0
fi

# Nothing happened
_sm_dbg_wake "idle" "3"
echo "IDLE"
