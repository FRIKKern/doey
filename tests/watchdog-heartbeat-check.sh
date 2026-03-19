#!/usr/bin/env bash
set -euo pipefail

# Watchdog heartbeat health-check — reports HEALTHY or STALE (threshold: 120s)

HEARTBEAT_DIR="/tmp/doey/claude-code-tmux-team/status"
STALE_THRESHOLD=120
NOW=$(date +%s)
any_stale=0
found=0

for hb_file in "$HEARTBEAT_DIR"/watchdog_W[0-9]*.heartbeat; do
    [ -f "$hb_file" ] || break
    found=1

    team=$(basename "$hb_file" | sed 's/^watchdog_//; s/\.heartbeat$//')
    timestamp=$(cat "$hb_file" 2>/dev/null || echo "")

    if [ -z "$timestamp" ]; then
        echo "Team $team: STALE (empty)"
        any_stale=1
        continue
    fi

    age=$((NOW - timestamp))
    if [ "$age" -gt "$STALE_THRESHOLD" ]; then
        echo "Team $team: STALE (${age}s ago)"
        any_stale=1
    else
        echo "Team $team: HEALTHY (${age}s ago)"
    fi
done

if [ "$found" -eq 0 ]; then
    echo "WARNING: No heartbeat files in $HEARTBEAT_DIR"
    exit 1
fi

exit "$any_stale"
