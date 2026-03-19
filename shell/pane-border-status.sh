#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux callbacks must not crash on transient failures

PANE_REF="${1:-}"
[ -z "$PANE_REF" ] && exit 0

TITLE=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || TITLE=""
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true

WIN_PANE="${PANE_REF##*:}"
WINDOW_IDX="${WIN_PANE%%.*}"
PANE_IDX="${WIN_PANE#*.}"

# Strip surrounding quotes from a value
unquote() { local v="${1#\"}"; echo "${v%\"}"; }

# Read a key's value from an env file
env_val() { # env_val <file> <key>
  while IFS='=' read -r k v; do
    [ "$k" = "$2" ] && { unquote "$v"; return; }
  done < "$1"
}

# Dashboard panes (window 0): show role-based labels
if [ "$WINDOW_IDX" = "0" ] && [ -n "$RUNTIME_DIR" ]; then
  SESSION_ENV="${RUNTIME_DIR}/session.env"
  if [ -f "$SESSION_ENV" ]; then
    SM_PANE=$(env_val "$SESSION_ENV" SM_PANE)
    if [ -n "$SM_PANE" ] && [ "0.${PANE_IDX}" = "$SM_PANE" ]; then
      echo "Session Manager"; exit 0
    fi
  fi

  for team_file in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$team_file" ] || continue
    WDG_PANE=$(env_val "$team_file" WATCHDOG_PANE)
    if [ -n "$WDG_PANE" ] && [ "0.${PANE_IDX}" = "$WDG_PANE" ]; then
      TEAM_WIN=$(env_val "$team_file" WINDOW_INDEX)
      echo "Watchdog Team ${TEAM_WIN:-?}"; exit 0
    fi
  done

  echo "$TITLE"; exit 0
fi

# Non-Dashboard panes: show title with reserved indicator
if [ -n "$RUNTIME_DIR" ]; then
  PANE_SAFE="${PANE_REF//[:.]/_}"
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]; then
    echo "${TITLE} 🔒"; exit 0
  fi
fi

echo "$TITLE"
