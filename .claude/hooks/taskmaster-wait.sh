#!/usr/bin/env bash
# Taskmaster wait — checks for pending work, sleeps briefly if idle.
set -euo pipefail

if [ -n "${DOEY_RUNTIME:-}" ]; then RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then RUNTIME_DIR="$1"
else RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 5; exit 0; }
fi
if [ -f "${RUNTIME_DIR}/session.env" ]; then
  while IFS='=' read -r _key _value; do
    _value="${_value%\"}"; _value="${_value#\"}"
    case "$_key" in
      SESSION_NAME) SESSION_NAME="$_value" ;;
      PROJECT_DIR)  PROJECT_DIR="$_value" ;;
      PROJECT_NAME) PROJECT_NAME="$_value" ;;
      GRID)         GRID="$_value" ;;
      TEAM_WINDOWS) TEAM_WINDOWS="$_value" ;;
    esac
  done < "${RUNTIME_DIR}/session.env"
fi
trap 'exit 0' ERR
source "$(dirname "$0")/common.sh" 2>/dev/null || true

# ── Role guard (task 648) ─────────────────────────────────────────────
# Subtaskmasters/Planners must use stm-wait.sh — this hook is coordinator-
# scoped (router triggers, MSG/FINISHED/CRASH/STALE/QUEUED on the
# Taskmaster pane). When STMs invoke this hook they silently sleep
# forever because their wake events come from worker-pane status
# transitions in their own team window. Reject early and let the caller
# adapt. Empty DOEY_ROLE allowed for legacy/test invocations. Core Team
# specialists (task_reviewer/deployment/doey_expert) still use the
# passive-role fast path below — they share the coordinator's signal set.
case "${DOEY_ROLE:-}" in
  "${DOEY_ROLE_ID_TEAM_LEAD:-team_lead}"|"${DOEY_ROLE_ID_PLANNER:-planner}"|team_lead|planner)
    echo "ERROR: ${DOEY_ROLE} must use stm-wait.sh, not taskmaster-wait.sh" >&2
    exit 0
    ;;
esac

TASKMASTER_PANE="${TASKMASTER_PANE:-$(get_taskmaster_pane)}"
TASKMASTER_SAFE="${SESSION_NAME//[-:.]/_}_${TASKMASTER_PANE//[-:.]/_}"
PANE="${SESSION_NAME}:${TASKMASTER_PANE}"; PANE_SAFE="$TASKMASTER_SAFE"
_TASKMASTER_STATUS_FILE="${RUNTIME_DIR}/status/${TASKMASTER_SAFE}.status"
trap 'NOW=$(date "+%Y-%m-%dT%H:%M:%S%z"); if command -v doey-ctl >/dev/null 2>&1; then doey status set "$TASKMASTER_SAFE" "BUSY" 2>/dev/null || true; else write_pane_status "$_TASKMASTER_STATUS_FILE" "BUSY" "${DOEY_ROLE_COORDINATOR} idle — listening" 2>/dev/null || true; fi' EXIT
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/taskmaster_trigger"
TRIGGER2="${RUNTIME_DIR}/triggers/${TASKMASTER_SAFE}.trigger"

# ── Passive role fast path ────────────────────────────────────────────
# Core Team specialists (Task Reviewer 1.1, Deployment 1.2, Doey Expert 1.3)
# reuse this wait hook but should ONLY wake on messages/triggers for their
# own pane. They must NOT wake on ACTIVE_TASKS, QUEUED, FINISHED, STALE,
# or other Taskmaster-specific signals — doing so creates a tight spin loop.
_CALLER_PANE=""
_IS_PASSIVE=false
if [ -n "${TMUX_PANE:-}" ]; then
  _CALLER_PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}.#{pane_index}' 2>/dev/null) || _CALLER_PANE=""
  if [ -n "$_CALLER_PANE" ] && [ "$_CALLER_PANE" != "$TASKMASTER_PANE" ]; then
    _IS_PASSIVE=true
  fi
fi

