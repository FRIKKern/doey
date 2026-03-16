#!/usr/bin/env bash
# Watchdog pre-filter scan — captures pane state with minimal output.
# Called by the watchdog as a single Bash tool call each cycle.
# Reduces LLM token usage by hashing pane content and only reporting changes.

set -euo pipefail

# Numeric-only validation (bash 3.2 safe)
is_numeric() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }

# --- Load session environment ---
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { echo "ERROR: not in doey session"; exit 1; }

# --- Detect window index (multi-window support) ---
WINDOW_INDEX=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) || WINDOW_INDEX="0"

# Safe key-value parse — try per-window team file first, fall back to session.env
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
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
PREV_STATES_FILE="${RUNTIME_DIR}/status/watchdog_pane_states_W${WINDOW_INDEX}.json"
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

# --- Window Manager health check (reads MANAGER_PANE from team env) ---
MGR_PANE_REF=""
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
if [ -f "$TEAM_ENV" ]; then
  _wds_mgr=$(grep '^MANAGER_PANE=' "$TEAM_ENV" | cut -d= -f2-)
  _wds_mgr="${_wds_mgr%\"}" && _wds_mgr="${_wds_mgr#\"}"
  [ -n "$_wds_mgr" ] && MGR_PANE_REF="${SESSION_NAME}:${_wds_mgr}"
fi
# Fallback for legacy layout
[ -z "$MGR_PANE_REF" ] && MGR_PANE_REF="${SESSION_NAME}:${WINDOW_INDEX}.0"

MGR_CMD=$(tmux display-message -t "$MGR_PANE_REF" -p '#{pane_current_command}' 2>/dev/null) || MGR_CMD=""
case "$MGR_CMD" in
  bash|zsh|sh|fish) echo "MANAGER_CRASHED" ;;
esac

# --- Manager idle detection (for inbox delivery) ---
MGR_CAPTURE=$(tmux capture-pane -t "$MGR_PANE_REF" -p -S -3 2>/dev/null) || MGR_CAPTURE=""
case "$MGR_CAPTURE" in
  *'❯'*|*'> '*) PANE_STATE_0="IDLE" ;;
  *) PANE_STATE_0="WORKING" ;;
esac

# --- Scan each worker pane ---
PANES_LIST="${WORKER_PANES//,/ }"
SCAN_HAD_OUTPUT=false
for i in $PANES_LIST; do
  # Validate pane index before use in eval/variable expansion
  is_numeric "$i" || continue
  PANE_REF="${SESSION_NAME}:${WINDOW_INDEX}.${i}"
  PANE_SAFE="${SESSION_SAFE}_${WINDOW_INDEX}_${i}"

  # Check reservation
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "PANE ${i} RESERVED"; SCAN_HAD_OUTPUT=true
    eval "PANE_STATE_${i}=RESERVED"
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
      if [ -f "$STATUS_FILE" ] && grep -q '^STATUS: FINISHED' "$STATUS_FILE"; then
        echo "PANE ${i} FINISHED"; SCAN_HAD_OUTPUT=true
        eval "PANE_STATE_${i}=FINISHED"
      elif [ -f "$STATUS_FILE" ] && grep -q '^STATUS: RESERVED' "$STATUS_FILE"; then
        echo "PANE ${i} RESERVED"; SCAN_HAD_OUTPUT=true
        eval "PANE_STATE_${i}=RESERVED"
      else
        echo "PANE ${i} CRASHED"; SCAN_HAD_OUTPUT=true
        eval "PANE_STATE_${i}=CRASHED"
        # Write crash alert file for Window Manager consumption
        CRASH_FILE="${RUNTIME_DIR}/status/crash_pane_${WINDOW_INDEX}_${i}"
        if [ ! -f "$CRASH_FILE" ]; then
          CRASH_CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -10 2>/dev/null) || CRASH_CAPTURE=""
          cat > "$CRASH_FILE" << CRASH_EOF
