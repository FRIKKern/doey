#!/usr/bin/env bash
# Watchdog pre-filter scan — captures pane state, reports only changes.
# Hashes pane content to reduce LLM token usage.

set -euo pipefail

is_numeric() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }

NL='
'

# Parse ps cputime (M:SS.cc or H:MM:SS) into whole seconds
_parse_cpu_seconds() {
  local t="$1"
  [ -z "$t" ] && echo "0" && return
  local colons="${t//[^:]/}"
  case "${#colons}" in
    1) local m="${t%%:*}" r="${t#*:}"; echo "$((10#$m * 60 + 10#${r%%.*}))" ;;
    2) local h="${t%%:*}" r="${t#*:}"; local m="${r%%:*}" s="${r#*:}"
       echo "$((10#$h * 3600 + 10#$m * 60 + 10#${s%%.*}))" ;;
    *) echo "0" ;;
  esac
}

_get_pane_title() {
  local t
  t=$(tmux display-message -t "$1" -p '#{pane_title}' 2>/dev/null) || t=""
  echo "${t//\'/}"
}

_set_pane_info() {
  local idx="$1" state="$2" title="$3" tool="$4" prev="$5"
  printf -v "PANE_STATE_${idx}" '%s' "$state"
  printf -v "PANE_TITLE_${idx}" '%s' "$title"
  printf -v "PANE_TOOL_${idx}" '%s' "$tool"
  printf -v "PANE_PREV_DISPLAY_${idx}" '%s' "$prev"
}

_update_duration() {
  local idx="$1" prev="$2" cur="$3"
  local since_file="${RUNTIME_DIR}/status/state_since_${TARGET_WINDOW}_${idx}"
  if [ "$prev" != "$cur" ]; then
    _atomic_write "$since_file" "$SCAN_TIME"
    printf -v "PANE_DURATION_${idx}" '%s' "0"
    SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}STATE_CHANGE ${idx} ${prev}->${cur}${NL}"
  else
    local since
    read -r since < "$since_file" 2>/dev/null || { _atomic_write "$since_file" "$SCAN_TIME"; since="$SCAN_TIME"; }
    printf -v "PANE_DURATION_${idx}" '%s' "$(($SCAN_TIME - $since))"
  fi
}

_atomic_write() { echo "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

_format_duration() {
  local h=$(($1 / 3600)) m=$((($1 % 3600) / 60)) s=$(($1 % 60))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m${s}s"
  elif [ "$m" -gt 0 ]; then echo "${m}m${s}s"
  else echo "${s}s"
  fi
}

# Map internal states to display states
_display_state() {
  case "$1" in
    WORKING|CHANGED|UNCHANGED|STUCK) echo "WORKING" ;;
    IDLE|FINISHED) echo "IDLE" ;;
    *) echo "$1" ;;
  esac
}

# Get previous state for pane $1
_get_prev() { eval "echo \${PREV_STATE_${1}:-UNKNOWN}"; }

# Report pane state: _report_pane <idx> <state> [tool] [snapshot_event]
# Emits output line, logs, updates duration+info
_report_pane() {
  local idx="$1" state="$2" tool="${3:-}" event="${4:-}"
  local prev=$(_get_prev "$idx")
  local dprev=$(_display_state "$prev")
  echo "PANE ${idx} ${state}"
  _pane_log "${TARGET_WINDOW}.${idx}" "pane ${idx} state=${state}"
  [ -n "$event" ] && SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}${event}${NL}"
  _update_duration "$idx" "$dprev" "$state"
  _set_pane_info "$idx" "$state" "$(_get_pane_title "${SESSION_NAME}:${TARGET_WINDOW}.${idx}")" "$tool" "$dprev"
}

# Read hook STATUS from a .status file; sets _hook_status
_read_hook_status() {
  _hook_status=""
  [ -f "$1" ] || return 0
  local line
  line=$(grep '^STATUS:' "$1" 2>/dev/null | head -1) || return 0
  _hook_status="${line#STATUS: }"
}

# --- Load environment ---
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { echo "ERROR: not in doey session"; exit 1; }

PANE_INFO=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}.#{pane_index}' 2>/dev/null) || PANE_INFO="0.0"
WINDOW_INDEX="${PANE_INFO%.*}"
PANE_INDEX="${PANE_INFO#*.}"

# Find which team has WATCHDOG_PANE matching our pane
TARGET_WINDOW=""
for tf in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$tf" ] || continue
  wp=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2-)
  wp="${wp%\"}" && wp="${wp#\"}"
  if [ "$wp" = "0.${PANE_INDEX}" ]; then
    fn="${tf##*/}"
    fn="${fn#team_}"
    TARGET_WINDOW="${fn%.env}"
    break
  fi
done
if [ -z "$TARGET_WINDOW" ]; then
  echo "WARNING: No team found for watchdog pane 0.${PANE_INDEX}" >&2
  TARGET_WINDOW="$PANE_INDEX"
fi

TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WINDOW}.env"
_ENV_SRC="$TEAM_ENV"
[ -f "$TEAM_ENV" ] || _ENV_SRC="${RUNTIME_DIR}/session.env"
while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    WORKER_PANES) WORKER_PANES="$value" ;;
    SESSION_NAME) SESSION_NAME="$value" ;;
  esac
done < "$_ENV_SRC"

if command -v md5 >/dev/null 2>&1; then
  hash_fn() { md5 -qs "$1"; }
else
  hash_fn() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
fi

# Load previous pane states
PREV_STATES_FILE="${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json"
if [ -f "$PREV_STATES_FILE" ]; then
  PREV_JSON=$(cat "$PREV_STATES_FILE" 2>/dev/null) || PREV_JSON="{}"
  PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
  while IFS=: read -r pidx pstate; do
    pidx="${pidx// /}" pstate="${pstate// /}"
    is_numeric "$pidx" || continue
    case "$pstate" in
      IDLE|WORKING|CHANGED|UNCHANGED|CRASHED|STUCK|FINISHED|RESERVED|LOGGED_OUT|BOOTING|UNKNOWN) ;;
      *) continue ;;
    esac
    printf -v "PREV_STATE_${pidx}" '%s' "$pstate"
  done <<EOF
