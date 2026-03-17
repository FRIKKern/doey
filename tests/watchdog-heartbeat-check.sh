#!/usr/bin/env bash
set -euo pipefail

# Watchdog heartbeat health-check
# Checks /tmp/doey/claude-code-tmux-team/status/watchdog_W*.heartbeat files
# Reports HEALTHY or STALE (threshold: 120 seconds)

HEARTBEAT_DIR="/tmp/doey/claude-code-tmux-team/status"
STALE_THRESHOLD=120
NOW=$(date +%s)
ANY_STALE=0
FOUND=0

# Match only numbered team heartbeats (W1, W2, ...) not the generic watchdog_W.heartbeat
for hb_file in "$HEARTBEAT_DIR"/watchdog_W[0-9]*.heartbeat; do
    if [ ! -f "$hb_file" ]; then
        break
    fi
    FOUND=1

    basename=$(basename "$hb_file")
    # Extract team name e.g. "W1" from "watchdog_W1.heartbeat"
    team=$(echo "$basename" | sed 's/^watchdog_//; s/\.heartbeat$//')

    timestamp=$(cat "$hb_file" 2>/dev/null || echo "")
    if [ -z "$timestamp" ]; then
        echo "Team $team: STALE (empty heartbeat file)"
        ANY_STALE=1
        continue
    fi

    age=$((NOW - timestamp))
    if [ "$age" -gt "$STALE_THRESHOLD" ]; then
        echo "Team $team: STALE (${age}s ago)"
        ANY_STALE=1
    else
        echo "Team $team: HEALTHY (${age}s ago)"
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "WARNING: No watchdog heartbeat files found in $HEARTBEAT_DIR"
    exit 1
fi

if [ "$ANY_STALE" -eq 1 ]; then
    exit 1
fi

exit 0