if [ "$_IS_PASSIVE" = true ]; then
  _CALLER_SAFE="${SESSION_NAME//[-:.]/_}_${_CALLER_PANE//[-:.]/_}"
  # Override EXIT trap — passive roles must not touch Taskmaster status
  trap '' EXIT
  _passive_wake() { echo "WAKE_REASON=$1"; exit 0; }

  # Scan for expired review-request deadlines owned by the calling pane.
  # Markers are written by Subtaskmasters before sending subtask_review_request
  # to the Task Reviewer (1.1). Format: line1=epoch deadline, line2=TASK_ID,
  # line3=SUBTASK_ID. Expired markers are removed and wake fires REVIEW_TIMEOUT
  # so the Subtaskmaster can escalate to Taskmaster instead of blocking forever.
  _check_review_timeouts() {
    local _pane_short _rr_dir _f _line1 _now _any=false
    _pane_short="${_CALLER_PANE//[-:.]/_}"
    _rr_dir="${RUNTIME_DIR}/review_requests"
    [ -d "$_rr_dir" ] || return 1
    _now=$(date +%s)
    for _f in "$_rr_dir"/${_pane_short}_*.pending; do
      [ -f "$_f" ] || continue
      _line1=$(head -n1 "$_f" 2>/dev/null) || continue
      [ -n "$_line1" ] || continue
      case "$_line1" in ''|*[!0-9]*) continue ;; esac
      if [ "$_now" -ge "$_line1" ]; then
        rm -f "$_f" 2>/dev/null || true
        _any=true
      fi
    done
    [ "$_any" = true ]
  }

  # Check for triggers
  [ -f "$TRIGGER" ] && { rm -f "$TRIGGER" 2>/dev/null; _passive_wake "TRIGGERED"; }
  for _tf in "${RUNTIME_DIR}/triggers/"*; do
    [ -f "$_tf" ] && { rm -f "${RUNTIME_DIR}/triggers/"* 2>/dev/null; _passive_wake "TRIGGERED"; }
  done

  # Check for messages to this pane (doey-ctl or file-based)
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    _unread=$(doey msg count --to "$_CALLER_PANE" --project-dir "$PROJECT_DIR" 2>/dev/null) || _unread=0
    [ "${_unread:-0}" -gt 0 ] && _passive_wake "MSG"
  else
    for _mf in "$MSG_DIR"/${_CALLER_SAFE}_*.msg "$MSG_DIR"/"${_CALLER_PANE//[-:.]/_}"_*.msg; do
      [ -f "$_mf" ] && _passive_wake "MSG"
    done
  fi

  # Check for expired review-request deadlines (pre-sleep, fires immediately)
  _check_review_timeouts && _passive_wake "REVIEW_TIMEOUT"

  # No work — block-wait (longer interval than Taskmaster's 15s)
  _passive_sleep=30
  if command -v inotifywait >/dev/null 2>&1; then
    mkdir -p "${RUNTIME_DIR}/triggers" 2>/dev/null
    inotifywait -qq -t "$_passive_sleep" -e create,modify \
      "${MSG_DIR}/" \
      "${RUNTIME_DIR}/triggers/" 2>/dev/null || true
  else
    sleep "$_passive_sleep"
  fi

  # Re-check after sleep
  for _tf in "${RUNTIME_DIR}/triggers/"*; do
    [ -f "$_tf" ] && { rm -f "${RUNTIME_DIR}/triggers/"* 2>/dev/null; _passive_wake "TRIGGERED"; }
  done
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    _unread=$(doey msg count --to "$_CALLER_PANE" --project-dir "$PROJECT_DIR" 2>/dev/null) || _unread=0
    [ "${_unread:-0}" -gt 0 ] && _passive_wake "MSG"
  else
    for _mf in "$MSG_DIR"/${_CALLER_SAFE}_*.msg "$MSG_DIR"/"${_CALLER_PANE//[-:.]/_}"_*.msg; do
      [ -f "$_mf" ] && _passive_wake "MSG"
    done
  fi

  # Re-check for expired review-request deadlines (post-sleep)
  _check_review_timeouts && _passive_wake "REVIEW_TIMEOUT"

  # Safety net: check if all workers in team are done before TIMEOUT
  _caller_window=$(echo "$_CALLER_PANE" | cut -d. -f1)
  _team_env="${RUNTIME_DIR}/team_${_caller_window}.env"
  if [ -f "$_team_env" ]; then
    _all_fin=true
    _w_list=$(grep '^WORKER_PANES=' "$_team_env" | sed 's/^WORKER_PANES=//;s/"//g')
    for _wp in $(echo "$_w_list" | tr ',' ' '); do
      _wp_safe=$(echo "${SESSION_NAME}:${_caller_window}.${_wp}" | tr ':.-' '_')
      _wp_st=$(grep '^STATUS=' "${RUNTIME_DIR}/status/${_wp_safe}.status" 2>/dev/null | head -1 | cut -d= -f2)
      case "$_wp_st" in
        FINISHED|RESERVED) ;;
        *) _all_fin=false; break ;;
      esac
    done
    if [ "$_all_fin" = "true" ]; then
      echo "WAKE_REASON=ALL_DONE"
      exit 0
    fi
  fi

  echo "WAKE_REASON=TIMEOUT"
  exit 0