$PREV_PAIRS
EOF
fi

SESSION_SAFE="${SESSION_NAME//[:.]/_}"
SCAN_TIME=$(date +%s)
SNAPSHOT_EVENTS=""

# Debug mode check (watchdog has own logging, doesn't use common.sh)
_WDG_DBG=false
[ -f "${RUNTIME_DIR}/debug.conf" ] && _WDG_DBG=true
_WDG_DBG_FILE="${RUNTIME_DIR}/debug/watchdog_W${TARGET_WINDOW}.jsonl"

# Read scan cycle number from file, increment
_WDG_CYCLE_FILE="${RUNTIME_DIR}/status/watchdog_cycle_W${TARGET_WINDOW}"
_WDG_CYCLE=0
[ -f "$_WDG_CYCLE_FILE" ] && read -r _WDG_CYCLE < "$_WDG_CYCLE_FILE" 2>/dev/null
_WDG_CYCLE=$((_WDG_CYCLE + 1))
_atomic_write "$_WDG_CYCLE_FILE" "$_WDG_CYCLE"

# Watchdog-local _log — writes to watchdog's own log file
_log() {
  local msg="$1"
  local pane_id="${DOEY_PANE_ID:-watchdog}"
  [ -n "${RUNTIME_DIR:-}" ] && mkdir -p "${RUNTIME_DIR}/logs" && \
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] ${msg}" >> "${RUNTIME_DIR}/logs/${pane_id}.log"
}

# Structured error logger for watchdog anomaly detection
_log_error_wd() {
  local cat="$1" msg="$2" detail="${3:-}"
  local err_dir="${RUNTIME_DIR}/errors"
  mkdir -p "$err_dir" 2>/dev/null || return 0
  local _now; _now=$(date '+%Y-%m-%dT%H:%M:%S')
  printf '[%s] %s | %s | watchdog | watchdog-scan | n/a | %s | %s\n' \
    "$_now" "$cat" "${DOEY_PANE_ID:-watchdog}" "${detail:-n/a}" "$msg" \
    >> "${err_dir}/errors.log" 2>/dev/null
}

# Per-pane logging helper — writes to the scanned pane's log, not the watchdog's
_pane_log() {
  local pane_id="$1" msg="$2"
  [ -n "${RUNTIME_DIR:-}" ] && mkdir -p "${RUNTIME_DIR}/logs" && \
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] watchdog-scan: ${msg}" >> "${RUNTIME_DIR}/logs/${pane_id:-unknown}.log"
}

_log "watchdog-scan: start cycle W${TARGET_WINDOW} panes=${WORKER_PANES}"

# --- Manager health check (skip for freelancer teams) ---
_team_type=""
[ -f "$TEAM_ENV" ] && _team_type=$(grep '^TEAM_TYPE=' "$TEAM_ENV" | cut -d= -f2-) && _team_type="${_team_type%\"}" && _team_type="${_team_type#\"}"
MGR_PANE_REF=""
MGR_CMD=""
MGR_TITLE=""
if [ "$_team_type" != "freelancer" ]; then
  if [ -f "$TEAM_ENV" ]; then
    mgr_idx=$(grep '^MANAGER_PANE=' "$TEAM_ENV" | cut -d= -f2-)
    mgr_idx="${mgr_idx%\"}" && mgr_idx="${mgr_idx#\"}"
    [ -n "$mgr_idx" ] && MGR_PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.${mgr_idx}"
  fi
  [ -z "$MGR_PANE_REF" ] && MGR_PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.0"

  MGR_CMD=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
  case "$MGR_CMD" in
    bash|zsh|sh|fish)
      echo "MANAGER_CRASHED"
      _log_error_wd "ANOMALY" "Manager crashed in window $TARGET_WINDOW" "pane_cmd=bare_shell"
      CRASH_ALERT="${RUNTIME_DIR}/status/manager_crashed_W${TARGET_WINDOW}"
      if [ ! -f "$CRASH_ALERT" ]; then
        _tmp="${CRASH_ALERT}.tmp"
        printf 'TEAM_WINDOW=%s\nTIMESTAMP=%s\n' "${TARGET_WINDOW}" "$(date +%s)" > "$_tmp"
        mv "$_tmp" "$CRASH_ALERT"
      fi
      ;;
    *)
      rm -f "${RUNTIME_DIR}/status/manager_crashed_W${TARGET_WINDOW}" 2>/dev/null
      ;;
  esac
fi

