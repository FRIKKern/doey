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

# Set per-pane tracking vars: state, title, tool, prev_display
_set_pane_info() {
  local idx="$1" state="$2" title="$3" tool="$4" prev="$5"
  eval "PANE_STATE_${idx}='${state}'"
  eval "PANE_TITLE_${idx}='${title}'"
  eval "PANE_TOOL_${idx}='${tool}'"
  eval "PANE_PREV_DISPLAY_${idx}='${prev}'"
}

# Track state duration; record transitions as snapshot events
_update_duration() {
  local idx="$1" prev="$2" cur="$3"
  local since_file="${RUNTIME_DIR}/status/state_since_${TARGET_WINDOW}_${idx}"
  if [ "$prev" != "$cur" ]; then
    echo "$SCAN_TIME" > "$since_file"
    eval "PANE_DURATION_${idx}=0"
    SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}STATE_CHANGE ${idx} ${prev}->${cur}${NL}"
  else
    local since
    read -r since < "$since_file" 2>/dev/null || { echo "$SCAN_TIME" > "$since_file"; since="$SCAN_TIME"; }
    eval "PANE_DURATION_${idx}=$(($SCAN_TIME - $since))"
  fi
}

# Atomic file write via tmp+mv
_atomic_write() { echo "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

# Format seconds as compact duration (e.g. 2h5m30s, 5m30s, 30s)
_format_duration() {
  local h=$(($1 / 3600)) m=$((($1 % 3600) / 60)) s=$(($1 % 60))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m${s}s"
  elif [ "$m" -gt 0 ]; then echo "${m}m${s}s"
  else echo "${s}s"
  fi
}

# Map raw/internal states to display states
_display_state() {
  case "$1" in
    WORKING|CHANGED|UNCHANGED|STUCK) echo "WORKING" ;;
    IDLE|FINISHED) echo "IDLE" ;;
    *) echo "$1" ;;
  esac
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

# Load previous pane states for stuck detection
PREV_STATES_FILE="${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json"
if [ -f "$PREV_STATES_FILE" ]; then
  PREV_JSON=$(cat "$PREV_STATES_FILE" 2>/dev/null) || PREV_JSON="{}"
  PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
  while IFS=: read -r pidx pstate; do
    pidx="${pidx// /}" pstate="${pstate// /}"
    is_numeric "$pidx" || continue
    case "$pstate" in
      IDLE|WORKING|CHANGED|UNCHANGED|CRASHED|STUCK|FINISHED|RESERVED|UNKNOWN) ;;
      *) continue ;;
    esac
    eval "PREV_STATE_${pidx}=\"${pstate}\""
  done <<EOF
$PREV_PAIRS
EOF
fi

SESSION_SAFE="${SESSION_NAME//[:.]/_}"
SCAN_HAD_OUTPUT=false
SCAN_TIME=$(date +%s)
SNAPSHOT_EVENTS=""

# --- Manager health check ---
MGR_PANE_REF=""
if [ -f "$TEAM_ENV" ]; then
  mgr_idx=$(grep '^MANAGER_PANE=' "$TEAM_ENV" | cut -d= -f2-)
  mgr_idx="${mgr_idx%\"}" && mgr_idx="${mgr_idx#\"}"
  [ -n "$mgr_idx" ] && MGR_PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.${mgr_idx}"
fi
[ -z "$MGR_PANE_REF" ] && MGR_PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.0"

MGR_CMD=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
case "$MGR_CMD" in
  bash|zsh|sh|fish)
    echo "MANAGER_CRASHED"; SCAN_HAD_OUTPUT=true
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

# Manager idle detection + completion transition
MGR_CAPTURE=$(tmux capture-pane -t "$MGR_PANE_REF" -p -S -3 2>/dev/null) || MGR_CAPTURE=""
case "$MGR_CAPTURE" in
  *'❯'*|*'> '*) PANE_STATE_0="IDLE" ;;
  *) PANE_STATE_0="WORKING" ;;
esac

MGR_PREV_FILE="${RUNTIME_DIR}/status/manager_prev_state_W${TARGET_WINDOW}"
read -r MGR_PREV_STATE < "$MGR_PREV_FILE" 2>/dev/null || MGR_PREV_STATE="UNKNOWN"
echo "$PANE_STATE_0" > "$MGR_PREV_FILE"
if [ "$MGR_PREV_STATE" = "WORKING" ] && [ "$PANE_STATE_0" = "IDLE" ]; then
  echo "MANAGER_COMPLETED"; SCAN_HAD_OUTPUT=true
