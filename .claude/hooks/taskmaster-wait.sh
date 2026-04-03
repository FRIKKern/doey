#!/usr/bin/env bash
# Taskmaster wait — checks for pending work, sleeps briefly if idle.
set -euo pipefail

if [ -n "${DOEY_RUNTIME:-}" ]; then RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then RUNTIME_DIR="$1"
else RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 5; exit 0; }
fi
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true
trap 'exit 0' ERR
source "$(dirname "$0")/common.sh" 2>/dev/null || true

TASKMASTER_PANE="${TASKMASTER_PANE:-$(get_taskmaster_pane)}"
TASKMASTER_SAFE="${SESSION_NAME//[-:.]/_}_${TASKMASTER_PANE//[-:.]/_}"
PANE="${SESSION_NAME}:${TASKMASTER_PANE}"; PANE_SAFE="$TASKMASTER_SAFE"
_TASKMASTER_STATUS_FILE="${RUNTIME_DIR}/status/${TASKMASTER_SAFE}.status"
trap 'NOW=$(date "+%Y-%m-%dT%H:%M:%S%z"); if command -v doey-ctl >/dev/null 2>&1; then doey status set "$TASKMASTER_SAFE" "BUSY" 2>/dev/null || true; else write_pane_status "$_TASKMASTER_STATUS_FILE" "BUSY" "${DOEY_ROLE_COORDINATOR} idle — listening" 2>/dev/null || true; fi' EXIT
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/taskmaster_trigger"
TRIGGER2="${RUNTIME_DIR}/triggers/${TASKMASTER_SAFE}.trigger"

_TASKMASTER_DBG=false; [ -f "${RUNTIME_DIR}/debug.conf" ] && _TASKMASTER_DBG=true
_TASKMASTER_DBG_FILE="${RUNTIME_DIR}/debug/taskmaster.jsonl"

_taskmaster_dbg_wake() {
  [ "$_TASKMASTER_DBG" = "true" ] || return 0
  mkdir -p "$(dirname "$_TASKMASTER_DBG_FILE")" 2>/dev/null
  printf '{"ts":%s,"cat":"taskmaster","msg":"taskmaster_wake","reason":"%s","wait_s":%s}\n' \
    "$(date +%s)" "$1" "${2:-0}" >> "$_TASKMASTER_DBG_FILE" 2>/dev/null
}

_wake() { _taskmaster_bump_cycle; _taskmaster_dbg_wake "$1" "${2:-0}"; echo "WAKE_REASON=$1"; exit 0; }

SEEN_FILE="${RUNTIME_DIR}/status/taskmaster_seen_results"
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

CYCLE_FILE="${RUNTIME_DIR}/status/taskmaster_cycle_count"
COMPACT_INTERVAL="${DOEY_TASKMASTER_COMPACT_INTERVAL:-20}"
_taskmaster_cycle=0
[ -f "$CYCLE_FILE" ] && _taskmaster_cycle=$(cat "$CYCLE_FILE" 2>/dev/null || echo 0)

_taskmaster_bump_cycle() {
  _taskmaster_cycle=$((_taskmaster_cycle + 1))
  echo "$_taskmaster_cycle" > "$CYCLE_FILE"
}

_check_work() {  # Exits script if work found, returns 1 otherwise
  local elapsed="$1"
  if [ -f "$TRIGGER" ] || [ -f "$TRIGGER2" ]; then
    rm -f "$TRIGGER" "$TRIGGER2" 2>/dev/null; _wake "TRIGGERED" "$elapsed"
  fi
  # Check for unread messages via unified msg command (fast path)
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    _unread=$(doey msg count --to "$TASKMASTER_PANE" --project-dir "$PROJECT_DIR" 2>/dev/null) || _unread=0
    [ "${_unread:-0}" -gt 0 ] && _wake "MSG" "$elapsed"
  fi
  # File-based message check (fallback) — match both full and short pane safe prefixes
  local _mf _pane_safe="${TASKMASTER_PANE//[-:.]/_}"
  for _mf in "$MSG_DIR"/${TASKMASTER_SAFE}_*.msg "$MSG_DIR"/"${_pane_safe}"_*.msg; do
    [ -f "$_mf" ] && _wake "MSG" "$elapsed"
  done
  if _has_new_results; then _mark_results_seen; _wake "FINISHED" "$elapsed"; fi
  set -- "$RUNTIME_DIR/status"/crash_pane_*
  [ -f "${1:-}" ] && _wake "CRASH" "$elapsed"
  _check_stale_heartbeats && _wake "STALE" "$elapsed"
  [ "$_has_queued" = true ] && _wake "QUEUED" "$elapsed"
  return 1
}