# Manager monitoring — skip entirely for freelancer teams (no manager)
PANE_STATE_0="N/A"
if [ "$_team_type" != "freelancer" ]; then
  MGR_CAPTURE=$(tmux capture-pane -t "$MGR_PANE_REF" -p -S -3 2>/dev/null) || MGR_CAPTURE=""
  case "$MGR_CAPTURE" in
    *"Select login method"*)
      PANE_STATE_0="LOGGED_OUT"
      echo "MANAGER_LOGGED_OUT"
      echo "LOGIN_MENU_STUCK:0"
      _log_error_wd "ANOMALY" "Manager has stuck login menu in window $TARGET_WINDOW"
      ;;
    *"Not logged in"*)
      PANE_STATE_0="LOGGED_OUT"
      echo "MANAGER_LOGGED_OUT"
      _log_error_wd "ANOMALY" "Manager logged out in window $TARGET_WINDOW"
      ;;
    *'❯'*|*'> '*) PANE_STATE_0="IDLE" ;;
    *) PANE_STATE_0="WORKING" ;;
  esac

  MGR_PREV_FILE="${RUNTIME_DIR}/status/manager_prev_state_W${TARGET_WINDOW}"
  read -r MGR_PREV_STATE < "$MGR_PREV_FILE" 2>/dev/null || MGR_PREV_STATE="UNKNOWN"
  _atomic_write "$MGR_PREV_FILE" "$PANE_STATE_0"
  if [ "$MGR_PREV_STATE" = "WORKING" ] && [ "$PANE_STATE_0" = "IDLE" ]; then
    echo "MANAGER_COMPLETED"
    _log "watchdog-scan: manager completed W${TARGET_WINDOW}"
  fi

  # --- Manager hook-reported status (more authoritative than screen-scrape) ---
  _mgr_pane_idx="${mgr_idx:-0}"
  _read_hook_status "${RUNTIME_DIR}/status/${SESSION_SAFE}_${TARGET_WINDOW}_${_mgr_pane_idx}.status"
  _mgr_hook_status="$_hook_status"

  # Reconcile hook state vs screen-scrape state
  if [ -n "$_mgr_hook_status" ]; then
    case "$_mgr_hook_status" in
      BUSY)
        # Hook says BUSY — trust it even if screen-scrape shows IDLE (between tool calls)
        if [ "$PANE_STATE_0" = "IDLE" ]; then
          PANE_STATE_0="WORKING"
          _log "watchdog-scan: manager hook=BUSY overrides scrape=IDLE"
        fi
        ;;
      READY|FINISHED)
        # Hook says READY but screen shows no prompt — manager may be stuck
        if [ "$PANE_STATE_0" = "WORKING" ]; then
          echo "MANAGER_POSSIBLY_STUCK (hook=${_mgr_hook_status} scrape=WORKING)"
          SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}MANAGER_POSSIBLY_STUCK hook=${_mgr_hook_status} scrape=WORKING${NL}"
          _log "watchdog-scan: manager possibly stuck — hook=${_mgr_hook_status} but scrape=WORKING"
        fi
        ;;
    esac
  fi

  # --- Manager activity events (written by hooks, consumed here) ---
  MGR_ACTIVITY_FILE="${RUNTIME_DIR}/status/manager_activity_W${TARGET_WINDOW}"
  _mgr_activity_event=""
  _mgr_activity_task=""
  if [ -f "$MGR_ACTIVITY_FILE" ]; then
    while IFS='=' read -r _ma_key _ma_val; do
      _ma_val="${_ma_val%\"}" && _ma_val="${_ma_val#\"}"
      case "$_ma_key" in
        EVENT) _mgr_activity_event="$_ma_val" ;;
        TASK) _mgr_activity_task="$_ma_val" ;;
      esac
    done < "$MGR_ACTIVITY_FILE"
    # Consume the event file
    rm -f "$MGR_ACTIVITY_FILE"
    if [ -n "$_mgr_activity_event" ]; then
      echo "MANAGER_ACTIVITY ${_mgr_activity_event} ${_mgr_activity_task}"
      SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}MANAGER_ACTIVITY ${_mgr_activity_event} ${_mgr_activity_task}${NL}"
      _log "watchdog-scan: manager activity=${_mgr_activity_event} task=${_mgr_activity_task}"
    fi
  fi
fi

# --- Session Manager health check (window-0 watchdog only) ---
if [ "$TARGET_WINDOW" = "0" ]; then
  _sm_pane_ref="${SESSION_NAME}:0.1"
  _sm_cmd=$(tmux display-message -t "$_sm_pane_ref" -p '#{pane_current_command}' 2>/dev/null) || _sm_cmd=""
  # Only check if SM pane exists and has a running Claude process
  if [ -n "$_sm_cmd" ]; then
    _sm_capture=$(tmux capture-pane -t "$_sm_pane_ref" -p -S -3 2>/dev/null) || _sm_capture=""
    _sm_is_idle="false"
    # Check for bare prompt with no activity (Claude has stopped)
    case "$_sm_cmd" in
      bash|zsh|sh|fish)
        # SM process has exited to a bare shell — definitely idle/crashed
        _sm_is_idle="true"
        ;;
      *)
        # Check if the SM pane shows only a bare prompt (❯) indicating it stopped
        case "$_sm_capture" in
          *'❯'*)
            # Verify it's not actively working — bare prompt means idle
            _sm_hook_file="${RUNTIME_DIR}/status/${SESSION_SAFE}_0_1.status"
            _read_hook_status "$_sm_hook_file"
            case "$_hook_status" in
              BUSY) ;;  # Hook says busy, trust it
              *) _sm_is_idle="true" ;;
            esac
            ;;
        esac
        ;;
    esac

    if [ "$_sm_is_idle" = "true" ]; then
      _sm_retry_dir="${RUNTIME_DIR}/watchdog"
      mkdir -p "$_sm_retry_dir" 2>/dev/null || true
      _sm_retry_file="${_sm_retry_dir}/sm_retrigger_count"
      _sm_retry_count=0
      [ -f "$_sm_retry_file" ] && read -r _sm_retry_count < "$_sm_retry_file" 2>/dev/null
      is_numeric "$_sm_retry_count" || _sm_retry_count=0

      if [ "$_sm_retry_count" -lt 3 ]; then
        # Wake SM via trigger file — session-manager-wait.sh watches for this.
        # Avoids send-keys which causes SM BUSY→IDLE cycle that resets the counter.
        _sm_trigger_dir="${RUNTIME_DIR}/triggers"
        mkdir -p "$_sm_trigger_dir" 2>/dev/null || true
        _sm_pane_safe="${SESSION_SAFE}_0_1"
        touch "${_sm_trigger_dir}/${_sm_pane_safe}.trigger"
        _sm_retry_count=$((_sm_retry_count + 1))
        _atomic_write "$_sm_retry_file" "$_sm_retry_count"
        _log "watchdog-scan: SM idle — trigger file written (attempt ${_sm_retry_count}/3)"
        echo "SM_RETRIGGER (attempt ${_sm_retry_count}/3)"
        SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}LIFECYCLE 0.1 SM_RETRIGGER $(date +%s) attempt=${_sm_retry_count}/3${NL}"
        # Write lifecycle event file for consumption
        _sm_lf_dir="${RUNTIME_DIR}/lifecycle"
        mkdir -p "$_sm_lf_dir" 2>/dev/null || true
        _sm_lf="${_sm_lf_dir}/W0_0.1_$(date +%s).evt"
        echo "0.1|SM_RETRIGGER|$(date +%s)|attempt=${_sm_retry_count}/3" > "${_sm_lf}.tmp" && mv "${_sm_lf}.tmp" "$_sm_lf"
      else
        echo "SM_STUCK (3 retrigger attempts exhausted)"
        _log_error_wd "ANOMALY" "Session Manager stuck after 3 retrigger attempts" "pane=0.1"
        SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}LIFECYCLE 0.1 SM_STUCK $(date +%s) retriggers_exhausted${NL}"
      fi
    fi
  fi
