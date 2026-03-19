#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

# Strip surrounding quotes from a value
strip_quotes() { local v="${1%\"}"; echo "${v#\"}"; }

# Parse session.env (no eval — /tmp is world-writable)
SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME=""
while IFS='=' read -r key value; do
  value=$(strip_quotes "$value")
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
  esac
done < "$SESSION_ENV"

# Pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Role detection
ROLE="worker"
TEAM_WINDOW="$WINDOW_INDEX"

if [ "$WINDOW_INDEX" = "0" ]; then
  sm_val=$(strip_quotes "$(grep '^SM_PANE=' "$SESSION_ENV" | cut -d= -f2- || true)")
  if [ "0.${PANE_INDEX}" = "${sm_val:-0.1}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  else
    for tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$tf" ] || continue
      wd_pane=$(strip_quotes "$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2-)")
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
  mgr_pane="0"
  team_env="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  if [ -f "$team_env" ]; then
    mgr_val=$(strip_quotes "$(grep '^MANAGER_PANE=' "$team_env" | cut -d= -f2-)")
    [ -n "$mgr_val" ] && mgr_pane="$mgr_val"
  fi
  [ "$PANE_INDEX" = "$mgr_pane" ] && ROLE="manager"
fi

# Worktree directory
wt_dir=""
wt_env="${RUNTIME_DIR}/team_${TEAM_WINDOW}.env"
if [ -f "$wt_env" ]; then
  wt_dir=$(strip_quotes "$(grep '^WORKTREE_DIR=' "$wt_env" 2>/dev/null | head -1 | cut -d= -f2-)")
fi

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
