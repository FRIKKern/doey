#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux callbacks must not crash on transient failures

# Fast pane border label: shows pane title + 🔒 if reserved
# Called by tmux pane-border-format via #()

PANE_REF="${1:-}"
[ -z "$PANE_REF" ] && exit 0

TITLE=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || TITLE=""

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
if [ -n "$RUNTIME_DIR" ]; then
  PANE_SAFE="${PANE_REF//[:.]/_}"
  RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
  if [ -f "$RESERVE_FILE" ]; then
    echo "${TITLE} 🔒"
    exit 0
  fi
fi

echo "$TITLE"