fi

# --- Scan worker panes ---
PANES_LIST="${WORKER_PANES//,/ }"
for i in $PANES_LIST; do
  is_numeric "$i" || continue
  PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.${i}"
  PANE_SAFE="${SESSION_SAFE}_${TARGET_WINDOW}_${i}"

  # Reserved
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    _report_pane "$i" "RESERVED"
    printf -v "PANE_DURATION_${i}" '%s' "0"
    continue
  fi

  # Exit copy-mode if active
  PANE_MODE=$(tmux display-message -t "$PANE_REF" -p '#{pane_mode}' 2>/dev/null) || PANE_MODE=""
  [ "$PANE_MODE" = "copy-mode" ] && { tmux copy-mode -q -t "$PANE_REF" 2>/dev/null || true; }

  # Single capture per pane per cycle — reused for all checks below
  PANE_CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null) || PANE_CAPTURE=""

  # Crash detection
  CURRENT_CMD=$(tmux display-message -t "$PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || CURRENT_CMD=""
  case "$CURRENT_CMD" in
    bash|zsh|sh|fish)
      _read_hook_status "${RUNTIME_DIR}/status/${PANE_SAFE}.status"
      case "$_hook_status" in
        FINISHED) _crash_state="FINISHED" ;;
        RESERVED) _crash_state="RESERVED" ;;
        *)
          _crash_state="CRASHED"
          _log_error_wd "ANOMALY" "Worker $i crashed" "window=$TARGET_WINDOW"
          CRASH_FILE="${RUNTIME_DIR}/status/crash_pane_${TARGET_WINDOW}_${i}"
          if [ ! -f "$CRASH_FILE" ]; then
            CRASH_CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -10 2>/dev/null) || CRASH_CAPTURE=""
            _atomic_write "$CRASH_FILE" "PANE_INDEX=${i}
