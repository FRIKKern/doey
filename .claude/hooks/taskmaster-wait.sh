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

# ── Context % monitoring — auto-compact at 70%, restart at 85% ──────
_CTX_COMPACT_COOLDOWN="${RUNTIME_DIR}/status/taskmaster_compact_ts"
_CTX_RESTART_COOLDOWN="${RUNTIME_DIR}/status/taskmaster_restart_ts"
_CTX_LOG="${RUNTIME_DIR}/logs/taskmaster-context.log"
_CTX_COOLDOWN_SECS=300  # 5 minutes

_taskmaster_ctx_log() {
  mkdir -p "$(dirname "$_CTX_LOG")" 2>/dev/null
  printf '%s [ctx] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >> "$_CTX_LOG" 2>/dev/null
}

_taskmaster_cooldown_ok() {
  local _ts_file="$1" _now _last
  [ ! -f "$_ts_file" ] && return 0
  _last=$(cat "$_ts_file" 2>/dev/null) || _last=0
  _now=$(date +%s)
  [ $((_now - _last)) -ge "$_CTX_COOLDOWN_SECS" ]
}

_taskmaster_context_check() {
  # Read context % from statusline-written file
  local _tm_win="${TASKMASTER_PANE%%.*}"
  local _tm_idx="${TASKMASTER_PANE#*.}"
  local _ctx_file="${RUNTIME_DIR}/status/context_pct_${_tm_win}_${_tm_idx}"
  local _ctx_pct=0
  [ -f "$_ctx_file" ] && _ctx_pct=$(cat "$_ctx_file" 2>/dev/null) || _ctx_pct=0
  _ctx_pct="${_ctx_pct%%[!0-9]*}"  # strip non-numeric
  [ -z "$_ctx_pct" ] && _ctx_pct=0

  local _full_pane="${SESSION_NAME}:${TASKMASTER_PANE}"

  # At 85%+: kill and relaunch with fresh context
  if [ "$_ctx_pct" -ge 85 ] && _taskmaster_cooldown_ok "$_CTX_RESTART_COOLDOWN"; then
    _taskmaster_ctx_log "context at ${_ctx_pct}% — restarting Taskmaster"
    date +%s > "$_CTX_RESTART_COOLDOWN"

    # Kill the Claude process in the Taskmaster pane
    local _pane_pid _child_pid
    _pane_pid=$(tmux display-message -t "$_full_pane" -p '#{pane_pid}' 2>/dev/null) || true
    if [ -n "$_pane_pid" ]; then
      _child_pid=$(pgrep -P "$_pane_pid" 2>/dev/null | head -1) || true
      [ -n "$_child_pid" ] && kill "$_child_pid" 2>/dev/null || true
    fi
    sleep 3

    # Rebuild launch command from session env
    local _tm_model _tm_agent _proj
    _tm_model="${DOEY_TASKMASTER_MODEL:-opus}"
    _tm_agent="${DOEY_ROLE_FILE_COORDINATOR:-doey-taskmaster}"
    _proj="${SESSION_NAME#doey-}"
    local _relaunch="claude --dangerously-skip-permissions --model ${_tm_model} --name \"${DOEY_ROLE_COORDINATOR:-Taskmaster}\" --agent \"${_tm_agent}\""
    [ -f "${RUNTIME_DIR}/doey-settings.json" ] && _relaunch="${_relaunch} --settings \"${RUNTIME_DIR}/doey-settings.json\""
    tmux copy-mode -q -t "$_full_pane" 2>/dev/null
    tmux send-keys -t "$_full_pane" Escape 2>/dev/null
    sleep 0.1
    tmux send-keys -t "$_full_pane" "$_relaunch" Enter

    # Wait for Claude to boot, then re-brief with active tasks
    sleep 8
    local _brief="You were auto-restarted due to high context usage (${_ctx_pct}%). Session: ${SESSION_NAME}."
    local _task_summary=""
    if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
      local _tl_line
      for _tl_line in $({ doey-ctl task list --status active --project-dir "$PROJECT_DIR" 2>/dev/null; doey-ctl task list --status in_progress --project-dir "$PROJECT_DIR" 2>/dev/null; } | awk 'NR>1 && /^[0-9]/{print $1}'); do
        local _tinfo _atitle _astatus
        _tinfo=$(doey-ctl task get --id "$_tl_line" --project-dir "$PROJECT_DIR" 2>/dev/null) || continue
        _atitle=$(echo "$_tinfo" | sed -n 's/^Title:[[:space:]]*//p')
        _astatus=$(echo "$_tinfo" | sed -n 's/^Status:[[:space:]]*//p')
        [ -n "$_atitle" ] && _task_summary="${_task_summary} #${_tl_line} ${_atitle} (${_astatus}),"
      done
    fi
    if [ -z "$_task_summary" ] && [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
      local _atf _aid _atitle _astatus
      for _atf in "${PROJECT_DIR:-.}"/.doey/tasks/*.task; do
        [ -f "$_atf" ] || continue
        _astatus=$(grep '^TASK_STATUS=' "$_atf" 2>/dev/null | head -1 | cut -d= -f2-) || continue
        case "$_astatus" in active|in_progress)
          _aid=$(grep '^TASK_ID=' "$_atf" 2>/dev/null | head -1 | cut -d= -f2-) || _aid="?"
          _atitle=$(grep '^TASK_TITLE=' "$_atf" 2>/dev/null | head -1 | cut -d= -f2-) || _atitle=""
          _task_summary="${_task_summary} #${_aid} ${_atitle} (${_astatus}),"
        ;; esac
      done
    fi
    [ -n "$_task_summary" ] && _brief="${_brief} Active tasks:${_task_summary%,}."
    doey_send_verified "$_full_pane" "$_brief" || true
    _taskmaster_ctx_log "relaunch complete — briefed with active tasks"
    return 0
  fi

  # At 70%+: auto-compact
  if [ "$_ctx_pct" -ge 70 ] && _taskmaster_cooldown_ok "$_CTX_COMPACT_COOLDOWN"; then
    _taskmaster_ctx_log "context at ${_ctx_pct}% — sending /compact"
    date +%s > "$_CTX_COMPACT_COOLDOWN"
    doey_send_verified "$_full_pane" "/compact" || true
    return 0
  fi
}

_check_work() {  # Exits script if work found, returns 1 otherwise
  local elapsed="$1"
  local _trig_found=false _tf
  [ -f "$TRIGGER" ] && _trig_found=true
  for _tf in "${RUNTIME_DIR}/triggers/"*; do [ -f "$_tf" ] && { _trig_found=true; break; }; done
  if [ "$_trig_found" = true ]; then
    rm -f "$TRIGGER" "${RUNTIME_DIR}/triggers/"* 2>/dev/null; _wake "TRIGGERED" "$elapsed"
  fi
  # Check for unread messages via unified msg command (fast path)
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    _unread=$(doey msg count --to "$TASKMASTER_PANE" --project-dir "$PROJECT_DIR" 2>/dev/null) || _unread=0
    [ "${_unread:-0}" -gt 0 ] && _wake "MSG" "$elapsed"
  else
    # File-based message check (fallback) — match both full and short pane safe prefixes
    local _mf _pane_safe="${TASKMASTER_PANE//[-:.]/_}"
    for _mf in "$MSG_DIR"/${TASKMASTER_SAFE}_*.msg "$MSG_DIR"/"${_pane_safe}"_*.msg; do
      [ -f "$_mf" ] && _wake "MSG" "$elapsed"
    done
  fi
  if _has_new_results; then _mark_results_seen; _wake "FINISHED" "$elapsed"; fi
  set -- "$RUNTIME_DIR/status"/crash_pane_*
  [ -f "${1:-}" ] && _wake "CRASH" "$elapsed"
  _check_stale_heartbeats && _wake "STALE" "$elapsed"
  [ "$_has_queued" = true ] && _wake "QUEUED" "$elapsed"
  return 1
}

# Combined task scan — single pass sets _has_queued and _has_active
_has_queued=false; _has_active=false; _active_list=""
_task_scan_done=false

# DB fast path: use doey-ctl task list + task get for team/updated checks
if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
  _now_ts=$(date +%s)
  for _tl_st in active in_progress; do
    for _tid in $(doey-ctl task list --status "$_tl_st" --project-dir "$PROJECT_DIR" 2>/dev/null | awk 'NR>1 && /^[0-9]/{print $1}'); do
      _tinfo=$(doey-ctl task get --id "$_tid" --project-dir "$PROJECT_DIR" 2>/dev/null) || continue
      _tteam=$(echo "$_tinfo" | sed -n 's/^Team:[[:space:]]*//p')
      [ -n "$_tteam" ] && continue  # assigned to a team — skip
      _tstatus=$(echo "$_tinfo" | sed -n 's/^Status:[[:space:]]*//p')
      case "$_tstatus" in active|in_progress) ;; *) continue ;; esac
      _has_active=true
      _active_list="${_active_list}${_tid}: ${_tl_st}\n"
      if [ "$_tl_st" = "active" ]; then
        _task_updated=$(echo "$_tinfo" | sed -n 's/^Created:[[:space:]]*//p')
        _task_ts=0
        if [ -n "$_task_updated" ]; then
          _task_ts=$(date -d "$_task_updated" +%s 2>/dev/null) || _task_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${_task_updated%%Z*}" +%s 2>/dev/null) || _task_ts=0
        fi
        if [ "$_task_ts" -eq 0 ] || [ $((_now_ts - _task_ts)) -ge 30 ]; then
          _has_queued=true
        fi
      fi
    done
  done
  _task_scan_done=true
