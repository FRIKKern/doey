#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
# Read config from tmux env (set by doey.sh at launch), fall back to default
if [ -z "${DOEY_WATCHDOG_SCAN_INTERVAL:-}" ]; then
  DOEY_WATCHDOG_SCAN_INTERVAL=$(tmux show-environment DOEY_WATCHDOG_SCAN_INTERVAL 2>/dev/null | cut -d= -f2-) || true
fi
DOEY_WATCHDOG_SCAN_INTERVAL="${DOEY_WATCHDOG_SCAN_INTERVAL:-30}"
TRIGGER="${RUNTIME_DIR}/status/watchdog_trigger_W${1:-${DOEY_TEAM_WINDOW:-1}}"

# Debug mode check
_WW_DBG=false
[ -f "${RUNTIME_DIR}/debug.conf" ] && _WW_DBG=true
_WW_TW="${1:-${DOEY_TEAM_WINDOW:-1}}"
_WW_DBG_FILE="${RUNTIME_DIR}/debug/watchdog_W${_WW_TW}.jsonl"

_ww_dbg_wake() {
  [ "$_WW_DBG" = "true" ] || return 0
  local reason="$1" elapsed="$2"
  [ -d "$(dirname "$_WW_DBG_FILE")" ] || mkdir -p "$(dirname "$_WW_DBG_FILE")" 2>/dev/null
  printf '{"ts":%s,"window":%s,"cat":"watchdog","msg":"wake","reason":"%s","wait_s":%s}\n' \
    "$(date +%s)" "$_WW_TW" "$reason" "$elapsed" \
    >> "$_WW_DBG_FILE" 2>/dev/null
  return 0
}

# Pre-sleep check: catch triggers/messages that arrived before entering the loop
if [ -f "$TRIGGER" ]; then
  rm -f "$TRIGGER" 2>/dev/null
  _ww_dbg_wake "trigger_presleep" "0"
  echo "TRIGGERED"
  exit 0
fi
# Check for pending messages addressed to this watchdog pane
_WW_SESSION="${DOEY_SESSION:-}"
if [ -z "$_WW_SESSION" ]; then
  _WW_SESSION=$(tmux show-environment DOEY_SESSION 2>/dev/null | cut -d= -f2-) || true
fi
if [ -z "$_WW_SESSION" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
  _WW_SESSION=$(. "${RUNTIME_DIR}/session.env" && printf '%s' "${SESSION_NAME:-}") || true
fi
_WW_PANE="${DOEY_PANE_INDEX:-}"
if [ -n "$_WW_SESSION" ] && [ -n "$_WW_PANE" ]; then
  _WW_MSG_DIR="${RUNTIME_DIR}/messages"
  _WW_SAFE="${_WW_SESSION//[-:.]/_}_${_WW_PANE//[-:.]/_}"
  set -- "$_WW_MSG_DIR"/${_WW_SAFE}_*.msg
  if [ -f "${1:-}" ]; then _ww_dbg_wake "new_messages_presleep" "0"; echo "NEW_MESSAGES"; exit 0; fi
fi

i=0
while [ "$i" -lt "$DOEY_WATCHDOG_SCAN_INTERVAL" ]; do
  if [ -f "$TRIGGER" ]; then
    rm -f "$TRIGGER" 2>/dev/null
    _ww_dbg_wake "trigger" "$i"
    echo "TRIGGERED"
    exit 0
  fi
  if [ -n "$_WW_SESSION" ] && [ -n "$_WW_PANE" ]; then
    set -- "$_WW_MSG_DIR"/${_WW_SAFE}_*.msg
    if [ -f "${1:-}" ]; then _ww_dbg_wake "new_messages" "$i"; echo "NEW_MESSAGES"; exit 0; fi
  fi
  sleep 1
  i=$((i + 1))
done
_ww_dbg_wake "timeout" "$DOEY_WATCHDOG_SCAN_INTERVAL"
echo "TIMEOUT"

exit 0
