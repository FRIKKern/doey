#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

# Read unquoted value from env file: _env_val file key
_env_val() { local v; v=$(grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true; v="${v%\"}"; echo "${v#\"}"; }

SESSION_NAME=$(_env_val "$SESSION_ENV" SESSION_NAME)
PROJECT_DIR=$(_env_val "$SESSION_ENV" PROJECT_DIR)
PROJECT_NAME=$(_env_val "$SESSION_ENV" PROJECT_NAME)

# Pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Role detection
ROLE="worker"
TEAM_WINDOW="$WINDOW_INDEX"

if [ "$WINDOW_INDEX" = "0" ]; then
  sm_val=$(_env_val "$SESSION_ENV" SM_PANE)
  if [ "0.${PANE_INDEX}" = "${sm_val:-0.1}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  else
    for tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$tf" ] || continue
      wd_pane=$(_env_val "$tf" WATCHDOG_PANE)
      if [ "$wd_pane" = "0.${PANE_INDEX}" ]; then
        ROLE="watchdog"
        fn="${tf##*/}"
        TEAM_WINDOW="${fn#team_}"
        TEAM_WINDOW="${TEAM_WINDOW%.env}"
        break
      fi
    done
  fi
else
  mgr_pane=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
  [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="manager"
fi

wt_dir=$(_env_val "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)

cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_RUNTIME="$RUNTIME_DIR"
export SESSION_NAME="$SESSION_NAME"
export PROJECT_DIR="$PROJECT_DIR"
export PROJECT_NAME="$PROJECT_NAME"
export DOEY_ROLE="$ROLE"
export DOEY_PANE_INDEX="$PANE_INDEX"
export DOEY_WINDOW_INDEX="$WINDOW_INDEX"
export DOEY_TEAM_WINDOW="$TEAM_WINDOW"
export DOEY_TEAM_DIR="${wt_dir:-$PROJECT_DIR}"
EOF

# Pane title
case "$ROLE" in
  watchdog)        tmux select-pane -t "${TMUX_PANE}" -T "T${TEAM_WINDOW} Watchdog" ;;
  manager)         tmux select-pane -t "${TMUX_PANE}" -T "T${TEAM_WINDOW} Window Manager" ;;
  session_manager) tmux select-pane -t "${TMUX_PANE}" -T "Session Manager" ;;
  worker)          tmux select-pane -t "${TMUX_PANE}" -T "T${TEAM_WINDOW} W${PANE_INDEX}" ;;
esac