fi
# ── End passive role fast path ────────────────────────────────────────

_TASKMASTER_DBG=false; [ -f "${RUNTIME_DIR}/debug.conf" ] && _TASKMASTER_DBG=true
_TASKMASTER_DBG_FILE="${RUNTIME_DIR}/debug/taskmaster.jsonl"

_taskmaster_dbg_wake() {
  [ "$_TASKMASTER_DBG" = "true" ] || return 0
  mkdir -p "$(dirname "$_TASKMASTER_DBG_FILE")" 2>/dev/null
  printf '{"ts":%s,"cat":"taskmaster","msg":"taskmaster_wake","reason":"%s","wait_s":%s}\n' \
    "$(date +%s)" "$1" "${2:-0}" >> "$_TASKMASTER_DBG_FILE" 2>/dev/null
}

_wake() {
  _taskmaster_dbg_wake "$1" "${2:-0}"
  # Stats emit (task #521 Phase 2) — cooldown-gated so polling does NOT
  # flood stats.db. Emit on state change (idle → wake) only.
  if command -v doey-stats-emit.sh >/dev/null 2>&1 && _check_cooldown "taskmaster_wake" 30 2>/dev/null; then
    (doey-stats-emit.sh worker taskmaster_wake "reason=${1:-unknown}" &) 2>/dev/null || true
  fi
  echo "WAKE_REASON=$1"; exit 0
}

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

# ── Core-team specialist escalation ladder (task 24) ──────────────────
# Reviewer (<coreWin>.1) and Deployment (<coreWin>.2) get a three-tier
# stale-heartbeat escalation instead of jumping straight from 300s silent
# to hard restart. Tier 1 at 180s nudges. Tier 2 at 360s sends /clear to
# drop context. Tier 3 at 600s falls through to the normal stale_pending
# → _enforce_stale_restart path. Worker panes retain their original 300s
# single-tier behavior.
_is_core_specialist() {
  local _pid="$1" _cw _w _p
  _cw=$(get_core_team_window 2>/dev/null || echo 1)
  _w=$(printf '%s' "$_pid" | awk -F_ '{print $(NF-1)}')
  _p=$(printf '%s' "$_pid" | awk -F_ '{print $NF}')
  [ "$_w" = "$_cw" ] && { [ "$_p" = "1" ] || [ "$_p" = "2" ]; }
}

_core_tier_cooldown_ok() {
  # $1=breadcrumb path, $2=cooldown seconds. Returns 0 if ok to fire.
  local _bc="$1" _cd="$2" _now _mt
  [ -f "$_bc" ] || return 0
  _now=$(date +%s)
  _mt=$(stat -c%Y "$_bc" 2>/dev/null || stat -f%m "$_bc" 2>/dev/null || echo 0)
  [ $((_now - _mt)) -ge "$_cd" ]
}

_core_tier_nudge() {
  local _pid="$1" _bc _now
  _bc="${RUNTIME_DIR}/recovery/${_pid}.nudge_tier1"
  mkdir -p "${RUNTIME_DIR}/recovery" "${RUNTIME_DIR}/triggers" 2>/dev/null
  _core_tier_cooldown_ok "$_bc" 180 || return 0
  _now=$(date +%s)
  touch "${RUNTIME_DIR}/triggers/${_pid}.trigger" 2>/dev/null || true
  printf '%s nudge\n' "$_now" > "${_bc}.tmp" 2>/dev/null && mv "${_bc}.tmp" "$_bc" 2>/dev/null || true
  _log_restart "$_pid" "tier1_nudge" "age-tier nudge at 180s — trigger touched"
}

