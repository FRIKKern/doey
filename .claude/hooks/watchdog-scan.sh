#!/usr/bin/env bash
# Watchdog pre-filter scan — captures pane state with minimal output.
# Called by the watchdog as a single Bash tool call each cycle.
# Reduces LLM token usage by hashing pane content and only reporting changes.

set -euo pipefail

# Numeric-only validation (bash 3.2 safe)
is_numeric() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }

# Newline variable for string building (bash 3.2 safe)
NL='
'

# --- Load session environment ---
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { echo "ERROR: not in doey session"; exit 1; }

# --- Detect pane identity ---
PANE_INFO=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}.#{pane_index}' 2>/dev/null) || PANE_INFO="0.0"
WINDOW_INDEX="${PANE_INFO%.*}"
PANE_INDEX="${PANE_INFO#*.}"

# --- Resolve target team window ---
# Watchdog lives in Dashboard (window 0) but monitors a team window.
# Find which team has WATCHDOG_PANE="0.<our pane index>".
TARGET_WINDOW=""
for _wds_tf in "${RUNTIME_DIR}"/team_*.env; do
  [ -f "$_wds_tf" ] || continue
  _wds_wd=$(grep '^WATCHDOG_PANE=' "$_wds_tf" | cut -d= -f2-)
  _wds_wd="${_wds_wd%\"}" && _wds_wd="${_wds_wd#\"}"
  if [ "$_wds_wd" = "0.${PANE_INDEX}" ]; then
    _wds_fn="${_wds_tf##*/}"   # team_N.env
    _wds_fn="${_wds_fn#team_}" # N.env
    TARGET_WINDOW="${_wds_fn%.env}"
    break
  fi
done
# Fallback: use pane index as team window (0.1 → team 1, 0.2 → team 2)
[ -z "$TARGET_WINDOW" ] && TARGET_WINDOW="$PANE_INDEX"

# Safe key-value parse — load target team's env file
TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WINDOW}.env"
if [ -f "$TEAM_ENV" ]; then
  _ENV_SRC="$TEAM_ENV"
else
  _ENV_SRC="${RUNTIME_DIR}/session.env"
fi
while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    WORKER_PANES) WORKER_PANES="$value" ;;
    SESSION_NAME) SESSION_NAME="$value" ;;
  esac
done < "$_ENV_SRC"

# --- Resolve hash command once (avoid per-pane fork) ---
if command -v md5 >/dev/null 2>&1; then
  hash_fn() { md5 -qs "$1"; }
else
  hash_fn() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
fi

# --- Collect pane states (bash 3 compatible, no associative arrays) ---
# States stored as PANE_STATE_<index>=value

# --- Load previous pane states from JSON (for stuck detection & suppression) ---
PREV_STATES_FILE="${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json"
if [ -f "$PREV_STATES_FILE" ]; then
  PREV_JSON=$(cat "$PREV_STATES_FILE" 2>/dev/null) || PREV_JSON="{}"
  # Parse "index":"STATE" pairs — bash 3.2 compatible
  PREV_PAIRS=$(echo "$PREV_JSON" | sed 's/[{}"]//g' | tr ',' '\n')
  while IFS=: read -r pidx pstate; do
    pidx="${pidx// /}"
    pstate="${pstate// /}"
    is_numeric "$pidx" || continue
    # Validate state value before eval to prevent injection from corrupted JSON
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

# --- Snapshot tracking variables ---
SNAPSHOT_EVENTS=""

# --- Window Manager health check (Manager is pane 0 in the target team window) ---
MGR_PANE_REF=""
TEAM_ENV="${RUNTIME_DIR}/team_${TARGET_WINDOW}.env"
if [ -f "$TEAM_ENV" ]; then
  _wds_mgr=$(grep '^MANAGER_PANE=' "$TEAM_ENV" | cut -d= -f2-)
  _wds_mgr="${_wds_mgr%\"}" && _wds_mgr="${_wds_mgr#\"}"
  [ -n "$_wds_mgr" ] && MGR_PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.${_wds_mgr}"
fi
# Fallback: Manager is pane 0 in the target team window
[ -z "$MGR_PANE_REF" ] && MGR_PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.0"