TIMESTAMP=$(date +%s)
LAST_OUTPUT=$(echo "$CRASH_CAPTURE" | tail -5 | tr '\n' '|')"
          fi
          ;;
      esac
      _report_pane "$i" "$_crash_state"
      continue
      ;;
  esac

  # Booting detection — Claude process running but not yet ready
  case "$PANE_CAPTURE" in
    *'❯'*|*'bypass permissions'*) ;;  # Ready — proceed to normal scan
    *)
      case "$CURRENT_CMD" in
        node) _report_pane "$i" "BOOTING" "" "BOOTING ${i}"; continue ;;
      esac
      ;;
  esac

  # Logged-out detection — must run BEFORE anomaly detection to prevent
  # "Esc to cancel" in login menus from being treated as PROMPT_STUCK
  case "$PANE_CAPTURE" in
    *"Select login method"*)
      _report_pane "$i" "LOGGED_OUT"
      echo "LOGIN_MENU_STUCK:$i"
      _log_error_wd "ANOMALY" "Worker $i has stuck login menu" "window=$TARGET_WINDOW"
      continue ;;
    *"Not logged in"*)
      _report_pane "$i" "LOGGED_OUT"
      _log_error_wd "ANOMALY" "Worker $i logged out" "window=$TARGET_WINDOW"
      continue ;;
  esac

  # Anomaly detection — permission prompts, wrong mode, queued messages
  _anomaly_type=""
  case "$PANE_CAPTURE" in
    *"Esc to cancel"*|*"Tab to amend"*)
      _anomaly_type="PROMPT_STUCK"
      # Auto-Enter with per-pane cooldown to prevent escalation loops.
      # Max 3 attempts per 300s window, then escalate to Manager.
      _ae_dir="${RUNTIME_DIR}/watchdog"
      mkdir -p "$_ae_dir" 2>/dev/null || true
      _ae_ts_file="${_ae_dir}/auto_enter_${TARGET_WINDOW}_${i}.ts"
      _ae_count_file="${_ae_dir}/auto_enter_${TARGET_WINDOW}_${i}.count"
      _ae_last=0; _ae_count=0
      [ -f "$_ae_ts_file" ] && read -r _ae_last < "$_ae_ts_file" 2>/dev/null
      [ -f "$_ae_count_file" ] && read -r _ae_count < "$_ae_count_file" 2>/dev/null
      _ae_elapsed=$(( SCAN_TIME - _ae_last ))
      # Reset counter if cooldown window (300s) expired
      if [ "$_ae_elapsed" -gt 300 ]; then
        _ae_count=0
      fi
      if [ "$_ae_count" -lt 3 ]; then
        # Validate Claude is actually running (not a bare shell)
        _ae_cmd=$(tmux display-message -t "$PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || _ae_cmd=""
        case "$_ae_cmd" in node)
          tmux copy-mode -q -t "$PANE_REF" 2>/dev/null
          tmux send-keys -t "$PANE_REF" Enter 2>/dev/null
          _ae_count=$((_ae_count + 1))
          _atomic_write "$_ae_ts_file" "$SCAN_TIME"
          _atomic_write "$_ae_count_file" "$_ae_count"
          _log_error_wd "ANOMALY" "Auto-sent Enter to stuck worker $i (attempt $_ae_count/3)" "window=$TARGET_WINDOW remediation=auto_enter"
          ;;
        *)
          _log_error_wd "ANOMALY" "Worker $i PROMPT_STUCK but process is $_ae_cmd, not node — skipping auto-Enter" "window=$TARGET_WINDOW"
          ;;
        esac
      else
        # Cooldown active — escalate to Manager instead of retrying
        _ae_suppress_file="${_ae_dir}/suppress_stuck_${TARGET_WINDOW}_${i}"
        if [ ! -f "$_ae_suppress_file" ]; then
          _atomic_write "$_ae_suppress_file" "$SCAN_TIME"
          _log_error_wd "ANOMALY" "Worker $i PROMPT_STUCK — cooldown hit (3 attempts in 300s), escalating to Manager" "window=$TARGET_WINDOW"
          # Escalate via message file to Manager
          _ae_msg_dir="${RUNTIME_DIR}/messages"
          mkdir -p "$_ae_msg_dir" 2>/dev/null || true
          _ae_mgr_safe="${SESSION_SAFE}_${TARGET_WINDOW}_0"
          _ae_msg_file="${_ae_msg_dir}/${_ae_mgr_safe}_$(date +%s)_$$.msg"
          printf 'FROM: watchdog\nSUBJECT: prompt_stuck_escalation\nWorker pane %s.%s is stuck at a prompt. Auto-Enter failed after 3 attempts. Manual intervention needed — check the pane and resolve the stuck prompt.\n' \
            "$TARGET_WINDOW" "$i" > "${_ae_msg_file}.tmp" 2>/dev/null && mv "${_ae_msg_file}.tmp" "$_ae_msg_file" 2>/dev/null
        fi
      fi
      ;;
    *"accept edits on"*)
      _anomaly_type="WRONG_MODE"
      ;;
    *"queued messages"*|*"Press up to edit"*)
      _anomaly_type="QUEUED_INPUT"
      ;;
  esac
  # Clear suppression when state changes away from PROMPT_STUCK
  if [ "$_anomaly_type" != "PROMPT_STUCK" ]; then
    rm -f "${RUNTIME_DIR}/watchdog/suppress_stuck_${TARGET_WINDOW}_${i}" 2>/dev/null
    rm -f "${RUNTIME_DIR}/watchdog/auto_enter_${TARGET_WINDOW}_${i}.count" 2>/dev/null
  fi
  if [ -n "$_anomaly_type" ]; then
    # Suppress repeated PROMPT_STUCK logging after escalation
    _ae_do_log="true"
    if [ "$_anomaly_type" = "PROMPT_STUCK" ] && [ -f "${RUNTIME_DIR}/watchdog/suppress_stuck_${TARGET_WINDOW}_${i}" ]; then
      _ae_do_log="false"
    fi
    echo "PANE ${i} ${_anomaly_type}"
    SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}ANOMALY ${i} ${_anomaly_type}${NL}"
    [ "$_ae_do_log" = "true" ] && _log_error_wd "ANOMALY" "Worker $i ${_anomaly_type}" "window=$TARGET_WINDOW"
  fi

  # CPU time detection
  _pane_ppid=$(tmux display-message -t "$PANE_REF" -p '#{pane_pid}' 2>/dev/null) || _pane_ppid=""
  _cpu_secs=0
  if [ -n "$_pane_ppid" ]; then
    _node_pid=$(pgrep -P "$_pane_ppid" 2>/dev/null | head -1) || _node_pid=""
    if [ -n "$_node_pid" ]; then
      _cputime_raw=$(ps -o cputime= -p "$_node_pid" 2>/dev/null | tr -d ' ') || _cputime_raw=""
      [ -n "$_cputime_raw" ] && _cpu_secs=$(_parse_cpu_seconds "$_cputime_raw")
    fi
  fi
  CPU_FILE="${RUNTIME_DIR}/status/cpu_${TARGET_WINDOW}_${i}"
  _prev_cpu_secs=-1
  [ -f "$CPU_FILE" ] && read -r _prev_cpu_secs < "$CPU_FILE" 2>/dev/null
  _atomic_write "$CPU_FILE" "$_cpu_secs"
  if [ "$_prev_cpu_secs" -lt 0 ]; then
    _cpu_delta=-1
  else
    _cpu_delta=$((_cpu_secs - _prev_cpu_secs))
    [ "$_cpu_delta" -lt 0 ] && _cpu_delta=0
  fi
  _cpu_active=""
  [ "$_cpu_delta" -gt 1 ] && _cpu_active="yes"

  # Hook-written status
  _read_hook_status "${RUNTIME_DIR}/status/${PANE_SAFE}.status"

  HASH=$(hash_fn "$PANE_CAPTURE")
  HASH_FILE="${RUNTIME_DIR}/status/pane_hash_${PANE_SAFE}"
  read -r OLD_HASH < "$HASH_FILE" 2>/dev/null || OLD_HASH=""

  if [ "$HASH" = "$OLD_HASH" ]; then
    # Content unchanged — use CPU to distinguish IDLE vs WORKING
    eval "PREV=\${PREV_STATE_${i}:-UNKNOWN}"

    if [ -n "$_cpu_active" ] || [ "$_hook_status" = "BUSY" ]; then
      COUNTER_FILE="${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}"
      read -r OLD_COUNT < "$COUNTER_FILE" 2>/dev/null || OLD_COUNT=0
      NEW_COUNT=$((OLD_COUNT + 1))
      _atomic_write "$COUNTER_FILE" "$NEW_COUNT"

      if [ "$NEW_COUNT" -ge 6 ]; then
        echo "PANE ${i} STUCK (CPU active but no output for ${NEW_COUNT} cycles)"
        _pane_log "${TARGET_WINDOW}.${i}" "pane ${i} state=STUCK unchanged_cycles=${NEW_COUNT}"
        _log_error_wd "ANOMALY" "Worker $i stuck for ${NEW_COUNT} cycles" "window=$TARGET_WINDOW cpu_active=true"
        _unch_state="STUCK"
      else
        _unch_state="WORKING"
        case "$PREV" in
          WORKING|CHANGED|UNCHANGED) ;;
          *) echo "PANE ${i} WORKING"
             _pane_log "${TARGET_WINDOW}.${i}" "pane ${i} state=WORKING (unchanged hash, CPU active)" ;;
        esac
      fi
      _update_duration "$i" "WORKING" "WORKING"
      _set_pane_info "$i" "$_unch_state" "$(_get_pane_title "$PANE_REF")" "" "WORKING"
    else
      # No CPU activity + hash unchanged = truly IDLE
      rm -f "${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}" 2>/dev/null
      _display_prev=$(_display_state "$PREV")
      case "$PREV" in IDLE|UNCHANGED) ;; *)
        echo "PANE ${i} IDLE"
        _pane_log "${TARGET_WINDOW}.${i}" "pane ${i} state=IDLE"
        ;; esac
      _update_duration "$i" "$_display_prev" "IDLE"
      _set_pane_info "$i" "IDLE" "$(_get_pane_title "$PANE_REF")" "" "$_display_prev"
    fi
    continue
  fi

  # Hash changed — content actively updating
  rm -f "${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}" 2>/dev/null
  _atomic_write "$HASH_FILE" "$HASH"

  # Extract last tool name from capture
  _last_tool=""
  _scan_line=""
  while IFS= read -r _scan_line; do
    case "$_scan_line" in
      *Agent*) _last_tool="Agent" ;; *Bash*) _last_tool="Bash" ;;
      *Read*) _last_tool="Read" ;; *Edit*) _last_tool="Edit" ;;
      *Write*) _last_tool="Write" ;; *Grep*) _last_tool="Grep" ;;
      *Glob*) _last_tool="Glob" ;;
    esac
  done <<EOF
