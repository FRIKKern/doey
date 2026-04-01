#!/usr/bin/env bash
# Session Manager wait — checks for pending work, sleeps briefly if idle.
set -euo pipefail

if [ -n "${DOEY_RUNTIME:-}" ]; then RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then RUNTIME_DIR="$1"
else RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 5; exit 0; }
fi
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true
trap 'exit 0' ERR
source "$(dirname "$0")/common.sh" 2>/dev/null || true

SM_PANE="${SM_PANE:-0.2}"
SM_SAFE="${SESSION_NAME//[-:.]/_}_${SM_PANE//[-:.]/_}"
PANE="${SESSION_NAME}:${SM_PANE}"; PANE_SAFE="$SM_SAFE"
_SM_STATUS_FILE="${RUNTIME_DIR}/status/${SM_SAFE}.status"
trap 'NOW=$(date "+%Y-%m-%dT%H:%M:%S%z"); write_pane_status "$_SM_STATUS_FILE" "BUSY" "SM idle — listening" 2>/dev/null || true' EXIT
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/session_manager_trigger"
TRIGGER2="${RUNTIME_DIR}/triggers/${SM_SAFE}.trigger"
TRIGGER3="${RUNTIME_DIR}/status/sm_trigger"

_SM_DBG=false; [ -f "${RUNTIME_DIR}/debug.conf" ] && _SM_DBG=true
_SM_DBG_FILE="${RUNTIME_DIR}/debug/session_manager.jsonl"

_sm_dbg_wake() {
  [ "$_SM_DBG" = "true" ] || return 0
  mkdir -p "$(dirname "$_SM_DBG_FILE")" 2>/dev/null
  printf '{"ts":%s,"cat":"sm","msg":"sm_wake","reason":"%s","wait_s":%s}\n' \
    "$(date +%s)" "$1" "${2:-0}" >> "$_SM_DBG_FILE" 2>/dev/null
}

_wake() { _sm_bump_cycle; _sm_dbg_wake "$1" "${2:-0}"; echo "$1"; exit 0; }

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

_check_stale_heartbeats() {
  local _hb _now _hb_time _task_id _pane_id _age _found=false
  _now=$(date +%s)
  for _hb in "$RUNTIME_DIR/status"/*.heartbeat; do
    [ -f "$_hb" ] || continue
    read -r _hb_time _task_id _pane_id < "$_hb" 2>/dev/null || continue
    [ -z "$_hb_time" ] && continue
    _age=$(( _now - _hb_time ))
    [ "$_age" -ge 90 ] || continue
    printf '%s %s %s %s\n' "$_pane_id" "$_task_id" "$_hb_time" "$_age" \
      > "${RUNTIME_DIR}/status/stale_${_pane_id}" 2>/dev/null || true
    _found=true
  done
  [ "$_found" = true ]
}

CYCLE_FILE="${RUNTIME_DIR}/status/sm_cycle_count"
COMPACT_INTERVAL="${DOEY_SM_COMPACT_INTERVAL:-20}"
_sm_cycle=0
[ -f "$CYCLE_FILE" ] && _sm_cycle=$(cat "$CYCLE_FILE" 2>/dev/null || echo 0)

_sm_bump_cycle() {
  _sm_cycle=$((_sm_cycle + 1))
  echo "$_sm_cycle" > "$CYCLE_FILE"
}

_check_work() {  # Exits script if work found, returns 1 otherwise
  local elapsed="$1"
  if [ -f "$TRIGGER" ] || [ -f "$TRIGGER2" ] || [ -f "$TRIGGER3" ]; then
    rm -f "$TRIGGER" "$TRIGGER2" "$TRIGGER3" 2>/dev/null; _wake "TRIGGERED" "$elapsed"
  fi
  set -- "$MSG_DIR"/${SM_SAFE}_*.msg
  [ -f "${1:-}" ] && _wake "NEW_MESSAGES" "$elapsed"
  if _has_new_results; then _mark_results_seen; _wake "NEW_RESULTS" "$elapsed"; fi
  set -- "$RUNTIME_DIR/status"/crash_pane_*
  [ -f "${1:-}" ] && _wake "CRASH_ALERT" "$elapsed"
  _check_stale_heartbeats && _wake "STALE_HEARTBEAT" "$elapsed"
  if [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
    local _tf
    for _tf in "${PROJECT_DIR:-.}/.doey/tasks"/*.task; do
      [ -f "$_tf" ] || continue
      grep -q 'TASK_STATUS=active' "$_tf" 2>/dev/null || continue
      grep -q 'TASK_TEAM=' "$_tf" 2>/dev/null && continue
      _wake "QUEUED_TASKS" "$elapsed"
    done
  fi
  return 1
}

_all_idle() {
  local _td="${PROJECT_DIR:-.}/.doey/tasks"
  if [ -d "$_td" ]; then
    local _tf
    for _tf in "$_td"/*.task; do
      [ -f "$_tf" ] || continue
      case "$(grep '^TASK_STATUS=' "$_tf" 2>/dev/null | cut -d= -f2-)" in
        active|in_progress) return 1 ;;
      esac
    done
  fi
  local _sf
  for _sf in "$RUNTIME_DIR/status"/*.status; do
    [ -f "$_sf" ] || continue
    grep -q '^STATUS: BUSY' "$_sf" 2>/dev/null && return 1
  done
  return 0
}

if [ "$((_sm_cycle + 1))" -ge "$COMPACT_INTERVAL" ]; then
  echo "0" > "$CYCLE_FILE"; _wake "COMPACT_CYCLE"
fi

_check_work "0" || true

_has_active=false; _active_list=""
if [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
  for _tf in "${PROJECT_DIR:-.}"/.doey/tasks/*.task; do
    [ -f "$_tf" ] || continue
    _status=$(grep '^TASK_STATUS=' "$_tf" 2>/dev/null | head -1 | cut -d= -f2-) || continue
    case "$_status" in active|in_progress)
      _has_active=true; _active_list="${_active_list}$(basename "$_tf" .task): ${_status}\n" ;;
    esac
  done
fi
if [ "$_has_active" = "true" ]; then
  _sm_bump_cycle; _sm_dbg_wake "active_tasks" "0"
  printf 'ACTIVE_TASKS %b' "$_active_list"
  rm -f "${RUNTIME_DIR}/status/sm_sleep_reported" 2>/dev/null
  exit 0
fi

_sleep_flag="${RUNTIME_DIR}/status/sm_sleep_reported"
if [ ! -f "$_sleep_flag" ] && [ -d "${RUNTIME_DIR}/messages" ]; then
  _boss_safe="${SESSION_NAME//[-:.]/_}_0_1"
  printf 'FROM: SessionManager\nSUBJECT: sleep_report\nAll tasks resolved. SM entering sleep.\n' \
    > "${RUNTIME_DIR}/messages/${_boss_safe}_$(date +%s)_$$.msg"
  touch "$_sleep_flag"
fi

_sleep_dur=3; _all_idle && _sleep_dur=10
sleep "$_sleep_dur"
_check_work "$_sleep_dur" || true
_sm_dbg_wake "idle" "$_sleep_dur"
echo "IDLE"
