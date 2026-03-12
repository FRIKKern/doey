#!/usr/bin/env bash
set -uo pipefail
# tmux-statusbar.sh — Dynamic status-right renderer for doey sessions.
# Called by tmux every 2s via status-interval. Must stay lightweight (<50ms).
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
  RESERVE_INFO="#[fg=red,bold] RESERVED#[fg=default,nobold]"
fi

# --- Worker counts (single awk pass, skip if no status files) ---
shopt -s nullglob
status_files=("$RUNTIME_DIR/status/"*.status)
if [ ${#status_files[@]} -eq 0 ]; then
  read -r BUSY READY FINISHED RESERVED <<< "0 0 0 0"
else
  read -r BUSY READY FINISHED RESERVED <<< "$(awk '/STATUS: BUSY/{b++} /STATUS: READY/{r++} /STATUS: FINISHED/{f++} /STATUS: RESERVED/{v++} END{print b+0, r+0, f+0, v+0}' "${status_files[@]}")"
fi

WORKERS=""
if [ "$BUSY" -gt 0 ]; then
  WORKERS="#[fg=cyan]${BUSY}B#[fg=default]"
fi
if [ -n "$WORKERS" ]; then WORKERS+="/"; fi
WORKERS+="${READY}R"
[ "$FINISHED" -gt 0 ] && { [ -n "$WORKERS" ] && WORKERS+="/"; WORKERS+="${FINISHED}F"; }
if [ "$RESERVED" -gt 0 ]; then
  WORKERS+="/#[fg=red]${RESERVED}Rsv#[fg=default]"
fi

# --- Output ---
if [ -n "$RESERVE_INFO" ]; then
  echo "${RESERVE_INFO} | ${WORKERS}"
else
  echo "${WORKERS}"
fi