fi

# --- Scan worker panes ---
PANES_LIST="${WORKER_PANES//,/ }"
for i in $PANES_LIST; do
  is_numeric "$i" || continue
  PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.${i}"
  PANE_SAFE="${SESSION_SAFE}_${TARGET_WINDOW}_${i}"

  # Reserved
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "PANE ${i} RESERVED"; SCAN_HAD_OUTPUT=true
    _set_pane_info "$i" "RESERVED" "" "" ""
    eval "PANE_DURATION_${i}=0"
    continue
  fi

  # Exit copy-mode if active
  PANE_MODE=$(tmux display-message -t "$PANE_REF" -p '#{pane_mode}' 2>/dev/null) || PANE_MODE=""
  if [ "$PANE_MODE" = "copy-mode" ]; then
    tmux copy-mode -q -t "$PANE_REF" 2>/dev/null || true
  fi

  # Crash detection (shell running without claude/node)
  CURRENT_CMD=$(tmux display-message -t "$PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || CURRENT_CMD=""
  case "$CURRENT_CMD" in
    bash|zsh|sh|fish)
      _hook_line=$(grep '^STATUS:' "${RUNTIME_DIR}/status/${PANE_SAFE}.status" 2>/dev/null | head -1) || _hook_line=""
      case "$_hook_line" in
        *FINISHED*) _crash_state="FINISHED" ;;
        *RESERVED*) _crash_state="RESERVED" ;;
        *)
          _crash_state="CRASHED"
          CRASH_FILE="${RUNTIME_DIR}/status/crash_pane_${TARGET_WINDOW}_${i}"
          if [ ! -f "$CRASH_FILE" ]; then
            CRASH_CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -10 2>/dev/null) || CRASH_CAPTURE=""
            cat > "$CRASH_FILE" << CRASH_EOF
