#!/usr/bin/env bash
# PreToolUse hook — blocks dangerous commands per role.
# Hot path: runs before EVERY tool call. Must be fast.
set -euo pipefail

INPUT=$(cat)

# Parse a JSON field via jq (with grep fallback)
_json_str() {
  local f="$1"
  if [ "${_HAS_JQ:-}" = "1" ]; then
    echo "$INPUT" | jq -r ".${f} // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${f}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*\"${f}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" || echo ""
  fi
}

# Check command against blocked patterns; sets MSG or returns 1
_check_blocked() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
  case "$cmd" in
    *"git push"*|*"git commit"*|*"gh pr create"*|*"gh pr merge"*)
      MSG="git/gh commands" ;;
    *"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*|*"rm -rf /Users/"*|*"rm -rf /home/"*)
      MSG="destructive rm" ;;
    *"shutdown"*|*"reboot"*)
      MSG="system commands" ;;
    *"tmux kill-session"*|*"tmux kill-server"*|*"tmux send-keys"*)
      MSG="tmux commands" ;;
    *) return 1 ;;
  esac
}

_HAS_JQ=0; command -v jq >/dev/null 2>&1 && _HAS_JQ=1
TOOL_NAME=$(_json_str tool_name)

# Resolve role: per-pane role file is authoritative (tmux session env is shared,
# so DOEY_ROLE from env may be stale/wrong — last pane to start wins).
_DOEY_ROLE="${DOEY_ROLE:-}"
if [ -n "${TMUX_PANE:-}" ]; then
  _RD="${DOEY_RUNTIME:-}"
  [ -z "$_RD" ] && _RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
  if [ -n "$_RD" ]; then
    _WP=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || true
    if [ -n "$_WP" ]; then
      _PS=$(echo "$_WP" | tr ':.' '_')
      [ -f "${_RD}/status/${_PS}.role" ] && _DOEY_ROLE=$(cat "${_RD}/status/${_PS}.role" 2>/dev/null) || true
    fi
  fi
fi

# Non-Bash: block write tools for Watchdog
if [ "$TOOL_NAME" != "Bash" ]; then
  case "$TOOL_NAME" in Edit|Write|Agent|NotebookEdit) ;; *) exit 0 ;; esac
  case "$_DOEY_ROLE" in watchdog)
    echo "BLOCKED: Watchdog cannot use $TOOL_NAME — monitoring role only." >&2
    exit 2 ;;
  esac
  exit 0
fi

# Manager/Session Manager: only block /rename via send-keys
if [ "$_DOEY_ROLE" = "manager" ] || [ "$_DOEY_ROLE" = "session_manager" ]; then
  _CMD=$(_json_str tool_input.command)
  _CMD_STRIPPED=$(echo "$_CMD" | sed 's/^[[:space:]]*//')
  case "$_CMD_STRIPPED" in
    "tmux send-keys"*"/rename"*|*"&& tmux send-keys"*"/rename"*|*"; tmux send-keys"*"/rename"*)
      echo "BLOCKED: Never send /rename via send-keys — it opens an interactive prompt that eats the next paste." >&2
      echo "Use: tmux select-pane -t \"\$PANE\" -T \"task-name\"" >&2
      exit 2 ;;
  esac
  exit 0
fi

# Git Agent: allow git commands, block everything else dangerous
if [ "$_DOEY_ROLE" = "git_agent" ]; then
  TOOL_COMMAND=$(_json_str tool_input.command)
  [ -z "$TOOL_COMMAND" ] && exit 0
  case "$TOOL_COMMAND" in
    *"rm -rf /"*|*"rm -rf ~"*|*'rm -rf $HOME'*|*"rm -rf /Users/"*|*"rm -rf /home/"*)
      echo "BLOCKED: Git Agent cannot run destructive rm." >&2; exit 2 ;;
    *"shutdown"*|*"reboot"*)
      echo "BLOCKED: Git Agent cannot run system commands." >&2; exit 2 ;;
    *"tmux kill-session"*|*"tmux kill-server"*|*"tmux send-keys"*)
      echo "BLOCKED: Git Agent cannot run tmux commands." >&2; exit 2 ;;
  esac
  exit 0
fi

# Worker fast path: skip init_hook entirely (saves 4+ tmux/subprocess calls)
if [ "$_DOEY_ROLE" = "worker" ]; then
  TOOL_COMMAND=$(_json_str tool_input.command)
  [ -z "$TOOL_COMMAND" ] && exit 0
  if _check_blocked "$TOOL_COMMAND"; then
    echo "BLOCKED: Workers cannot run ${MSG}. Only the Window Manager can do this." >&2
    exit 2
  fi
  exit 0
fi

# Slow path: watchdog or unknown role — needs full init_hook for role detection
source "$(dirname "$0")/common.sh"
init_hook

is_manager && exit 0
is_session_manager && exit 0

TOOL_COMMAND=$(_json_str tool_input.command)
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
      echo "$CLEAN_CMD" | grep -qE '^[[:space:]]*tmux copy-mode[[:space:]]' && exit 0
      if [ -n "$TEAM_WINDOW" ]; then
        case "$TOOL_COMMAND" in *":${TEAM_WINDOW}.0"*) exit 0 ;; esac
      fi
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
if _check_blocked "$TOOL_COMMAND"; then
  echo "BLOCKED: ${ROLE} cannot run ${MSG}. Only the Window Manager can do this." >&2
  exit 2
fi
exit 0
