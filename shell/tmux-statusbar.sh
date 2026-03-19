#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux status bar must not crash on transient failures

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
[ -z "$RUNTIME_DIR" ] && { echo " --/-- "; exit 0; }

FOCUSED_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
FOCUSED_SAFE=${FOCUSED_PANE//[:.]/_}

shopt -s nullglob
status_files=("$RUNTIME_DIR/status/"*.status)
if [ ${#status_files[@]} -gt 0 ]; then
  read -r BUSY READY FINISHED RESERVED <<< "$(awk '/STATUS: BUSY/{b++} /STATUS: READY/{r++} /STATUS: FINISHED/{f++} /STATUS: RESERVED/{v++} END{print b+0, r+0, f+0, v+0}' "${status_files[@]}")"
else
  BUSY=0 READY=0 FINISHED=0 RESERVED=0
fi

WORKERS=""
[ "$BUSY" -gt 0 ] && WORKERS="#[fg=cyan]${BUSY}B#[fg=colour248]/"
WORKERS+="${READY}R"
[ "$FINISHED" -gt 0 ] && WORKERS+="/${FINISHED}F"
[ "$RESERVED" -gt 0 ] && WORKERS+="/#[fg=red]${RESERVED}Rsv#[fg=colour248]"

if [ -f "${RUNTIME_DIR}/status/${FOCUSED_SAFE}.reserved" ]; then
  echo "#[fg=red,bold] RESERVED#[fg=colour248,nobold] | ${WORKERS}"
else
  echo "${WORKERS}"
fi
