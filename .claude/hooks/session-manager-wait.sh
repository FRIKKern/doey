#!/usr/bin/env bash
# Session Manager wait — sleeps up to 30s, wakes on new messages or triggers.
set -euo pipefail

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
source "${RUNTIME_DIR}/session.env" 2>/dev/null || true

SM_PANE="${SM_PANE:-0.1}"
SM_SAFE="${SESSION_NAME//[:.]/_}_${SM_PANE//[:.]/_}"
MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER="${RUNTIME_DIR}/status/session_manager_trigger"

i=0
while [ "$i" -lt 30 ]; do
  # Wake on explicit trigger
  if [ -f "$TRIGGER" ]; then
    rm -f "$TRIGGER" 2>/dev/null
    echo "TRIGGERED"
    exit 0
  fi
  # Wake on new messages addressed to Session Manager
  set -- "$MSG_DIR"/${SM_SAFE}_*.msg
  [ -f "${1:-}" ] && { echo "NEW_MESSAGES"; exit 0; }
  # Wake on new results
  set -- "$RUNTIME_DIR/results"/pane_*.json
  [ -f "${1:-}" ] && { echo "NEW_RESULTS"; exit 0; }
  # Wake on crash alerts
  set -- "$RUNTIME_DIR/status"/crash_pane_*
  [ -f "${1:-}" ] && { echo "CRASH_ALERT"; exit 0; }
  sleep 1
  i=$((i + 1))
done
echo "TIMEOUT"
