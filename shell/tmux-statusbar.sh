#!/usr/bin/env bash
set -uo pipefail
# tmux-statusbar.sh — Dynamic status-right renderer for doey sessions.
# Called by tmux every 5s via status-interval. Must stay lightweight (<50ms).
# Shows: reservation status for focused pane + worker summary counts.
# NOTE: This script is read-only — it never mutates state. Hooks own cleanup.

_raw=$(tmux show-environment DOEY_RUNTIME 2>/dev/null) || { echo " --/-- "; exit 0; }
RUNTIME_DIR="${_raw#DOEY_RUNTIME=}"
[ -z "$RUNTIME_DIR" ] && { echo " --/-- "; exit 0; }

# --- Focused pane reservation check ---
FOCUSED_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
FOCUSED_SAFE=${FOCUSED_PANE//[:.]/_}
RESERVE_FILE="${RUNTIME_DIR}/status/${FOCUSED_SAFE}.reserved"
RESERVE_INFO=""

if [ -f "$RESERVE_FILE" ]; then
  read -r EXPIRY < "$RESERVE_FILE" 2>/dev/null || EXPIRY=""
  if [ "$EXPIRY" = "permanent" ]; then
    RESERVE_INFO="#[fg=red,bold] RESERVED#[fg=default,nobold]"
  elif [[ "$EXPIRY" =~ ^[0-9]+$ ]]; then
    NOW=$(date +%s)
    REMAINING=$(( EXPIRY - NOW ))
    if [ "$REMAINING" -gt 0 ]; then
      if [ "$REMAINING" -le 10 ]; then
        RESERVE_INFO="#[fg=yellow] RSV:${REMAINING}s#[fg=default]"
      else
        RESERVE_INFO="#[fg=red] RSV:${REMAINING}s#[fg=default]"
      fi
    fi
    # Expired reservations are NOT cleaned up here — hooks own cleanup
  fi
fi

# --- Worker counts (single awk pass, skip if no status files) ---
shopt -s nullglob
status_files=("$RUNTIME_DIR/status/"*.status)
if [ ${#status_files[@]} -eq 0 ]; then
  read -r WORKING IDLE RESERVED <<< "0 0 0"
else
  read -r WORKING IDLE RESERVED <<< "$(awk '/STATUS: WORKING/{w++} /STATUS: IDLE/{i++} /STATUS: RESERVED/{r++} END{print w+0, i+0, r+0}' "${status_files[@]}")"
fi

if [ "$RESERVED" -gt 0 ]; then
  WORKERS="${WORKING}W/${IDLE}I/#[fg=red]${RESERVED}R#[fg=default]"
elif [ "$WORKING" -gt 0 ]; then
  WORKERS="#[fg=cyan]${WORKING}W#[fg=default]/${IDLE}I"
else
  WORKERS="${IDLE}I"
fi

# --- Output ---
if [ -n "$RESERVE_INFO" ]; then
  echo "${RESERVE_INFO} | ${WORKERS}"
else
  echo "${WORKERS}"
fi
