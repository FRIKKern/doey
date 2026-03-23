#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
# Read config from tmux env (set by doey.sh at launch), fall back to default
if [ -z "${DOEY_WATCHDOG_SCAN_INTERVAL:-}" ]; then
  DOEY_WATCHDOG_SCAN_INTERVAL=$(tmux show-environment DOEY_WATCHDOG_SCAN_INTERVAL 2>/dev/null | cut -d= -f2-) || true
fi
DOEY_WATCHDOG_SCAN_INTERVAL="${DOEY_WATCHDOG_SCAN_INTERVAL:-30}"
TRIGGER="${RUNTIME_DIR}/status/watchdog_trigger_W${1:-${DOEY_TEAM_WINDOW:-1}}"

i=0
while [ "$i" -lt "$DOEY_WATCHDOG_SCAN_INTERVAL" ]; do
  if [ -f "$TRIGGER" ]; then
    rm -f "$TRIGGER" 2>/dev/null
    echo "TRIGGERED"
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
echo "TIMEOUT"
