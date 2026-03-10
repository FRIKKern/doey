#!/usr/bin/env bash
# tmux-statusbar.sh — Fast status-right renderer for claude-team sessions.
# Called by tmux every 1s via status-interval. Must stay lightweight.

RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-)
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

# --- Worker counts ---
WORKING=0
IDLE=0
for f in "$RUNTIME_DIR/status/"*.status; do
  [ -f "$f" ] || continue
  if grep -q 'STATUS: WORKING' "$f" 2>/dev/null; then
    WORKING=$((WORKING + 1))
  elif grep -q 'STATUS: IDLE' "$f" 2>/dev/null; then
    IDLE=$((IDLE + 1))
  fi
done

if [ "$WORKING" -gt 0 ]; then
  WORKERS="#[fg=cyan]${WORKING}W#[fg=default]/${IDLE}I"
else
  WORKERS="${IDLE}I"
fi

echo "Monitor:${COUNTDOWN} | Workers:${WORKERS}"