MGR_CMD=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
case "$MGR_CMD" in
  bash|zsh|sh|fish)
    echo "MANAGER_CRASHED"; SCAN_HAD_OUTPUT=true
    # Write alert file so on-pre-tool-use.sh can block send-keys to the dead Manager
    CRASH_ALERT="${RUNTIME_DIR}/status/manager_crashed_W${TARGET_WINDOW}"
    if [ ! -f "$CRASH_ALERT" ]; then
      # Atomic write via temp+mv (consistent with heartbeat pattern)
      _crash_tmp="${CRASH_ALERT}.tmp"
      printf 'TEAM_WINDOW=%s\nTIMESTAMP=%s\n' "${TARGET_WINDOW}" "$(date +%s)" > "$_crash_tmp"
      mv "$_crash_tmp" "$CRASH_ALERT"
    fi
    ;;
  *)
    # Manager is alive — clean up any stale crash alert
    rm -f "${RUNTIME_DIR}/status/manager_crashed_W${TARGET_WINDOW}" 2>/dev/null
    ;;
esac

# --- Manager idle detection (for completion notification) ---
MGR_CAPTURE=$(tmux capture-pane -t "$MGR_PANE_REF" -p -S -3 2>/dev/null) || MGR_CAPTURE=""
case "$MGR_CAPTURE" in
  *'❯'*|*'> '*) PANE_STATE_0="IDLE" ;;
  *) PANE_STATE_0="WORKING" ;;
esac

# Detect Manager WORKING→IDLE transition (completion event for Session Manager)
MGR_PREV_FILE="${RUNTIME_DIR}/status/manager_prev_state_W${TARGET_WINDOW}"
read -r MGR_PREV_STATE < "$MGR_PREV_FILE" 2>/dev/null || MGR_PREV_STATE="UNKNOWN"
echo "$PANE_STATE_0" > "$MGR_PREV_FILE"
if [ "$MGR_PREV_STATE" = "WORKING" ] && [ "$PANE_STATE_0" = "IDLE" ]; then
  echo "MANAGER_COMPLETED"
  SCAN_HAD_OUTPUT=true
fi

# --- Scan each worker pane ---
PANES_LIST="${WORKER_PANES//,/ }"
# Note: SCAN_HAD_OUTPUT may already be true from MANAGER_CRASHED above — don't reset
for i in $PANES_LIST; do
  # Validate pane index before use in eval/variable expansion
  is_numeric "$i" || continue
  PANE_REF="${SESSION_NAME}:${TARGET_WINDOW}.${i}"
  PANE_SAFE="${SESSION_SAFE}_${TARGET_WINDOW}_${i}"

  # Check reservation
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "PANE ${i} RESERVED"; SCAN_HAD_OUTPUT=true
    eval "PANE_STATE_${i}=RESERVED"
    eval "PANE_TITLE_${i}=''"
    eval "PANE_TOOL_${i}=''"
    eval "PANE_DURATION_${i}=0"
    eval "PANE_PREV_DISPLAY_${i}=''"
    continue
  fi

  # Exit copy-mode only if pane is actually in copy-mode
  PANE_MODE=$(tmux display-message -t "$PANE_REF" -p '#{pane_mode}' 2>/dev/null) || PANE_MODE=""
  if [ "$PANE_MODE" = "copy-mode" ]; then
    tmux copy-mode -q -t "$PANE_REF" 2>/dev/null || true
  fi

  # Check for crash (shell prompt without claude/node running)
  # Cross-check with status file to avoid false-positives on normally finished workers
  CURRENT_CMD=$(tmux display-message -t "$PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || CURRENT_CMD=""
  case "$CURRENT_CMD" in
    bash|zsh|sh|fish)
      STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
      _crash_state=""
      if [ -f "$STATUS_FILE" ] && grep -q '^STATUS: FINISHED' "$STATUS_FILE"; then
        echo "PANE ${i} FINISHED"; SCAN_HAD_OUTPUT=true
        _crash_state="FINISHED"
      elif [ -f "$STATUS_FILE" ] && grep -q '^STATUS: RESERVED' "$STATUS_FILE"; then
        echo "PANE ${i} RESERVED"; SCAN_HAD_OUTPUT=true
        _crash_state="RESERVED"
      else
        echo "PANE ${i} CRASHED"; SCAN_HAD_OUTPUT=true
        _crash_state="CRASHED"
        # Write crash alert file for Window Manager consumption
        CRASH_FILE="${RUNTIME_DIR}/status/crash_pane_${TARGET_WINDOW}_${i}"
        if [ ! -f "$CRASH_FILE" ]; then
          CRASH_CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -10 2>/dev/null) || CRASH_CAPTURE=""
          cat > "$CRASH_FILE" << CRASH_EOF