fi

# File fallback
if [ "$_task_scan_done" = false ] && [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
  _now_ts=$(date +%s)
  for _tf in "${PROJECT_DIR:-.}"/.doey/tasks/*.task; do
    [ -f "$_tf" ] || continue
    _status=$(grep '^TASK_STATUS=' "$_tf" 2>/dev/null | head -1 | cut -d= -f2-) || continue
    case "$_status" in
      active)
        if ! grep -q 'TASK_TEAM=' "$_tf" 2>/dev/null; then
          _task_updated=$(grep '^TASK_UPDATED=' "$_tf" 2>/dev/null | head -1 | cut -d= -f2-) || _task_updated=""
          _task_ts=0
          if [ -n "$_task_updated" ]; then
            _task_ts=$(date -d "$_task_updated" +%s 2>/dev/null) || _task_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$_task_updated" +%s 2>/dev/null) || _task_ts=0
          fi
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

# Check context % and auto-compact/restart if needed
_taskmaster_context_check || true

if [ "$_has_active" = "true" ]; then
  _taskmaster_bump_cycle
  sleep 15
  # One-shot: return control immediately after sleep — do NOT re-check.
  # Claude will process any pending input (paste-buffer, messages, etc.)
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

_sleep_dur=15
# Use inotifywait for event-driven blocking if available
if command -v inotifywait >/dev/null 2>&1; then
  mkdir -p "${RUNTIME_DIR}/triggers" 2>/dev/null
  inotifywait -qq -t "$_sleep_dur" -e create,modify \
    "${RUNTIME_DIR}/status/" \
    "${RUNTIME_DIR}/results/" \
    "${MSG_DIR}/" \
    "${RUNTIME_DIR}/triggers/" 2>/dev/null || true
else
  sleep "$_sleep_dur"
fi
# Consume trigger files written during sleep/inotifywait (race edge case)
_trig_found=false
[ -f "$TRIGGER" ] && _trig_found=true
for _tf in "${RUNTIME_DIR}/triggers/"*; do [ -f "$_tf" ] && { _trig_found=true; break; }; done
if [ "$_trig_found" = true ]; then
  rm -f "$TRIGGER" "${RUNTIME_DIR}/triggers/"* 2>/dev/null
  _taskmaster_dbg_wake "trigger_post_sleep" "$_sleep_dur"
  echo "WAKE_REASON=TRIGGERED"
  exit 0
fi
# One-shot: return control immediately after sleep/inotifywait.
# Do NOT re-check — Claude must reach its prompt to process paste-buffer input.
_taskmaster_dbg_wake "idle" "$_sleep_dur"
echo "WAKE_REASON=TIMEOUT"
