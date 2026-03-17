#!/usr/bin/env bash
# Watchdog wait: sleeps up to 30s, wakes immediately on trigger file.
# Called by the Watchdog between scan cycles instead of plain `sleep 30`.
# The trigger file is written by stop-results.sh when a worker finishes.
set -euo pipefail

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 30; exit 0; }
TEAM_WINDOW="${1:-${DOEY_TEAM_WINDOW:-1}}"
TRIGGER="${RUNTIME_DIR}/status/watchdog_trigger_W${TEAM_WINDOW}"

for _w in $(seq 1 30); do
  if [ -f "$TRIGGER" ]; then
    rm -f "$TRIGGER" 2>/dev/null
    echo "TRIGGERED"
    exit 0
  fi
  sleep 1
done
echo "TIMEOUT"
