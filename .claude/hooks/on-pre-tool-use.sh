#!/usr/bin/env bash
# PreToolUse hook — blocks dangerous commands per role.
# Hot path: runs before EVERY tool call. Must be fast.
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=""
if command -v jq >/dev/null 2>&1; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
fi
[ -z "$TOOL_NAME" ] && TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"$//')

# Non-Bash: block write tools for Watchdog
if [ "$TOOL_NAME" != "Bash" ]; then
  case "$TOOL_NAME" in Edit|Write|Agent|NotebookEdit) ;; *) exit 0 ;; esac
  RUNTIME_DIR=$(tmux show-environment -t "$TMUX_PANE" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  read WINDOW_INDEX CURRENT_PANE <<< "$(tmux display-message -t "$TMUX_PANE" -p '#{window_index} #{pane_index}' 2>/dev/null)" || exit 0
  if [ "$WINDOW_INDEX" = "0" ]; then
    case "$CURRENT_PANE" in 2|3|4|5|6|7)
      for _pt_tf in "${RUNTIME_DIR}"/team_*.env; do
        [ -f "$_pt_tf" ] || continue
        _pt_wd=$(grep '^WATCHDOG_PANE=' "$_pt_tf" | cut -d= -f2)
        if [ "${_pt_wd//\"/}" = "0.${CURRENT_PANE}" ]; then
          echo "BLOCKED: Watchdog cannot use $TOOL_NAME — monitoring role only." >&2
          exit 2
        fi
      done ;;
    esac
  fi
  exit 0
fi

source "$(dirname "$0")/common.sh"
init_hook <<< "$INPUT"

is_manager && exit 0
is_session_manager && exit 0

if command -v jq >/dev/null 2>&1; then
  TOOL_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || TOOL_COMMAND=""
else
  TOOL_COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi
[ -z "$TOOL_COMMAND" ] && exit 0

# Watchdog: allow bash except sending keystrokes
if is_watchdog; then
  case "$TOOL_COMMAND" in
    *"send-keys"*|*"send-key"*|*"paste-buffer"*|*"load-buffer"*)
      TEAM_WINDOW="${DOEY_TEAM_WINDOW:-}"
      if [ -n "$TEAM_WINDOW" ] && [ -f "${RUNTIME_DIR}/status/manager_crashed_W${TEAM_WINDOW}" ]; then
        case "$TOOL_COMMAND" in
          *":${TEAM_WINDOW}.0"*)
            echo "BLOCKED: Watchdog cannot send keys to crashed Manager pane ${TEAM_WINDOW}.0." >&2
            echo "Write an alert file for the Session Manager instead." >&2
            exit 2 ;;
        esac
      fi
      CLEAN_CMD=$(echo "$TOOL_COMMAND" | sed 's/[[:space:]]*2>\/dev\/null[[:space:]]*$//')
      # Always allow: copy-mode (read-only)
      echo "$CLEAN_CMD" | grep -qE '^[[:space:]]*tmux copy-mode[[:space:]]' && exit 0
      # Allow: send-keys / paste-buffer to own Manager pane (W.0)
      if [ -n "$TEAM_WINDOW" ]; then
        case "$TOOL_COMMAND" in
          *":${TEAM_WINDOW}.0"*) exit 0 ;;
        esac
      fi
      # Allow: /login, /compact, bare Enter to any pane (worker recovery)
      _TP='(\"[^\"]*\"|[^[:space:]]+)'
      echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+\"?(/login|/compact)\"?[[:space:]]+Enter[[:space:]]*$" && exit 0
      echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+Enter[[:space:]]*$" && exit 0
      echo "BLOCKED: Watchdog cannot send keystrokes to worker panes." >&2
      echo "Report stuck workers to the Window Manager instead." >&2
      exit 2 ;;
  esac
fi

# Blocked patterns for Workers and Watchdog
ROLE="Workers"; is_watchdog && ROLE="Watchdog"

case "$TOOL_COMMAND" in
  *"git push"*|*"git commit"*|*"gh pr create"*|*"gh pr merge"*)
    MSG="git/gh commands" ;;
  *"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*)
    MSG="destructive rm" ;;
  *"shutdown"*|*"reboot"*)
    MSG="system commands" ;;
  *"tmux kill-session"*|*"tmux kill-server"*|*"tmux send-keys"*)
    MSG="tmux commands" ;;
  *) exit 0 ;;
esac

echo "BLOCKED: ${ROLE} cannot run ${MSG}. Only the Window Manager can do this." >&2
exit 2