# Combined task scan — single pass sets _has_queued and _has_active
_has_queued=false; _has_active=false; _active_list=""
if [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
  for _tf in "${PROJECT_DIR:-.}"/.doey/tasks/*.task; do
    [ -f "$_tf" ] || continue
    _status=$(grep '^TASK_STATUS=' "$_tf" 2>/dev/null | head -1 | cut -d= -f2-) || continue
    case "$_status" in
      active)
        if ! grep -q 'TASK_TEAM=' "$_tf" 2>/dev/null; then
          # Only flag as queued if task has been in this state for >30s
          _task_updated=$(grep '^TASK_UPDATED=' "$_tf" 2>/dev/null | head -1 | cut -d= -f2-) || _task_updated=""
          _task_ts=0
          if [ -n "$_task_updated" ]; then
            _task_ts=$(date -d "$_task_updated" +%s 2>/dev/null) || _task_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$_task_updated" +%s 2>/dev/null) || _task_ts=0
          fi
          _now_ts=$(date +%s)
          if [ "$_task_ts" -eq 0 ] || [ $((_now_ts - _task_ts)) -ge 30 ]; then
            _has_queued=true
          fi
          _has_active=true
          _active_list="${_active_list}$(basename "$_tf" .task): ${_status}\n"
        fi
        ;;
      in_progress)
        if ! grep -q 'TASK_TEAM=' "$_tf" 2>/dev/null; then
          _has_active=true
          _active_list="${_active_list}$(basename "$_tf" .task): ${_status}\n"
        fi
        ;;
    esac
  done
fi

if [ "$((_taskmaster_cycle + 1))" -ge "$COMPACT_INTERVAL" ]; then
  echo "0" > "$CYCLE_FILE"; _wake "TRIGGERED"
fi

_check_work "0" || true

if [ "$_has_active" = "true" ]; then
  _taskmaster_bump_cycle
  sleep 15
  _check_work "15" || true
  _taskmaster_dbg_wake "active_tasks_idle" "15"
  echo "WAKE_REASON=QUEUED"
  printf 'ACTIVE_TASKS %b' "$_active_list"
  rm -f "${RUNTIME_DIR}/status/taskmaster_sleep_reported" 2>/dev/null
  exit 0
fi

_sleep_flag="${RUNTIME_DIR}/status/taskmaster_sleep_reported"
if [ ! -f "$_sleep_flag" ] && [ -d "${RUNTIME_DIR}/messages" ]; then
  _boss_safe="${SESSION_NAME//[-:.]/_}_0_1"
  printf "FROM: ${DOEY_ROLE_COORDINATOR}\nSUBJECT: sleep_report\nAll tasks resolved. ${DOEY_ROLE_COORDINATOR} entering sleep.\n" \
    > "${RUNTIME_DIR}/messages/${_boss_safe}_$(date +%s)_$$.msg"
  touch "$_sleep_flag"
fi

_sleep_dur=30
# Use inotifywait for event-driven blocking if available
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -qq -t "$_sleep_dur" -e create,modify \
    "${RUNTIME_DIR}/status/" \
    "${RUNTIME_DIR}/results/" \
    "${MSG_DIR}/" 2>/dev/null || true
else
  sleep "$_sleep_dur"
fi
_check_work "$_sleep_dur" || true
_taskmaster_dbg_wake "idle" "$_sleep_dur"
echo "WAKE_REASON=TIMEOUT"