$PANE_CAPTURE
EOF

  _report_pane "$i" "WORKING" "$_last_tool"
done

# --- Status summary ---
if [ -n "$MGR_CMD" ]; then
  case "$MGR_CMD" in
    bash|zsh|sh|fish) _mgr_label="CRASHED" ;;
    *) _mgr_label="$PANE_STATE_0" ;;
  esac
  MGR_TITLE=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_title}' 2>/dev/null) || MGR_TITLE=""
else
  _mgr_label="$PANE_STATE_0"
fi

_n_working=0 _n_idle=0 _n_stuck=0 _n_crashed=0 _n_reserved=0 _n_logged_out=0 _n_booting=0 _n_other=0
_active_titles=""
_longest_pane="" _longest_dur=0
for i in $PANES_LIST; do
  is_numeric "$i" || continue
  eval "_st=\${PANE_STATE_${i}:-UNKNOWN}"
  eval "_dur=\${PANE_DURATION_${i}:-0}"
  case "$_st" in
    WORKING|CHANGED|UNCHANGED) _n_working=$((_n_working + 1))
      eval "_pt=\${PANE_TITLE_${i}:-}"
      [ -n "$_pt" ] && _active_titles="${_active_titles:+${_active_titles}, }${i}:${_pt}"
      if [ "$_dur" -gt "$_longest_dur" ]; then
        _longest_dur="$_dur"; _longest_pane="$i"
      fi
      ;;
    IDLE|FINISHED) _n_idle=$((_n_idle + 1)) ;;
    STUCK) _n_stuck=$((_n_stuck + 1)) ;;
    CRASHED) _n_crashed=$((_n_crashed + 1)) ;;
    RESERVED) _n_reserved=$((_n_reserved + 1)) ;;
    LOGGED_OUT) _n_logged_out=$((_n_logged_out + 1)) ;;
    BOOTING) _n_booting=$((_n_booting + 1)) ;;
    *) _n_other=$((_n_other + 1)) ;;
  esac
done

_longest_label=""
if [ -n "$_longest_pane" ] && [ "$_longest_dur" -gt 0 ]; then
  _longest_label="${_longest_pane}@$(_format_duration "$_longest_dur")"
fi

# Wave completion: HAS_WORKING -> ALL_IDLE transition
_all_available=$((_n_working + _n_idle + _n_stuck + _n_crashed))
WAVE_STATE_FILE="${RUNTIME_DIR}/status/wave_state_W${TARGET_WINDOW}"
read -r _prev_wave_state < "$WAVE_STATE_FILE" 2>/dev/null || _prev_wave_state="UNKNOWN"
if [ "$_n_working" -eq 0 ] && [ "$_n_stuck" -eq 0 ] && [ "$_n_crashed" -eq 0 ] && [ "$_n_booting" -eq 0 ] && [ "$_all_available" -gt 0 ]; then
  _cur_wave_state="ALL_IDLE"
else
  _cur_wave_state="HAS_WORKING"
fi
_atomic_write "$WAVE_STATE_FILE" "$_cur_wave_state"
if [ "$_prev_wave_state" = "HAS_WORKING" ] && [ "$_cur_wave_state" = "ALL_IDLE" ]; then
  echo "WAVE_COMPLETE"
  SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}WAVE_COMPLETE all_workers_idle${NL}"
fi

printf 'STATUS W%s | Mgr:%s | %dW %dI' "$TARGET_WINDOW" "$_mgr_label" "$_n_working" "$_n_idle"
[ "$_n_stuck" -gt 0 ] && printf ' %dS' "$_n_stuck"
[ "$_n_crashed" -gt 0 ] && printf ' %dC' "$_n_crashed"
[ "$_n_logged_out" -gt 0 ] && printf ' %dL' "$_n_logged_out"
[ "$_n_booting" -gt 0 ] && printf ' %dB' "$_n_booting"
[ -n "$_active_titles" ] && printf ' | %s' "$_active_titles"
[ -n "$_longest_label" ] && printf ' | longest:%s' "$_longest_label"
printf '\n'

# --- Completion events ---
for cf in "${RUNTIME_DIR}/status"/completion_pane_${TARGET_WINDOW}_*; do
  [ -f "$cf" ] || continue
  _ce_pane_idx="" _ce_title="" _ce_status="" _ce_ts=""
  while IFS='=' read -r _cf_key _cf_val; do
    _cf_val="${_cf_val%\"}" && _cf_val="${_cf_val#\"}"
    case "$_cf_key" in
      PANE_INDEX) _ce_pane_idx="$_cf_val" ;;
      PANE_TITLE) _ce_title="$_cf_val" ;;
      STATUS) _ce_status="$_cf_val" ;;
      TIMESTAMP) _ce_ts="$_cf_val" ;;
    esac
  done < "$cf"
  echo "COMPLETION ${_ce_pane_idx} ${_ce_status} ${_ce_title}"
  SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}COMPLETION ${_ce_pane_idx} ${_ce_status} ${_ce_title}${NL}"
  rm -f "$cf"
