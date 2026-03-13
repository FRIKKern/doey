#!/usr/bin/env bash
# Watchdog pre-filter scan — captures pane state with minimal output.
# Called by the watchdog as a single Bash tool call each cycle.
# Reduces LLM token usage by hashing pane content and only reporting changes.

set -euo pipefail

# --- Load session environment ---
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { echo "ERROR: not in doey session"; exit 1; }
source "${RUNTIME_DIR}/session.env"

# --- Resolve hash command once (avoid per-pane fork) ---
if command -v md5 >/dev/null 2>&1; then
  hash_fn() { md5 -qs "$1"; }
else
  hash_fn() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
fi

# --- Collect pane states (bash 3 compatible, no associative arrays) ---
# States stored as PANE_STATE_<index>=value


# --- Scan each worker pane ---
IFS=',' read -ra PANES <<< "$WORKER_PANES"
for i in "${PANES[@]}"; do
  # Validate pane index before use in eval/variable expansion
  [[ "$i" =~ ^[0-9]+$ ]] || continue
  PANE_REF="${SESSION_NAME}:0.${i}"
  PANE_SAFE="${SESSION_NAME//[:.]/_}_0_${i}"

  # Check reservation
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "PANE ${i} RESERVED"
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
  if [[ "$CURRENT_CMD" =~ ^(bash|zsh|sh|fish)$ ]]; then
    STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    if [ -f "$STATUS_FILE" ] && grep -q '^STATUS: FINISHED' "$STATUS_FILE"; then
      echo "PANE ${i} FINISHED"
      eval "PANE_STATE_${i}=FINISHED"
    elif [ -f "$STATUS_FILE" ] && grep -q '^STATUS: RESERVED' "$STATUS_FILE"; then
      echo "PANE ${i} RESERVED"
      eval "PANE_STATE_${i}=RESERVED"
    else
      echo "PANE ${i} CRASHED"
      eval "PANE_STATE_${i}=CRASHED"
    fi
    continue
  fi

  # Capture last 5 lines
  CAPTURE=$(tmux capture-pane -t "$PANE_REF" -p -S -5 2>/dev/null) || CAPTURE=""

  # Hash the capture
  HASH=$(hash_fn "$CAPTURE")

  HASH_FILE="${RUNTIME_DIR}/status/pane_hash_${PANE_SAFE}"
  OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null) || true

  if [ "$HASH" = "$OLD_HASH" ]; then
    echo "PANE ${i} UNCHANGED"
    eval "PANE_STATE_${i}=UNCHANGED"
    continue
  fi

  # Hash changed — update stored hash (atomic write)
  echo "$HASH" > "${HASH_FILE}.tmp" && mv "${HASH_FILE}.tmp" "$HASH_FILE"

  # Classify the change
  if [[ "$CAPTURE" == *'❯'* ]]; then
    echo "PANE ${i} IDLE"
    eval "PANE_STATE_${i}=IDLE"
  elif [[ "$CAPTURE" =~ thinking|working|Bash|Read|Edit|Write|Grep|Glob|Agent ]]; then
    echo "PANE ${i} WORKING"
    eval "PANE_STATE_${i}=WORKING"
  else
    echo "PANE ${i} CHANGED"
    echo "$CAPTURE" | sed 's/^/  /'
    eval "PANE_STATE_${i}=CHANGED"
  fi
done

# --- Inbox check ---
shopt -s nullglob
INBOX_FILES=("${RUNTIME_DIR}/messages/"*.msg)
INBOX_COUNT=${#INBOX_FILES[@]}
shopt -u nullglob

# --- Write heartbeat ---
SCAN_TIME=$(date +%s)
echo "$SCAN_TIME" > "${RUNTIME_DIR}/status/watchdog.heartbeat.tmp" && \
  mv "${RUNTIME_DIR}/status/watchdog.heartbeat.tmp" "${RUNTIME_DIR}/status/watchdog.heartbeat"

# --- Write pane states JSON (atomic) ---
JSON="{"
FIRST=true
for i in "${PANES[@]}"; do
  # Validate pane index before eval to prevent injection
  [[ "$i" =~ ^[0-9]+$ ]] || continue
  eval "STATE=\${PANE_STATE_${i}:-UNKNOWN}"
  if [ "$FIRST" = true ]; then
    JSON+="\"${i}\":\"${STATE}\""
    FIRST=false
  else
    JSON+=",\"${i}\":\"${STATE}\""
  fi
done
JSON+="}"
echo "$JSON" > "${RUNTIME_DIR}/status/watchdog_pane_states.json.tmp" && \
  mv "${RUNTIME_DIR}/status/watchdog_pane_states.json.tmp" "${RUNTIME_DIR}/status/watchdog_pane_states.json"

# --- Summary footer ---
echo "SCAN_TIME=${SCAN_TIME}"
echo "INBOX: ${INBOX_COUNT} pending"