_core_tier_softclear() {
  local _pid="$1" _bc _now _w _p _tgt
  _bc="${RUNTIME_DIR}/recovery/${_pid}.softclear_tier2"
  mkdir -p "${RUNTIME_DIR}/recovery" 2>/dev/null
  _core_tier_cooldown_ok "$_bc" 120 || return 0
  _now=$(date +%s)
  _w=$(printf '%s' "$_pid" | awk -F_ '{print $(NF-1)}')
  _p=$(printf '%s' "$_pid" | awk -F_ '{print $NF}')
  _tgt="${SESSION_NAME}:${_w}.${_p}"
  tmux copy-mode -q -t "$_tgt" 2>/dev/null || :
  if ! type doey_send_command >/dev/null 2>&1; then
    [ -f "$HOME/.local/bin/doey-send.sh" ] && . "$HOME/.local/bin/doey-send.sh" 2>/dev/null || true
  fi
  if type doey_send_command >/dev/null 2>&1; then
    doey_send_command "$_tgt" "/clear" 2>/dev/null || true
  else
    tmux send-keys -t "$_tgt" "/clear" Enter 2>/dev/null || true
  fi
  printf '%s softclear\n' "$_now" > "${_bc}.tmp" 2>/dev/null && mv "${_bc}.tmp" "$_bc" 2>/dev/null || true
  _log_restart "$_pid" "tier2_softclear" "age-tier /clear at 360s — context dropped in place"
}