PANE_INDEX=${i}
TIMESTAMP=$(date +%s)
LAST_OUTPUT=$(echo "$CRASH_CAPTURE" | tail -5 | tr '\n' '|')
CRASH_EOF
        fi
      fi
      eval "PANE_STATE_${i}='${_crash_state}'"
      # Duration tracking for crashed/finished/reserved panes
      _pt=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || _pt=""
      eval "PANE_TITLE_${i}='${_pt}'"
      eval "PANE_TOOL_${i}=''"
      # State-since tracking
      eval "_prev_for_dur=\${PREV_STATE_${i}:-UNKNOWN}"
      STATE_SINCE_FILE="${RUNTIME_DIR}/status/state_since_${TARGET_WINDOW}_${i}"
      if [ "$_prev_for_dur" != "$_crash_state" ]; then
        echo "$SCAN_TIME" > "$STATE_SINCE_FILE"
        eval "PANE_DURATION_${i}=0"
        SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}STATE_CHANGE ${i} ${_prev_for_dur}->${_crash_state}${NL}"
      else
        read -r _since < "$STATE_SINCE_FILE" 2>/dev/null || _since="$SCAN_TIME"
        eval "PANE_DURATION_${i}=$(($SCAN_TIME - $_since))"
      fi
      eval "PANE_PREV_DISPLAY_${i}='${_prev_for_dur}'"
      continue
      ;;
  esac

  # Capture last 5 lines
  CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null) || CAPTURE=""

  # Hash the capture
  HASH=$(hash_fn "$CAPTURE")

  HASH_FILE="${RUNTIME_DIR}/status/pane_hash_${PANE_SAFE}"
  read -r OLD_HASH < "$HASH_FILE" 2>/dev/null || OLD_HASH=""

  if [ "$HASH" = "$OLD_HASH" ]; then
    # Content unchanged — but is the pane idle or actually working?
    # Check if pane is sitting at the prompt (idle) vs actively processing
    _pt=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || _pt=""
    eval "PANE_TITLE_${i}='${_pt}'"
    eval "PANE_TOOL_${i}=''"

    # Re-check capture for idle prompt — an idle worker at ❯ is not stuck
    _unch_capture=$(tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null) || _unch_capture=""
    _is_at_prompt=""
    case "$_unch_capture" in
      *'❯'*|*'● Ready'*) _is_at_prompt="yes" ;;
    esac

    eval "PREV=\${PREV_STATE_${i}:-UNKNOWN}"
    STATE_SINCE_FILE="${RUNTIME_DIR}/status/state_since_${TARGET_WINDOW}_${i}"

    if [ -n "$_is_at_prompt" ]; then
      # Pane is at the prompt — it's IDLE, not stuck
      rm -f "${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}" 2>/dev/null
      _unch_state="IDLE"
      # Only print if this is a state change
      if [ "$PREV" != "IDLE" ] && [ "$PREV" != "UNCHANGED" ] || [ "$PREV" = "UNCHANGED" ]; then
        # Suppress repeated IDLE — only report on transition
        case "$PREV" in
          IDLE|UNCHANGED) ;;
          *) echo "PANE ${i} IDLE"; SCAN_HAD_OUTPUT=true ;;
        esac
      fi
      # Display state for duration tracking
      _display_prev="IDLE"
      case "$PREV" in
        WORKING|CHANGED|STUCK) _display_prev="WORKING" ;;
        IDLE|UNCHANGED|FINISHED) _display_prev="IDLE" ;;
        *) _display_prev="$PREV" ;;
      esac
      if [ "$_display_prev" != "IDLE" ]; then
        echo "$SCAN_TIME" > "$STATE_SINCE_FILE"
        eval "PANE_DURATION_${i}=0"
        SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}STATE_CHANGE ${i} ${_display_prev}->IDLE${NL}"
      else
        read -r _since < "$STATE_SINCE_FILE" 2>/dev/null || { echo "$SCAN_TIME" > "$STATE_SINCE_FILE"; _since="$SCAN_TIME"; }
        eval "PANE_DURATION_${i}=$(($SCAN_TIME - $_since))"
      fi
      eval "PANE_PREV_DISPLAY_${i}='${_display_prev}'"
    else
      # Pane content unchanged and NOT at prompt — could be stuck
      COUNTER_FILE="${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}"
      read -r OLD_COUNT < "$COUNTER_FILE" 2>/dev/null || OLD_COUNT=0
      NEW_COUNT=$((OLD_COUNT + 1))
      echo "$NEW_COUNT" > "$COUNTER_FILE"

      # After 6 consecutive UNCHANGED cycles while not at prompt, escalate to STUCK
      _unch_state=""
      if [ "$NEW_COUNT" -ge 6 ]; then
        echo "PANE ${i} STUCK (unchanged for ${NEW_COUNT} cycles, not at prompt)"; SCAN_HAD_OUTPUT=true
        _unch_state="STUCK"
      else
        _unch_state="UNCHANGED"
      fi
      # Display state for duration tracking
      _display_state="WORKING"
      read -r _since < "$STATE_SINCE_FILE" 2>/dev/null || { echo "$SCAN_TIME" > "$STATE_SINCE_FILE"; _since="$SCAN_TIME"; }
      eval "PANE_DURATION_${i}=$(($SCAN_TIME - $_since))"
      eval "PANE_PREV_DISPLAY_${i}='${_display_state}'"
    fi
    eval "PANE_STATE_${i}='${_unch_state}'"
    continue
  fi

  # Hash changed — reset unchanged counter
  rm -f "${RUNTIME_DIR}/status/unchanged_count_${TARGET_WINDOW}_${i}" 2>/dev/null

  # Hash changed — update stored hash (atomic write)
  echo "$HASH" > "${HASH_FILE}.tmp" && mv "${HASH_FILE}.tmp" "$HASH_FILE"

  # Classify the change
  _classified_state=""
  case "$CAPTURE" in
    *'❯'*)
      echo "PANE ${i} IDLE"; SCAN_HAD_OUTPUT=true
      _classified_state="IDLE"
      ;;
    *thinking*|*working*|*Bash*|*Read*|*Edit*|*Write*|*Grep*|*Glob*|*Agent*)
      echo "PANE ${i} WORKING"; SCAN_HAD_OUTPUT=true
      _classified_state="WORKING"
      ;;
    *)
      echo "PANE ${i} CHANGED"; SCAN_HAD_OUTPUT=true
      _classified_state="CHANGED"
      ;;
  esac
  eval "PANE_STATE_${i}='${_classified_state}'"

  # Capture pane title
  _pt=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || _pt=""
  eval "PANE_TITLE_${i}='${_pt}'"

  # Extract last tool name from capture (for WORKING/CHANGED panes)
  _last_tool=""
  if [ "$_classified_state" = "WORKING" ] || [ "$_classified_state" = "CHANGED" ]; then
    # Scan capture for tool names — last match wins
    _remaining="$CAPTURE"
    while [ -n "$_remaining" ]; do
      _line="${_remaining%%${NL}*}"
      case "$_line" in
        *Agent*) _last_tool="Agent" ;;
        *Bash*)  _last_tool="Bash" ;;
        *Read*)  _last_tool="Read" ;;
        *Edit*)  _last_tool="Edit" ;;
        *Write*) _last_tool="Write" ;;
        *Grep*)  _last_tool="Grep" ;;
        *Glob*)  _last_tool="Glob" ;;
      esac
      # Advance to next line
      if [ "$_remaining" = "$_line" ]; then
        break
      fi
      _remaining="${_remaining#*${NL}}"
    done
  fi
  eval "PANE_TOOL_${i}='${_last_tool}'"

  # Duration tracking — detect state changes
  eval "_prev_for_dur=\${PREV_STATE_${i}:-UNKNOWN}"
  # Map to display states for comparison (CHANGED→WORKING, UNCHANGED→keep prev)
  case "$_classified_state" in
    WORKING|CHANGED) _display_now="WORKING" ;;
    *) _display_now="$_classified_state" ;;
  esac
  case "$_prev_for_dur" in
    WORKING|CHANGED|UNCHANGED|STUCK) _display_prev="WORKING" ;;
    IDLE|FINISHED) _display_prev="IDLE" ;;
    *) _display_prev="$_prev_for_dur" ;;
  esac
  STATE_SINCE_FILE="${RUNTIME_DIR}/status/state_since_${TARGET_WINDOW}_${i}"
  if [ "$_display_prev" != "$_display_now" ]; then
    echo "$SCAN_TIME" > "$STATE_SINCE_FILE"
    eval "PANE_DURATION_${i}=0"
    SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}STATE_CHANGE ${i} ${_display_prev}->${_display_now}${NL}"
  else
    read -r _since < "$STATE_SINCE_FILE" 2>/dev/null || { echo "$SCAN_TIME" > "$STATE_SINCE_FILE"; _since="$SCAN_TIME"; }
    eval "PANE_DURATION_${i}=$(($SCAN_TIME - $_since))"
  fi
  eval "PANE_PREV_DISPLAY_${i}='${_display_prev}'"
