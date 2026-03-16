#!/usr/bin/env bash
# SessionStart hook: injects Doey environment variables into every Claude Code session
# via CLAUDE_ENV_FILE so all subsequent Bash tool calls have them.
set -euo pipefail

# Bail silently if not in tmux
[ -z "${TMUX_PANE:-}" ] && exit 0

# Get runtime dir from tmux environment — bail if not set
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

# Bail if no env file to write to
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

# Source session.env for project metadata
SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

# Read variables from session.env (single-pass parse, no eval — /tmp is world-writable)
SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME="" WATCHDOG_PANE=""
while IFS='=' read -r key value; do
  # Strip surrounding quotes (session.env values may be quoted)
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
    WATCHDOG_PANE) WATCHDOG_PANE="$value" ;;
  esac
done < "$SESSION_ENV"

# Write environment variables (append, don't overwrite)
cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_RUNTIME="$RUNTIME_DIR"
export SESSION_NAME="$SESSION_NAME"
export PROJECT_DIR="$PROJECT_DIR"
export PROJECT_NAME="$PROJECT_NAME"
EOF

# Determine pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
# Extract window index for multi-window support
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Multi-window: check team_<W>.env for per-window watchdog, fall back to session.env
TEAM_WD_PANE=""
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
if [ -f "$TEAM_ENV" ]; then
  TEAM_WD_PANE=$(grep '^WATCHDOG_PANE=' "$TEAM_ENV" | cut -d= -f2-)
  TEAM_WD_PANE="${TEAM_WD_PANE%\"}" && TEAM_WD_PANE="${TEAM_WD_PANE#\"}"
fi
# Fall back to session.env WATCHDOG_PANE (already parsed above)
[ -z "$TEAM_WD_PANE" ] && TEAM_WD_PANE="$WATCHDOG_PANE"

# Determine role — pane 0 is always manager in any window
if [ "$PANE_INDEX" = "0" ]; then
  ROLE="manager"
elif [ "$PANE_INDEX" = "$TEAM_WD_PANE" ]; then
  ROLE="watchdog"
else
  ROLE="worker"
fi

cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_ROLE="$ROLE"
export DOEY_PANE_INDEX="$PANE_INDEX"
export DOEY_WINDOW_INDEX="$WINDOW_INDEX"
EOF