_check_stale_heartbeats() {
  local _hb _now _hb_time _task_id _pane_id _age _found=false
  _now=$(date +%s)
  for _hb in "$RUNTIME_DIR/status"/*.heartbeat; do
    [ -f "$_hb" ] || continue
    read -r _hb_time _task_id _pane_id < "$_hb" 2>/dev/null || continue
    [ -z "$_hb_time" ] && continue
    _age=$(( _now - _hb_time ))

    # ── Core-team specialist escalation (tiers 1 & 2) ────────────────
    # For reviewer/deployment, run sub-600s tiers before the main
    # threshold check. Tier 3 (>=600s) falls through to the generic
    # stale-marker path below with threshold overridden to 600.
    local _is_core=false
    if _is_core_specialist "$_pane_id"; then
      _is_core=true
      # Skip terminal states early — do not nudge/clear a done pane
      local _core_sf="${RUNTIME_DIR}/status/${_pane_id}.status"
      if [ -f "$_core_sf" ]; then
        local _core_st
        _core_st=$(grep '^STATUS: ' "$_core_sf" 2>/dev/null | head -1 | sed 's/^STATUS: //') || _core_st=""
        case "$_core_st" in FINISHED|RESERVED) continue ;; esac
      fi
      if [ "$_age" -ge 180 ] && [ "$_age" -lt 360 ]; then
        _core_tier_nudge "$_pane_id"
        continue
      fi
      if [ "$_age" -ge 360 ] && [ "$_age" -lt 600 ]; then
        _core_tier_softclear "$_pane_id"
        continue
      fi
      # age >= 600 → clear cooldown breadcrumbs and fall through to
      # the hard-restart path with a fixed 600s threshold.
      rm -f "${RUNTIME_DIR}/recovery/${_pane_id}.nudge_tier1" \
            "${RUNTIME_DIR}/recovery/${_pane_id}.softclear_tier2" 2>/dev/null || true
    fi

    # Managers (pane index 0) get a longer timeout than workers
    local _threshold
    if [ "$_is_core" = true ]; then
      _threshold=600
    else
      case "$_pane_id" in
        *_0) _threshold="${DOEY_STALE_MANAGER_TIMEOUT:-600}" ;;
        *)   _threshold="${DOEY_STALE_WORKER_TIMEOUT:-300}" ;;
      esac
    fi
    [ "$_age" -ge "$_threshold" ] || continue
    # Skip FINISHED/RESERVED workers — they are done, not stale
    local _hb_status_file="${RUNTIME_DIR}/status/${_pane_id}.status"
    if [ -f "$_hb_status_file" ]; then
      local _hb_cur_st
      _hb_cur_st=$(grep '^STATUS: ' "$_hb_status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //') || _hb_cur_st=""
      case "$_hb_cur_st" in FINISHED|RESERVED) continue ;; esac
    fi
    printf '%s %s %s %s\n' "$_pane_id" "$_task_id" "$_hb_time" "$_age" \
      > "${RUNTIME_DIR}/status/stale_${_pane_id}" 2>/dev/null || true
    _found=true
  done
  [ "$_found" = true ]
}

_check_stale_booting() {
  local _sf _line _status _updated _now _boot_ts _age _pane_id _found=false
  local _timeout="${DOEY_BOOT_TIMEOUT:-60}"
  _now=$(date +%s)
  for _sf in "$RUNTIME_DIR/status"/*.status; do
    [ -f "$_sf" ] || continue
    _status=""; _updated=""
    while IFS= read -r _line; do
      case "$_line" in
        "STATUS: "*) _status="${_line#STATUS: }" ;;
        STATUS=*)    _status="${_line#STATUS=}" ;;
        "UPDATED: "*) _updated="${_line#UPDATED: }" ;;
        UPDATED=*)    _updated="${_line#UPDATED=}" ;;
      esac
    done < "$_sf"
    [ "$_status" = "BOOTING" ] || continue
    [ -n "$_updated" ] || continue
    _boot_ts=$(date -d "$_updated" +%s 2>/dev/null) \
      || _boot_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${_updated%%[+-]*}" +%s 2>/dev/null) \
      || continue
    _age=$(( _now - _boot_ts ))
    [ "$_age" -ge "$_timeout" ] || continue
    _pane_id=$(basename "$_sf" .status)
    printf 'BOOT_STUCK %s age=%ss timeout=%ss\n' "$_pane_id" "$_age" "$_timeout" \
      > "${RUNTIME_DIR}/status/crash_pane_${_pane_id}" 2>/dev/null || true
    _found=true
  done
  [ "$_found" = true ]
}

_log_restart() {
  local _pane_id="${1:-}" _action="${2:-}" _details="${3:-}"
  local _log_file="${RUNTIME_DIR}/issues/auto_restart.log"
  local _ts
  _ts=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "unknown")
  mkdir -p "$(dirname "$_log_file")" 2>/dev/null || true
  printf '[%s] PANE=%s ACTION=%s %s\n' "$_ts" "$_pane_id" "$_action" "$_details" \
    >> "$_log_file" 2>/dev/null
}

_enforce_stale_restart() {
  local _stale_dir="${RUNTIME_DIR}/status"
  local _restart_count_dir="${RUNTIME_DIR}/recovery"
  local _max_restarts="${DOEY_STALE_MAX_RESTARTS:-2}"
  local _any_restarted=false

  mkdir -p "$_restart_count_dir" 2>/dev/null || true

  for _marker in "$_stale_dir"/stale_*; do
    [ -f "$_marker" ] || continue

    local _pane_id
    _pane_id=$(basename "$_marker" | sed 's/^stale_//')

    # Read stale marker for details
    local _stale_info
    _stale_info=$(cat "$_marker" 2>/dev/null) || continue

    # ── Strong-proof gate: require 2 consecutive stale observations ──
    # First observation writes a .stale_pending file; only on second
    # observation (marker still present on next cycle) do we proceed.
    local _pending_file="${_restart_count_dir}/${_pane_id}.stale_pending"
    if [ ! -f "$_pending_file" ]; then
      # First observation — record timestamp, skip restart this cycle
      date +%s > "$_pending_file" 2>/dev/null || true
      _log_restart "$_pane_id" "pending" "First stale observation — waiting for confirmation"
      continue
    fi

    # Re-verify heartbeat is STILL stale (worker may have resumed)
    local _hb_file="${_stale_dir}/${_pane_id}.heartbeat"
    if [ -f "$_hb_file" ]; then
      local _hb_now _hb_time_now _hb_age_now _hb_threshold_now
      _hb_now=$(date +%s)
      read -r _hb_time_now _ _ < "$_hb_file" 2>/dev/null || _hb_time_now=0
      _hb_age_now=$(( _hb_now - _hb_time_now ))
      case "$_pane_id" in
        *_0) _hb_threshold_now="${DOEY_STALE_MANAGER_TIMEOUT:-600}" ;;
        *)   _hb_threshold_now="${DOEY_STALE_WORKER_TIMEOUT:-300}" ;;
      esac
      if [ "$_hb_age_now" -lt "$_hb_threshold_now" ]; then
        # Heartbeat refreshed since first observation — worker recovered
        _log_restart "$_pane_id" "cleared" "Heartbeat refreshed (age=${_hb_age_now}s) — not stale"
        rm -f "$_marker" "$_pending_file"
        continue
      fi
    fi

    # Check status file — do NOT restart FINISHED or RESERVED workers
    local _status_file="${_stale_dir}/${_pane_id}.status"
    if [ -f "$_status_file" ]; then
      local _cur_st
      _cur_st=$(grep '^STATUS: ' "$_status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //') || _cur_st=""
      case "$_cur_st" in
        FINISHED|RESERVED)
          _log_restart "$_pane_id" "skipped" "Status is ${_cur_st} — not restarting"
          rm -f "$_marker" "$_pending_file"
          continue
          ;;
      esac
    fi

    # Confirmed stale — clean up pending file
    rm -f "$_pending_file"

    # Check restart count
    local _count_file="${_restart_count_dir}/${_pane_id}.auto_restart_count"
    local _count
    _count=$(cat "$_count_file" 2>/dev/null) || _count=0

    if [ "$_count" -ge "$_max_restarts" ]; then
      # Escalate — write crash file, don't restart
      printf 'STALE_EXHAUSTED %s restarts=%s max=%s\n' "$_pane_id" "$_count" "$_max_restarts" \
        > "${_stale_dir}/crash_pane_${_pane_id}"
      _log_restart "$_pane_id" "escalated" "Max $_max_restarts restarts reached"
      rm -f "$_marker"
      continue
    fi

    # Check if launch command exists
    local _launch_cmd_file="${_stale_dir}/${_pane_id}.launch_cmd"
    if [ ! -f "$_launch_cmd_file" ]; then
      _log_restart "$_pane_id" "skipped" "No .launch_cmd file found"
      rm -f "$_marker"
      continue
    fi

    # Resolve tmux target pane from pane_id (format: session_name_W_P)
    local _w_idx _p_idx _tmux_target
    _w_idx=$(echo "$_pane_id" | awk -F'_' '{print $(NF-1)}')
    _p_idx=$(echo "$_pane_id" | awk -F'_' '{print $NF}')
    _tmux_target="${SESSION_NAME}:${_w_idx}.${_p_idx}"

    # Kill existing Claude process
    local _pane_pid _child_pid
    _pane_pid=$(tmux display-message -t "$_tmux_target" -p '#{pane_pid}' 2>/dev/null) || {
      _log_restart "$_pane_id" "skipped" "Cannot resolve tmux pane"
      rm -f "$_marker"
      continue
    }
    _child_pid=$(pgrep -P "$_pane_pid" 2>/dev/null) || true
    if [ -n "$_child_pid" ]; then
      kill "$_child_pid" 2>/dev/null || true
    fi

    # Transition state: BUSY -> ERROR -> READY
    transition_state "$_pane_id" "ERROR" || true
    transition_state "$_pane_id" "READY" || {
      _log_restart "$_pane_id" "skipped" "State transition to READY failed"
      rm -f "$_marker"
      continue
    }

    # Increment restart count
    printf '%s\n' "$((_count + 1))" > "$_count_file"

    # Read saved launch command and relaunch
    local _launch_cmd
    _launch_cmd=$(cat "$_launch_cmd_file" 2>/dev/null) || {
      _log_restart "$_pane_id" "failed" "Cannot read launch_cmd"
      rm -f "$_marker"
      continue
    }

    if type doey_send_launch >/dev/null 2>&1; then
      doey_send_launch "$_tmux_target" "$_launch_cmd" || {
        _log_restart "$_pane_id" "failed" "doey_send_launch failed"
        rm -f "$_marker"
        continue
      }
    else
      tmux send-keys -t "$_tmux_target" "$_launch_cmd" Enter 2>/dev/null || {
        _log_restart "$_pane_id" "failed" "tmux send-keys failed"
        rm -f "$_marker"
        continue
      }
    fi

    _log_restart "$_pane_id" "restarted" "Auto-restart #$((_count + 1))/$_max_restarts"
    _any_restarted=true
    rm -f "$_marker"
  done

  [ "$_any_restarted" = "true" ]
}

CYCLE_FILE="${RUNTIME_DIR}/status/taskmaster_cycle_count"
COMPACT_INTERVAL="${DOEY_TASKMASTER_COMPACT_INTERVAL:-20}"
_taskmaster_cycle=0
[ -f "$CYCLE_FILE" ] && _taskmaster_cycle=$(cat "$CYCLE_FILE" 2>/dev/null || echo 0)

_taskmaster_bump_cycle() {
  _taskmaster_cycle=$((_taskmaster_cycle + 1))
  echo "$_taskmaster_cycle" > "$CYCLE_FILE"
}

# ── Polling-loop detector (task #525/#536) ────────────────────────────
# Runs on every wake cycle. If this pane keeps waking without any real
# tool work (no sentinel from on-pre-tool-use.sh), the counter bumps.
# At 3 → warn event, at 5 → breaker + nudge + 30s backoff.
violation_bump_counter "$PANE_SAFE" "TASKMASTER_WAIT" \
  "${SESSION_NAME:-}" "${DOEY_ROLE:-coordinator}" \
  "${TASKMASTER_PANE%%.*}" 2>/dev/null || true

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
    if type doey_send_launch >/dev/null 2>&1; then
      doey_send_launch "$_full_pane" "$_relaunch" || true
    else
      doey_send_command "$_full_pane" "$_relaunch"
    fi

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
  _enforce_stale_restart && _wake "RESTART" "$elapsed"
  _check_stale_booting && _wake "BOOT_STUCK" "$elapsed"
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
      _active_list="${_active_list}${_tid}: ${_tl_st}\n"
      if [ "$_tl_st" = "active" ]; then
        _has_active=true
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
          _active_list="${_active_list}$(basename "$_tf" .task): ${_status}\n"
        fi
        ;;
    esac
  done
fi

if [ "$((_taskmaster_cycle + 1))" -ge "$COMPACT_INTERVAL" ]; then
  _taskmaster_cycle=-1
  echo "0" > "$CYCLE_FILE"; _wake "TRIGGERED"
fi

_check_work "0" || true

# Check context % and auto-compact/restart if needed
_taskmaster_context_check || true

if [ "$_has_active" = "true" ]; then
  _taskmaster_bump_cycle
  sleep 15
  # Re-check for urgent work (messages, crashes, triggers) that arrived during sleep
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

# Pre-sleep guard: final check before entering blocking wait
_check_work "0" || true

_sleep_dur=60
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
# Re-check for messages/tasks that arrived during sleep
_check_work "$_sleep_dur" || true
_taskmaster_bump_cycle

# ── Late task re-scan: catch tasks queued during sleep ────────────────
_late_queued=false
if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
  _late_now=$(date +%s)
  for _late_tid in $(doey-ctl task list --status active --project-dir "$PROJECT_DIR" 2>/dev/null | awk 'NR>1 && /^[0-9]/{print $1}'); do
    _late_info=$(doey-ctl task get --id "$_late_tid" --project-dir "$PROJECT_DIR" 2>/dev/null) || continue
    _late_team=$(echo "$_late_info" | sed -n 's/^Team:[[:space:]]*//p')
    [ -n "$_late_team" ] && continue
    _late_queued=true; break
  done
fi
if [ "$_late_queued" = false ] && [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
  for _late_tf in "${PROJECT_DIR:-.}"/.doey/tasks/*.task; do
    [ -f "$_late_tf" ] || continue
    _late_st=$(grep '^TASK_STATUS=' "$_late_tf" 2>/dev/null | head -1 | cut -d= -f2-) || continue
    [ "$_late_st" = "active" ] || continue
    grep -q 'TASK_TEAM=' "$_late_tf" 2>/dev/null && continue
    _late_queued=true; break
  done
fi
if [ "$_late_queued" = true ]; then
  _wake "QUEUED" "$_sleep_dur"
fi

_taskmaster_dbg_wake "idle" "$_sleep_dur"
echo "WAKE_REASON=TIMEOUT"