done

# --- Status summary (always printed for Watchdog display) ---
# Manager status
case "$MGR_CMD" in
  bash|zsh|sh|fish) _mgr_label="CRASHED" ;;
  *) _mgr_label="$PANE_STATE_0" ;;
esac
MGR_TITLE=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_title}' 2>/dev/null) || MGR_TITLE=""

# Build compact worker summary: count by state + list active titles
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
      # Track longest-running worker
      if [ "$_dur" -gt "$_longest_dur" ]; then
        _longest_dur="$_dur"
        _longest_pane="$i"
      fi
      ;;
    IDLE|FINISHED) _n_idle=$((_n_idle + 1)) ;;
    STUCK) _n_stuck=$((_n_stuck + 1)) ;;
    CRASHED) _n_crashed=$((_n_crashed + 1)) ;;
    RESERVED) _n_reserved=$((_n_reserved + 1)) ;;
    *) _n_other=$((_n_other + 1)) ;;
  esac
done

# Format longest duration as HhMmSs
_longest_label=""
if [ -n "$_longest_pane" ] && [ "$_longest_dur" -gt 0 ]; then
  _lh=$((_longest_dur / 3600))
  _lm=$(((_longest_dur % 3600) / 60))
  _ls=$((_longest_dur % 60))
  if [ "$_lh" -gt 0 ]; then
    _longest_label="${_longest_pane}@${_lh}h${_lm}m${_ls}s"
  elif [ "$_lm" -gt 0 ]; then
    _longest_label="${_longest_pane}@${_lm}m${_ls}s"
  else
    _longest_label="${_longest_pane}@${_ls}s"
  fi