done

# --- Lifecycle events (pushed by hooks via notify_watchdog) ---
# Events are named W<team>_<pane_id>_<timestamp>.evt
for _lf in "${RUNTIME_DIR}/lifecycle"/W${TARGET_WINDOW}_*.evt; do
  [ -f "$_lf" ] || continue
  # Format: pane_id|status|time|detail
  _lf_line=$(head -1 "$_lf" 2>/dev/null) || _lf_line=""
  if [ -n "$_lf_line" ]; then
    _lf_pane="${_lf_line%%|*}" _lf_rest="${_lf_line#*|}"
    _lf_status="${_lf_rest%%|*}" _lf_rest2="${_lf_rest#*|}"
    _lf_time="${_lf_rest2%%|*}" _lf_detail="${_lf_rest2#*|}"
    echo "LIFECYCLE ${_lf_pane} ${_lf_status} ${_lf_time} ${_lf_detail}"
    SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}LIFECYCLE ${_lf_pane} ${_lf_status} ${_lf_time} ${_lf_detail}${NL}"
  fi
  rm -f "$_lf"
done

# --- Write team snapshot ---
SNAPSHOT_FILE="${RUNTIME_DIR}/status/team_snapshot_W${TARGET_WINDOW}.txt"
{
  printf 'SNAPSHOT_TIME=%s\n' "$SCAN_TIME"
  printf 'MANAGER=%s\n' "$_mgr_label"
  printf 'MANAGER_TITLE=%s\n' "$MGR_TITLE"
  printf 'TOTAL_WORKERS=%s\n' "$((_n_working + _n_idle + _n_stuck + _n_crashed + _n_reserved + _n_logged_out + _n_booting + _n_other))"
  printf 'WORKING=%s\nIDLE=%s\nSTUCK=%s\nCRASHED=%s\nRESERVED=%s\nLOGGED_OUT=%s\nBOOTING=%s\n' \
    "$_n_working" "$_n_idle" "$_n_stuck" "$_n_crashed" "$_n_reserved" "$_n_logged_out" "$_n_booting"
  printf -- '---\n'
  printf 'PANE|STATE|TITLE|DURATION_SECS|LAST_TOOL|PREV_STATE\n'
  for i in $PANES_LIST; do
    is_numeric "$i" || continue
    eval "_sn_st=\${PANE_STATE_${i}:-UNKNOWN}"
    eval "_sn_title=\${PANE_TITLE_${i}:-}"
    eval "_sn_dur=\${PANE_DURATION_${i}:-0}"
    eval "_sn_tool=\${PANE_TOOL_${i}:-}"
    eval "_sn_prev=\${PANE_PREV_DISPLAY_${i}:-}"
    case "$_sn_st" in (CHANGED|UNCHANGED) _sn_st="WORKING" ;; esac
    printf '%s|%s|%s|%s|%s|%s\n' "$i" "$_sn_st" "$_sn_title" "$_sn_dur" "$_sn_tool" "$_sn_prev"
  done
  printf -- '---\n'
  printf 'EVENTS\n'
  printf '%s' "$SNAPSHOT_EVENTS"
} > "${SNAPSHOT_FILE}.tmp" && mv "${SNAPSHOT_FILE}.tmp" "$SNAPSHOT_FILE"

# --- Heartbeat ---
_atomic_write "${RUNTIME_DIR}/status/watchdog_W${TARGET_WINDOW}.heartbeat" "$SCAN_TIME"

# --- Pane states JSON ---
JSON="{"
_sep=""
for i in $PANES_LIST; do
  is_numeric "$i" || continue
  eval "STATE=\${PANE_STATE_${i}:-UNKNOWN}"
  JSON+="${_sep}\"${i}\":\"${STATE}\""
  _sep=","
done
JSON+="}"
_atomic_write "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json" "$JSON"

# --- Anomaly processing: persist, expire, escalate ---
_process_anomalies() {
  # Write new anomaly events to files
  local lines pane type af snippet
  lines=$(printf '%s' "$SNAPSHOT_EVENTS" | grep '^ANOMALY ') || lines=""
  if [ -n "$lines" ]; then
    while IFS= read -r _aline; do
      [ -z "$_aline" ] && continue
      pane=$(echo "$_aline" | awk '{print $2}')
      type=$(echo "$_aline" | awk '{print $3}')
      af="${RUNTIME_DIR}/status/anomaly_${TARGET_WINDOW}_${pane}.event"
      snippet=$(tmux capture-pane -t "${SESSION_NAME}:${TARGET_WINDOW}.${pane}" -p -S -3 2>/dev/null | tail -3 | tr '\n' '|')
      printf 'TYPE=%s\nPANE=%s\nWINDOW=%s\nTIMESTAMP=%s\nSNIPPET=%s\n' \
        "$type" "$pane" "$TARGET_WINDOW" "$SCAN_TIME" "$snippet" > "${af}.tmp" && mv "${af}.tmp" "$af"
    done <<ANOMALY_EOF
$lines
ANOMALY_EOF
  fi

  # Expire events >5 min old; escalate persistent ones
  local ts count_file prev_count new_count ep et
  for af in "${RUNTIME_DIR}/status"/anomaly_${TARGET_WINDOW}_*.event; do
    [ -f "$af" ] || continue
    ts=$(grep '^TIMESTAMP=' "$af" 2>/dev/null | cut -d= -f2)
    is_numeric "${ts:-x}" || ts=0
    if [ "$(($SCAN_TIME - ts))" -gt 300 ]; then rm -f "$af"; continue; fi
    ep=$(grep '^PANE=' "$af" 2>/dev/null | cut -d= -f2)
    et=$(grep '^TYPE=' "$af" 2>/dev/null | cut -d= -f2)
    count_file="${RUNTIME_DIR}/status/anomaly_count_${TARGET_WINDOW}_${ep}"
    prev_count=0
    [ -f "$count_file" ] && read -r prev_count < "$count_file" 2>/dev/null
    is_numeric "$prev_count" || prev_count=0
    new_count=$((prev_count + 1))
    _atomic_write "$count_file" "$new_count"
    if [ "$new_count" -ge 3 ]; then
      echo "ESCALATE ANOMALY ${ep} ${et} (${new_count} consecutive)"
      _log_error_wd "ANOMALY" "Escalating anomaly for pane $ep" "type=${et:-unknown} count=${new_count:-?}"
    fi
  done

  # Clear counts for resolved anomalies
  for cf in "${RUNTIME_DIR}/status"/anomaly_count_${TARGET_WINDOW}_*; do
    [ -f "$cf" ] || continue
    pane="${cf##*_}"
    [ -f "${RUNTIME_DIR}/status/anomaly_${TARGET_WINDOW}_${pane}.event" ] || rm -f "$cf"
  done
}
_process_anomalies