PANE_INDEX=${i}
TIMESTAMP=$(date +%s)
LAST_OUTPUT=$(echo "$CRASH_CAPTURE" | tail -5 | tr '\n' '|')
CRASH_EOF
          fi
          ;;
      esac
      echo "PANE ${i} ${_crash_state}"; SCAN_HAD_OUTPUT=true
      eval "_prev=\${PREV_STATE_${i}:-UNKNOWN}"
      _update_duration "$i" "$_prev" "$_crash_state"
      _set_pane_info "$i" "$_crash_state" "$(_get_pane_title "$PANE_REF")" "" "$_prev"
      continue
      ;;
  esac

  # CPU time detection — active work consumes CPU; idle waiting does not
  _pane_ppid=$(tmux display-message -t "$PANE_REF" -p '#{pane_pid}' 2>/dev/null) || _pane_ppid=""
  _cpu_secs=0
  if [ -n "$_pane_ppid" ]; then
    _node_pid=$(pgrep -P "$_pane_ppid" 2>/dev/null | head -1)
    if [ -n "$_node_pid" ]; then
      _cputime_raw=$(ps -o cputime= -p "$_node_pid" 2>/dev/null | tr -d ' ')
      [ -n "$_cputime_raw" ] && _cpu_secs=$(_parse_cpu_seconds "$_cputime_raw")
    fi
  fi
  CPU_FILE="${RUNTIME_DIR}/status/cpu_${TARGET_WINDOW}_${i}"
  _prev_cpu_secs=-1
  [ -f "$CPU_FILE" ] && read -r _prev_cpu_secs < "$CPU_FILE" 2>/dev/null
  echo "$_cpu_secs" > "$CPU_FILE"
  if [ "$_prev_cpu_secs" -lt 0 ]; then
    _cpu_delta=-1
  else
    _cpu_delta=$((_cpu_secs - _prev_cpu_secs))
    [ "$_cpu_delta" -lt 0 ] && _cpu_delta=0
  fi
  _cpu_active=""
  [ "$_cpu_delta" -gt 1 ] && _cpu_active="yes"

  # Hook-written status (BUSY/FINISHED/READY from on-prompt-submit/stop-status)
  _hook_status=""
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  if [ -f "$STATUS_FILE" ]; then
    _hook_status=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
    _hook_status="${_hook_status#STATUS: }"
  fi

  CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null) || CAPTURE=""
  HASH=$(hash_fn "$CAPTURE")
  HASH_FILE="${RUNTIME_DIR}/status/pane_hash_${PANE_SAFE}"
  read -r OLD_HASH < "$HASH_FILE" 2>/dev/null || OLD_HASH=""

  if [ "$HASH" = "$OLD_HASH" ]; then
    # Content unchanged — use CPU time to distinguish IDLE vs WORKING
    eval "PREV=\${PREV_STATE_${i}:-UNKNOWN}"

    if [ -n "$_cpu_active" ] || [ "$_hook_status" = "BUSY" ]; then
      # CPU active or hook says BUSY
      COUNTER_FILE="${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}"
      read -r OLD_COUNT < "$COUNTER_FILE" 2>/dev/null || OLD_COUNT=0
      NEW_COUNT=$((OLD_COUNT + 1))
      echo "$NEW_COUNT" > "$COUNTER_FILE"

      if [ "$NEW_COUNT" -ge 6 ]; then
        echo "PANE ${i} STUCK (CPU active but no output for ${NEW_COUNT} cycles)"; SCAN_HAD_OUTPUT=true
        _unch_state="STUCK"
      else
        _unch_state="WORKING"
        case "$PREV" in
          WORKING|CHANGED|UNCHANGED) ;;
          *) echo "PANE ${i} WORKING"; SCAN_HAD_OUTPUT=true ;;
        esac
      fi
      _update_duration "$i" "WORKING" "WORKING"
      _set_pane_info "$i" "$_unch_state" "$(_get_pane_title "$PANE_REF")" "" "WORKING"
    else
      # No CPU activity + hash unchanged = truly IDLE
      rm -f "${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}" 2>/dev/null
      case "$PREV" in
        IDLE|UNCHANGED)
          _display_prev="IDLE" ;;
        FINISHED)
          echo "PANE ${i} IDLE"; SCAN_HAD_OUTPUT=true
          _display_prev="IDLE" ;;
        WORKING|CHANGED|STUCK)
          echo "PANE ${i} IDLE"; SCAN_HAD_OUTPUT=true
          _display_prev="WORKING" ;;
        *)
          echo "PANE ${i} IDLE"; SCAN_HAD_OUTPUT=true
          _display_prev="$PREV" ;;
      esac
      _update_duration "$i" "$_display_prev" "IDLE"
      _set_pane_info "$i" "IDLE" "$(_get_pane_title "$PANE_REF")" "" "$_display_prev"
    fi
    continue
  fi

  # Hash changed — content actively updating
  rm -f "${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}" 2>/dev/null
  _atomic_write "$HASH_FILE" "$HASH"

  echo "PANE ${i} WORKING"; SCAN_HAD_OUTPUT=true

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
$CAPTURE
EOF

  eval "_prev_raw=\${PREV_STATE_${i}:-UNKNOWN}"
  case "$_prev_raw" in
    WORKING|CHANGED|UNCHANGED|STUCK) _display_prev="WORKING" ;;
    IDLE|FINISHED) _display_prev="IDLE" ;;
    *) _display_prev="$_prev_raw" ;;
  esac
  _update_duration "$i" "$_display_prev" "WORKING"
  _set_pane_info "$i" "WORKING" "$(_get_pane_title "$PANE_REF")" "$_last_tool" "$_display_prev"
done

# --- Status summary ---
case "$MGR_CMD" in
  bash|zsh|sh|fish) _mgr_label="CRASHED" ;;
  *) _mgr_label="$PANE_STATE_0" ;;
esac
MGR_TITLE=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_title}' 2>/dev/null) || MGR_TITLE=""

_n_working=0 _n_idle=0 _n_stuck=0 _n_crashed=0 _n_reserved=0 _n_other=0
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
    *) _n_other=$((_n_other + 1)) ;;
  esac
done

_longest_label=""
if [ -n "$_longest_pane" ] && [ "$_longest_dur" -gt 0 ]; then
  _longest_label="${_longest_pane}@$(_format_duration "$_longest_dur")"
fi

