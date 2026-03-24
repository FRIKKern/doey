#!/usr/bin/env bash
# Session Manager wait — sleeps up to 30s, wakes on new messages or triggers.
set -euo pipefail

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true

SM_PANE="${SM_PANE:-0.1}"
SM_SAFE="${SESSION_NAME//[:.]/_}_${SM_PANE//[:.]/_}"
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/session_manager_trigger"

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

i=0
while [ "$i" -lt 30 ]; do
  # Wake on explicit trigger
  if [ -f "$TRIGGER" ]; then
    rm -f "$TRIGGER" 2>/dev/null
    _sm_dbg_wake "trigger" "$i"
    echo "TRIGGERED"
    exit 0
  fi
  # Wake on new messages addressed to Session Manager
  set -- "$MSG_DIR"/${SM_SAFE}_*.msg
  if [ -f "${1:-}" ]; then _sm_dbg_wake "new_messages" "$i"; echo "NEW_MESSAGES"; exit 0; fi
  # Wake on new results
  set -- "$RUNTIME_DIR/results"/pane_*.json
  if [ -f "${1:-}" ]; then _sm_dbg_wake "new_results" "$i"; echo "NEW_RESULTS"; exit 0; fi
  # Wake on crash alerts
  set -- "$RUNTIME_DIR/status"/crash_pane_*
  if [ -f "${1:-}" ]; then _sm_dbg_wake "crash_alert" "$i"; echo "CRASH_ALERT"; exit 0; fi
  sleep 1
  i=$((i + 1))
done
_sm_dbg_wake "timeout" "30"
echo "TIMEOUT"