# --- Inline snapshot for watchdog (suppress if unchanged) ---
_SNAP_HASH_FILE="${RUNTIME_DIR}/status/watchdog_last_snapshot_hash_W${TARGET_WINDOW}.txt"
_SNAP_NOCHANGE_FILE="${RUNTIME_DIR}/status/watchdog_nochange_counter_W${TARGET_WINDOW}.txt"
_SNAP_LASTCHANGE_FILE="${RUNTIME_DIR}/status/watchdog_lastchange_time_W${TARGET_WINDOW}.txt"
if [ -f "$SNAPSHOT_FILE" ]; then
  # Hash current snapshot
  if command -v md5 >/dev/null 2>&1; then
    _snap_hash=$(md5 -q "$SNAPSHOT_FILE")
  else
    _snap_hash=$(md5sum "$SNAPSHOT_FILE" | cut -d' ' -f1)
  fi
  _snap_prev_hash=""
  [ -f "$_SNAP_HASH_FILE" ] && read -r _snap_prev_hash < "$_SNAP_HASH_FILE" 2>/dev/null
  if [ "$_snap_hash" = "$_snap_prev_hash" ]; then
    # No change — increment counter, show compact line
    _nc_count=0
    [ -f "$_SNAP_NOCHANGE_FILE" ] && read -r _nc_count < "$_SNAP_NOCHANGE_FILE" 2>/dev/null
    _nc_count=$((_nc_count + 1))
    _atomic_write "$_SNAP_NOCHANGE_FILE" "$_nc_count"
    _lc_time="$SCAN_TIME"
    [ -f "$_SNAP_LASTCHANGE_FILE" ] && read -r _lc_time < "$_SNAP_LASTCHANGE_FILE" 2>/dev/null
    _nc_elapsed=$((SCAN_TIME - _lc_time))
    echo "NO_CHANGE cycle=${_nc_count} elapsed=${_nc_elapsed}s SCAN_TIME=${SCAN_TIME}"
  else
    # Changed — reset counter, echo full snapshot
    _atomic_write "$_SNAP_HASH_FILE" "$_snap_hash"
    _atomic_write "$_SNAP_NOCHANGE_FILE" "0"
    _atomic_write "$_SNAP_LASTCHANGE_FILE" "$SCAN_TIME"
    echo "--- SNAPSHOT ---"
    cat "$SNAPSHOT_FILE"
    echo "--- END SNAPSHOT ---"
  fi
fi

# --- Context pressure check ---
_ctx_line=$(tmux capture-pane -t "${TMUX_PANE}" -p -S -5 2>/dev/null | grep 'Ctx ' | tail -1) || _ctx_line=""
_ctx_pct=$(echo "$_ctx_line" | sed 's/.*Ctx [^ ]* //;s/%.*//')
_ctx_pct="${_ctx_pct// /}"
is_numeric "$_ctx_pct" || _ctx_pct="0"
if [ "$_ctx_pct" -ge 60 ]; then
  echo ""
  echo "⚠️  COMPACT_NOW — context at ${_ctx_pct}% (threshold: 60%)"
  echo "You MUST run /compact immediately. Do NOT run another scan cycle first."
  _log_error_wd "ANOMALY" "Context pressure - compact needed" "context_pct=${_ctx_pct}%"
fi

# Debug: write scan cycle summary (reuses $JSON from pane states block above)
if [ "$_WDG_DBG" = "true" ]; then
  _wdg_end=$(date +%s)
  _wdg_dur=$((_wdg_end - SCAN_TIME))
  # Reuse pane states from $JSON — strip outer braces to get the inner fragment
  _wdg_pstates="${JSON#\{}"
  _wdg_pstates="${_wdg_pstates%\}}"
  # Build anomaly list
  _wdg_anomalies=""
  _wdg_alines=$(printf '%s' "$SNAPSHOT_EVENTS" | grep '^ANOMALY ' 2>/dev/null) || _wdg_alines=""
  if [ -n "$_wdg_alines" ]; then
    _wdg_anomalies=$(printf '%s' "$_wdg_alines" | tr '\n' ',' | sed 's/,$//')
  fi
  _wdg_wave=""
  case "$SNAPSHOT_EVENTS" in *WAVE_COMPLETE*) _wdg_wave=',"wave_complete":true' ;; esac
  [ -d "$(dirname "$_WDG_DBG_FILE")" ] || mkdir -p "$(dirname "$_WDG_DBG_FILE")" 2>/dev/null
  printf '{"ts":%s,"window":%s,"cycle":%s,"dur_s":%s,"mgr":"%s","working":%s,"idle":%s,"stuck":%s,"crashed":%s,"panes":{%s},"anomalies":"%s"%s}\n' \
    "$SCAN_TIME" "$TARGET_WINDOW" "$_WDG_CYCLE" "$_wdg_dur" "$_mgr_label" \
    "$_n_working" "$_n_idle" "$_n_stuck" "$_n_crashed" \
    "$_wdg_pstates" "$_wdg_anomalies" "$_wdg_wave" \
    >> "$_WDG_DBG_FILE" 2>/dev/null
fi

_log "watchdog-scan: end cycle W${TARGET_WINDOW} working=${_n_working} idle=${_n_idle} stuck=${_n_stuck} crashed=${_n_crashed}"

echo "SCAN_TIME=${SCAN_TIME}"