PANE_INDEX=${i}
TIMESTAMP=$(date +%s)
LAST_OUTPUT=$(echo "$CRASH_CAPTURE" | tail -5 | tr '\n' '|')
CRASH_EOF
        fi
      fi
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
    # Stuck-worker counter: increment on UNCHANGED, check previous state
    COUNTER_FILE="${RUNTIME_DIR}/status/unchanged_count_${WINDOW_INDEX}_${i}"
    read -r OLD_COUNT < "$COUNTER_FILE" 2>/dev/null || OLD_COUNT=0
    NEW_COUNT=$((OLD_COUNT + 1))
    echo "$NEW_COUNT" > "$COUNTER_FILE"

    eval "PREV=\${PREV_STATE_${i}:-UNKNOWN}"

    # After 6 consecutive UNCHANGED cycles, escalate to STUCK
    # BUT only if previous state was WORKING or CHANGED (active work)
    if [ "$NEW_COUNT" -ge 6 ] && { [ "$PREV" = "WORKING" ] || [ "$PREV" = "CHANGED" ] || [ "$PREV" = "UNCHANGED" ]; }; then
      echo "PANE ${i} STUCK (unchanged for ${NEW_COUNT} cycles)"; SCAN_HAD_OUTPUT=true
      eval "PANE_STATE_${i}=STUCK"
    else
      # Suppress UNCHANGED output — only STUCK gets printed
      eval "PANE_STATE_${i}=UNCHANGED"
    fi
    continue
  fi

  # Hash changed — reset unchanged counter
  rm -f "${RUNTIME_DIR}/status/unchanged_count_${WINDOW_INDEX}_${i}" 2>/dev/null

  # Hash changed — update stored hash (atomic write)
  echo "$HASH" > "${HASH_FILE}.tmp" && mv "${HASH_FILE}.tmp" "$HASH_FILE"

  # Classify the change
  case "$CAPTURE" in
    *'❯'*)
      echo "PANE ${i} IDLE"; SCAN_HAD_OUTPUT=true
      eval "PANE_STATE_${i}=IDLE"
      ;;
    *thinking*|*working*|*Bash*|*Read*|*Edit*|*Write*|*Grep*|*Glob*|*Agent*)
      echo "PANE ${i} WORKING"; SCAN_HAD_OUTPUT=true
      eval "PANE_STATE_${i}=WORKING"
      ;;
    *)
      echo "PANE ${i} CHANGED"; SCAN_HAD_OUTPUT=true
      eval "PANE_STATE_${i}=CHANGED"
      ;;
  esac
done

# --- No-changes shortcut (single token confirmation) ---
if [ "$SCAN_HAD_OUTPUT" = false ]; then
  echo "OK"
fi

# --- Per-pane inbox detection ---
# Single glob, then classify by pane index (avoids N readdir calls)
TOTAL_INBOX=0
HAS_MSGS=false
for _test_msg in "${RUNTIME_DIR}/messages/"*.msg; do [ -e "$_test_msg" ] && HAS_MSGS=true; break; done
if [ "$HAS_MSGS" = true ]; then
  # Count messages per idle pane using filename prefix matching
  # Include Manager (pane 0) so it can receive inbox deliveries too
  INBOX_PANES="0 $PANES_LIST"
  for msg in "${RUNTIME_DIR}/messages/"*.msg; do
    msg_name=$(basename "$msg")
    for i in $INBOX_PANES; do
      is_numeric "$i" || continue
      eval "PSTATE=\${PANE_STATE_${i}:-UNKNOWN}"
      [ "$PSTATE" = "IDLE" ] || continue
      case "$msg_name" in "${SESSION_SAFE}_${WINDOW_INDEX}_${i}_"*)
        eval "INBOX_COUNT_${i}=\$(( \${INBOX_COUNT_${i}:-0} + 1 ))"
        break
        ;; esac
    done
  done
  # Report per-pane inbox counts
  for i in $INBOX_PANES; do
    is_numeric "$i" || continue
    eval "IC=\${INBOX_COUNT_${i}:-0}"
    if [ "$IC" -gt 0 ]; then
      echo "INBOX ${i} ${IC}"
      TOTAL_INBOX=$((TOTAL_INBOX + IC))
    fi
  done
fi

# --- Check for worker completion events ---
for cf in "${RUNTIME_DIR}/status"/completion_pane_${WINDOW_INDEX}_*; do
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
  rm -f "$cf"
done

# --- Write heartbeat ---
SCAN_TIME=$(date +%s)
echo "$SCAN_TIME" > "${RUNTIME_DIR}/status/watchdog_W${WINDOW_INDEX}.heartbeat.tmp" && \
  mv "${RUNTIME_DIR}/status/watchdog_W${WINDOW_INDEX}.heartbeat.tmp" "${RUNTIME_DIR}/status/watchdog_W${WINDOW_INDEX}.heartbeat"

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
echo "$JSON" > "${RUNTIME_DIR}/status/watchdog_pane_states_W${WINDOW_INDEX}.json.tmp" && \
  mv "${RUNTIME_DIR}/status/watchdog_pane_states_W${WINDOW_INDEX}.json.tmp" "${RUNTIME_DIR}/status/watchdog_pane_states_W${WINDOW_INDEX}.json"

# --- Summary footer ---
echo "SCAN_TIME=${SCAN_TIME}"
echo "INBOX: ${TOTAL_INBOX} pending"