fi

# --- Wave completion detection (HAS_WORKING → ALL_IDLE transition) ---
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
  echo "WAVE_COMPLETE"
  SCAN_HAD_OUTPUT=true
  SNAPSHOT_EVENTS="${SNAPSHOT_EVENTS}WAVE_COMPLETE all_workers_idle${NL}"
fi

# Print summary line
printf 'STATUS W%s | Mgr:%s | %dW %dI' "$TARGET_WINDOW" "$_mgr_label" "$_n_working" "$_n_idle"
[ "$_n_stuck" -gt 0 ] && printf ' %dS' "$_n_stuck"
[ "$_n_crashed" -gt 0 ] && printf ' %dC' "$_n_crashed"
[ -n "$_active_titles" ] && printf ' | %s' "$_active_titles"
[ -n "$_longest_label" ] && printf ' | longest:%s' "$_longest_label"
printf '\n'

# --- Check for worker completion events ---
for cf in "${RUNTIME_DIR}/status"/completion_pane_${TARGET_WINDOW}_*; do
  [ -f "$cf" ] || continue
  # Safe key-value parse (completion files live in /tmp, avoid sourcing)
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

# --- Write team snapshot file ---
SNAPSHOT_FILE="${RUNTIME_DIR}/status/team_snapshot_W${TARGET_WINDOW}.txt"
SNAPSHOT_TMP="${SNAPSHOT_FILE}.tmp"
{
  printf 'SNAPSHOT_TIME=%s\n' "$SCAN_TIME"
  printf 'MANAGER=%s\n' "$_mgr_label"
  printf 'MANAGER_TITLE=%s\n' "$MGR_TITLE"
  _total=0
  for _ci in $PANES_LIST; do is_numeric "$_ci" && _total=$((_total + 1)); done
  printf 'TOTAL_WORKERS=%s\n' "$_total"
  printf 'WORKING=%s\n' "$_n_working"
  printf 'IDLE=%s\n' "$_n_idle"
  printf 'STUCK=%s\n' "$_n_stuck"
  printf 'CRASHED=%s\n' "$_n_crashed"
  printf 'RESERVED=%s\n' "$_n_reserved"
  printf -- '---\n'
  printf 'PANE|STATE|TITLE|DURATION_SECS|LAST_TOOL|PREV_STATE\n'
  for i in $PANES_LIST; do
    is_numeric "$i" || continue
    eval "_sn_st=\${PANE_STATE_${i}:-UNKNOWN}"
    eval "_sn_title=\${PANE_TITLE_${i}:-}"
    eval "_sn_dur=\${PANE_DURATION_${i}:-0}"
    eval "_sn_tool=\${PANE_TOOL_${i}:-}"
    eval "_sn_prev=\${PANE_PREV_DISPLAY_${i}:-}"
    # Normalize display state for snapshot
    case "$_sn_st" in
      CHANGED) _sn_st="WORKING" ;;
      UNCHANGED) _sn_st="WORKING" ;;  # Brief transitional state before IDLE or STUCK
    esac
    printf '%s|%s|%s|%s|%s|%s\n' "$i" "$_sn_st" "$_sn_title" "$_sn_dur" "$_sn_tool" "$_sn_prev"
  done
  printf -- '---\n'
  printf 'EVENTS\n'
  # Print collected events (trailing newline already in each entry)
  printf '%s' "$SNAPSHOT_EVENTS"
} > "$SNAPSHOT_TMP" && mv "$SNAPSHOT_TMP" "$SNAPSHOT_FILE"