# Wave completion: HAS_WORKING → ALL_IDLE transition
_all_available=$((_n_working + _n_idle + _n_stuck + _n_crashed))
WAVE_STATE_FILE="${RUNTIME_DIR}/status/wave_state_W${TARGET_WINDOW}"
read -r _prev_wave_state < "$WAVE_STATE_FILE" 2>/dev/null || _prev_wave_state="UNKNOWN"
if [ "$_n_working" -eq 0 ] && [ "$_n_stuck" -eq 0 ] && [ "$_n_crashed" -eq 0 ] && [ "$_all_available" -gt 0 ]; then
  _cur_wave_state="ALL_IDLE"
else
  _cur_wave_state="HAS_WORKING"
fi
echo "$_cur_wave_state" > "$WAVE_STATE_FILE"
if [ "$_prev_wave_state" = "HAS_WORKING" ] && [ "$_cur_wave_state" = "ALL_IDLE" ]; then
  echo "WAVE_COMPLETE"; SCAN_HAD_OUTPUT=true
  SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}WAVE_COMPLETE all_workers_idle${NL}"
fi

printf 'STATUS W%s | Mgr:%s | %dW %dI' "$TARGET_WINDOW" "$_mgr_label" "$_n_working" "$_n_idle"
[ "$_n_stuck" -gt 0 ] && printf ' %dS' "$_n_stuck"
[ "$_n_crashed" -gt 0 ] && printf ' %dC' "$_n_crashed"
[ -n "$_active_titles" ] && printf ' | %s' "$_active_titles"
[ -n "$_longest_label" ] && printf ' | longest:%s' "$_longest_label"
printf '\n'

# --- Completion events ---
for cf in "${RUNTIME_DIR}/status"/completion_pane_${TARGET_WINDOW}_*; do
  [ -f "$cf" ] || continue
  PANE_INDEX="" PANE_TITLE="" STATUS="" TIMESTAMP=""
  while IFS='=' read -r _cf_key _cf_val; do
    _cf_val="${_cf_val%\"}" && _cf_val="${_cf_val#\"}"
    case "$_cf_key" in
      PANE_INDEX) PANE_INDEX="$_cf_val" ;;
      PANE_TITLE) PANE_TITLE="$_cf_val" ;;
      STATUS) STATUS="$_cf_val" ;;
      TIMESTAMP) TIMESTAMP="$_cf_val" ;;
    esac
  done < "$cf"
  echo "COMPLETION ${PANE_INDEX} ${STATUS} ${PANE_TITLE}"
  SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}COMPLETION ${PANE_INDEX} ${STATUS} ${PANE_TITLE}${NL}"
  rm -f "$cf"
done

# --- Write team snapshot ---
SNAPSHOT_FILE="${RUNTIME_DIR}/status/team_snapshot_W${TARGET_WINDOW}.txt"
{
  printf 'SNAPSHOT_TIME=%s\n' "$SCAN_TIME"
  printf 'MANAGER=%s\n' "$_mgr_label"
  printf 'MANAGER_TITLE=%s\n' "$MGR_TITLE"
  _total=0
  for _ci in $PANES_LIST; do is_numeric "$_ci" && _total=$((_total + 1)); done
  printf 'TOTAL_WORKERS=%s\n' "$_total"
  printf 'WORKING=%s\nIDLE=%s\nSTUCK=%s\nCRASHED=%s\nRESERVED=%s\n' \
    "$_n_working" "$_n_idle" "$_n_stuck" "$_n_crashed" "$_n_reserved"
  printf -- '---\n'
  printf 'PANE|STATE|TITLE|DURATION_SECS|LAST_TOOL|PREV_STATE\n'
  for i in $PANES_LIST; do
    is_numeric "$i" || continue
    eval "_sn_st=\${PANE_STATE_${i}:-UNKNOWN}"
    eval "_sn_title=\${PANE_TITLE_${i}:-}"
    eval "_sn_dur=\${PANE_DURATION_${i}:-0}"
    eval "_sn_tool=\${PANE_TOOL_${i}:-}"
    eval "_sn_prev=\${PANE_PREV_DISPLAY_${i}:-}"
    case "$_sn_st" in CHANGED|UNCHANGED) _sn_st="WORKING" ;; esac
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

# --- Inline snapshot for watchdog ---
if [ -f "$SNAPSHOT_FILE" ]; then
  echo "--- SNAPSHOT ---"
  cat "$SNAPSHOT_FILE"
  echo "--- END SNAPSHOT ---"
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
fi

echo "SCAN_TIME=${SCAN_TIME}"
