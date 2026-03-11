#!/usr/bin/env bash
# tmux-statusbar.sh — Fast status-right renderer for doey sessions.
# Called by tmux every 1s via status-interval. Must stay lightweight.

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
[ -z "$RUNTIME_DIR" ] && { echo "Monitor:--s | Workers:--"; exit 0; }

# --- Countdown timer ---
NOW=$(date +%s)
LAST=$(cat "$RUNTIME_DIR/status/last_monitor.ts" 2>/dev/null || echo "0")
ELAPSED=$(( NOW - LAST ))
REMAINING=$(( 60 - ELAPSED ))
[ "$REMAINING" -lt 0 ] && REMAINING=0

if [ "$REMAINING" -le 10 ]; then
  COUNTDOWN="#[fg=green]${REMAINING}s#[fg=default]"
elif [ "$REMAINING" -le 30 ]; then
  COUNTDOWN="#[fg=yellow]${REMAINING}s#[fg=default]"
else
  COUNTDOWN="${REMAINING}s"
fi

# --- Worker counts (single awk pass instead of grep-per-file) ---
read -r WORKING IDLE <<< "$(awk '/STATUS: WORKING/{w++} /STATUS: IDLE/{i++} END{print w+0, i+0}' "$RUNTIME_DIR/status/"*.status 2>/dev/null || echo "0 0")"

if [ "$WORKING" -gt 0 ]; then
  WORKERS="#[fg=cyan]${WORKING}W#[fg=default]/${IDLE}I"
else
  WORKERS="${IDLE}I"
fi

echo "Monitor:${COUNTDOWN} | Workers:${WORKERS}"
