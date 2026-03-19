#!/usr/bin/env bash
# Watchdog wait: sleep up to 30s, wake on trigger file from stop-results.sh.
set -euo pipefail

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
TRIGGER="${RUNTIME_DIR}/status/watchdog_trigger_W${1:-${DOEY_TEAM_WINDOW:-1}}"

for _w in $(seq 1 30); do
  if [ -f "$TRIGGER" ]; then
    rm -f "$TRIGGER" 2>/dev/null
    echo "TRIGGERED"
    exit 0
  fi
  sleep 1
done
echo "TIMEOUT"
