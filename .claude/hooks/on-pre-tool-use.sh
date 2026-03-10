#!/usr/bin/env bash
# Claude Code hook: PreToolUse — blocks dangerous operations on worker panes.
set -euo pipefail

HOOK_DIR="$(dirname "$0")"
if [ -f "$HOOK_DIR/common.sh" ]; then
  source "$HOOK_DIR/common.sh"
  init_hook
else
  # Minimal inline fallback if common.sh doesn't exist yet
  INPUT=$(cat)
  [ -z "${TMUX_PANE:-}" ] && exit 0
  tmux display-message -t "${TMUX_PANE}" -p '' >/dev/null 2>&1 || exit 0
  RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_INDEX="${PANE##*.}"
fi

# Manager and Watchdog — allow everything
if is_manager 2>/dev/null || is_watchdog 2>/dev/null; then
  exit 0
fi

# Fallback role check if common.sh helpers aren't available
if ! type is_manager &>/dev/null; then
  WINDOW_AND_PANE="${PANE#*:}"
  [ "$WINDOW_AND_PANE" = "0.0" ] && exit 0
  if [ -f "${RUNTIME_DIR}/session.env" ]; then
    WD_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" | cut -d= -f2)
    [ "$PANE_INDEX" = "$WD_PANE" ] && exit 0
  fi
fi

# Parse tool info
TOOL_NAME=$(parse_field "tool_name" 2>/dev/null) || \
  TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"$//')

# Only check Bash commands
if [ "$TOOL_NAME" = "Bash" ]; then
  if command -v jq >/dev/null 2>&1; then
    TOOL_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || TOOL_COMMAND=""
  else
    TOOL_COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//;s/"$//')
  fi

  if [ -n "$TOOL_COMMAND" ]; then
    BLOCKED_PATTERNS=(
      "git push"
      "git commit"
      "gh pr create"
      "gh pr merge"
      "rm -rf /"
      "rm -rf ~"
      "rm -rf \$HOME"
      "shutdown"
      "reboot"
      "tmux kill-session"
      "tmux kill-server"
      "tmux send-keys"
    )

    for pattern in "${BLOCKED_PATTERNS[@]}"; do
      if echo "$TOOL_COMMAND" | grep -qF "$pattern"; then
        echo "BLOCKED: Workers cannot run '$pattern'. Only the Manager can do this." >&2
        echo "If you need this operation, finish your task and let the Manager handle it." >&2
        exit 2
      fi
    done
  fi
fi

exit 0