# --- Write heartbeat ---
echo "$SCAN_TIME" > "${RUNTIME_DIR}/status/watchdog_W${TARGET_WINDOW}.heartbeat.tmp" && \
  mv "${RUNTIME_DIR}/status/watchdog_W${TARGET_WINDOW}.heartbeat.tmp" "${RUNTIME_DIR}/status/watchdog_W${TARGET_WINDOW}.heartbeat"

# --- Write pane states JSON (atomic) ---
JSON="{"
FIRST=true
for i in $PANES_LIST; do
  # Validate pane index before eval to prevent injection
  is_numeric "$i" || continue
  eval "STATE=\${PANE_STATE_${i}:-UNKNOWN}"
  if [ "$FIRST" = true ]; then
    JSON+="\"${i}\":\"${STATE}\""
    FIRST=false
  else
    JSON+=",\"${i}\":\"${STATE}\""
  fi
done
JSON+="}"
echo "$JSON" > "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json.tmp" && \
  mv "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json.tmp" "${RUNTIME_DIR}/status/watchdog_pane_states_W${TARGET_WINDOW}.json"

# --- Append snapshot inline (so watchdog doesn't need a second tool call) ---
if [ -f "$SNAPSHOT_FILE" ]; then
  echo "--- SNAPSHOT ---"
  cat "$SNAPSHOT_FILE"
  echo "--- END SNAPSHOT ---"
fi

# --- Context check: detect watchdog's own context % from pane status line ---
# Parse "Ctx ████░░░░░░ 42%" from the watchdog's pane (TMUX_PANE = self)
_ctx_line=$(tmux capture-pane -t "${TMUX_PANE}" -p -S -5 2>/dev/null | grep 'Ctx ' | tail -1) || _ctx_line=""
_ctx_pct=""
if [ -n "$_ctx_line" ]; then
  # Extract percentage number from "Ctx ████░░░░░░ 42%"
  _ctx_pct=$(echo "$_ctx_line" | sed 's/.*Ctx [^ ]* //;s/%.*//')
  # Strip whitespace
  _ctx_pct="${_ctx_pct// /}"
fi
is_numeric "$_ctx_pct" || _ctx_pct="0"
if [ "$_ctx_pct" -ge 60 ]; then
  echo ""
  echo "⚠️  COMPACT_NOW — context at ${_ctx_pct}% (threshold: 60%)"
  echo "You MUST run /compact immediately. Do NOT run another scan cycle first."
fi

# --- Summary footer ---
echo "SCAN_TIME=${SCAN_TIME}"
