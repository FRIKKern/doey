#!/usr/bin/env bash
# Session Manager wait — sleeps up to 30s, wakes on new messages or triggers.
set -euo pipefail

# Prefer env var (set by on-session-start), fall back to tmux query
if [ -n "${DOEY_RUNTIME:-}" ]; then
  RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then
  RUNTIME_DIR="$1"
else
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
fi
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true

SM_PANE="${SM_PANE:-0.1}"
SM_SAFE="${SESSION_NAME//[:.]/_}_${SM_PANE//[:.]/_}"
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/session_manager_trigger"
TRIGGER2="${RUNTIME_DIR}/triggers/${SM_SAFE}.trigger"

# Debug mode check
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
  # Append only the newly-found results to the seen list
  _seen_results="${_seen_results}${_new_result_files}"
  echo "$_seen_results" > "$SEEN_FILE"
}

# Auto-compact trigger: check cycle count (increment deferred to non-IDLE exit)
CYCLE_FILE="${RUNTIME_DIR}/status/sm_cycle_count"
COMPACT_INTERVAL="${DOEY_SM_COMPACT_INTERVAL:-20}"
_sm_cycle=0
[ -f "$CYCLE_FILE" ] && _sm_cycle=$(cat "$CYCLE_FILE" 2>/dev/null || echo 0)

# Idle backoff: track consecutive IDLE returns
IDLE_COUNT_FILE="${RUNTIME_DIR}/sm_idle_count"
_sm_idle_count=0
[ -f "$IDLE_COUNT_FILE" ] && _sm_idle_count=$(cat "$IDLE_COUNT_FILE" 2>/dev/null || echo 0)

# Helpers for non-IDLE exits
_sm_bump_cycle() {
  _sm_cycle=$((_sm_cycle + 1))
  echo "$_sm_cycle" > "$CYCLE_FILE"
}
_sm_reset_idle() {
  echo "0" > "$IDLE_COUNT_FILE"
}
_sm_non_idle_exit() {
  _sm_bump_cycle; _sm_reset_idle
}

# Check if we'd hit compact threshold on next increment
if [ "$((_sm_cycle + 1))" -ge "$COMPACT_INTERVAL" ]; then
  echo "0" > "$CYCLE_FILE"
  _sm_reset_idle
  _sm_dbg_wake "compact_cycle" "0"
  echo "COMPACT_CYCLE"
  exit 0
fi

# Pre-sleep check: catch messages/triggers that arrived before entering the loop
if [ -f "$TRIGGER" ] || [ -f "$TRIGGER2" ]; then
  rm -f "$TRIGGER" "$TRIGGER2" 2>/dev/null
  _sm_non_idle_exit
  _sm_dbg_wake "trigger_presleep" "0"
  echo "TRIGGERED"
  exit 0
fi
set -- "$MSG_DIR"/${SM_SAFE}_*.msg
if [ -f "${1:-}" ]; then _sm_non_idle_exit; _sm_dbg_wake "new_messages_presleep" "0"; echo "NEW_MESSAGES"; exit 0; fi
if _has_new_results; then _mark_results_seen; _sm_non_idle_exit; _sm_dbg_wake "new_results_presleep" "0"; echo "NEW_RESULTS"; exit 0; fi
set -- "$RUNTIME_DIR/status"/crash_pane_*
if [ -f "${1:-}" ]; then _sm_non_idle_exit; _sm_dbg_wake "crash_alert_presleep" "0"; echo "CRASH_ALERT"; exit 0; fi

# Idle backoff: determine sleep duration per cycle
_sm_scan_interval="${DOEY_SM_SCAN_INTERVAL:-30}"
if [ "$_sm_idle_count" -ge 50 ]; then
  _sm_scan_interval=900
elif [ "$_sm_idle_count" -ge 25 ]; then
  _sm_scan_interval=600
elif [ "$_sm_idle_count" -ge 10 ]; then
  _sm_scan_interval=180
elif [ "$_sm_idle_count" -ge 3 ]; then
  _sm_scan_interval=60
fi

# Internal multi-cycle batching: loop through multiple sleep cycles before
# returning IDLE to the SM. This is the key optimization — instead of returning
# IDLE every cycle (each costing context), batch them internally.
_internal_cycles=1
if [ "$_sm_idle_count" -ge 50 ]; then
  _internal_cycles=4   # 4 x 900s = return every ~60min
elif [ "$_sm_idle_count" -ge 25 ]; then
  _internal_cycles=3   # 3 x 600s = return every ~30min
fi

_cycle_num=0
while [ "$_cycle_num" -lt "$_internal_cycles" ]; do
  i=0
  while [ "$i" -lt "$_sm_scan_interval" ]; do
    # Wake on explicit trigger (check both legacy and per-pane paths)
    if [ -f "$TRIGGER" ] || [ -f "$TRIGGER2" ]; then
      rm -f "$TRIGGER" "$TRIGGER2" 2>/dev/null
      _sm_non_idle_exit
      _sm_dbg_wake "trigger" "$i"
      echo "TRIGGERED"
      exit 0
    fi
    # Wake on new messages addressed to Session Manager
    set -- "$MSG_DIR"/${SM_SAFE}_*.msg
    if [ -f "${1:-}" ]; then
      _sm_non_idle_exit
      _sm_dbg_wake "new_messages" "$i"
      echo "NEW_MESSAGES"
      exit 0
    fi
    # Wake on new results (skip already-seen)
    if _has_new_results; then
      _mark_results_seen; _sm_non_idle_exit
      _sm_dbg_wake "new_results" "$i"
      echo "NEW_RESULTS"
      exit 0
    fi
    # Wake on crash alerts
    set -- "$RUNTIME_DIR/status"/crash_pane_*
    if [ -f "${1:-}" ]; then
      _sm_non_idle_exit
      _sm_dbg_wake "crash_alert" "$i"
      echo "CRASH_ALERT"
      exit 0
    fi
    sleep 1
    i=$((i + 1))
  done

  # End of internal cycle — increment idle count and check compact
  _sm_idle_count=$((_sm_idle_count + 1))
  echo "$_sm_idle_count" > "$IDLE_COUNT_FILE"

  # Preemptive compact: flush accumulated IDLE ceremony from context
  # Check at end of EACH internal cycle so batching never skips it
  if [ "$((_sm_idle_count % 15))" -eq 0 ]; then
    _sm_dbg_wake "compact_needed_idle" "$_sm_scan_interval"
    echo "COMPACT_NEEDED"
    exit 0
  fi

  _cycle_num=$((_cycle_num + 1))
done

_sm_dbg_wake "timeout" "$_sm_scan_interval"
echo "IDLE"
