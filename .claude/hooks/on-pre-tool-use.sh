#!/usr/bin/env bash
# PreToolUse hook — blocks dangerous commands per role.
# Hot path: runs before EVERY tool call. Must be fast.
set -euo pipefail

INPUT=$(cat)

# Lightweight error logger for fast path (common.sh not loaded)
_log_block() {
  local cat="$1" msg="$2" detail="${3:-}"
  local _rt="${DOEY_RUNTIME:-}"
  [ -z "$_rt" ] && _rt=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) 2>/dev/null
  [ -z "$_rt" ] && return 0
  local _pid="${DOEY_PANE_ID:-unknown}" _role="${_DOEY_ROLE:-unknown}"
  local _now; _now=$(date '+%Y-%m-%dT%H:%M:%S')
  mkdir -p "${_rt}/errors" 2>/dev/null || return 0
  printf '[%s] %s | %s | %s | on-pre-tool-use | %s | %s | %s\n' \
    "$_now" "$cat" "$_pid" "$_role" "${TOOL_NAME:-n/a}" "${detail:-n/a}" "$msg" \
    >> "${_rt}/errors/errors.log" 2>/dev/null
}

# Parse a JSON field via jq (with grep fallback)
_json_str() {
  local f="$1"
  if [ "${_HAS_JQ:-}" = "1" ]; then
    echo "$INPUT" | jq -r ".${f} // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${f}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*\"${f}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" || echo ""
  fi
}

# Check if an rm command targets a dangerous path with recursive+force flags.
# Handles any flag ordering: rm -rf, rm -fr, rm -r -f, rm --recursive --force, etc.
_is_destructive_rm() {
  local cmd="$1"
  case "$cmd" in *"rm "*) ;; *) return 1 ;; esac
  local rm_part
  rm_part=$(printf '%s' "$cmd" | sed 's/.*rm[[:space:]]/rm /;s/[;&|].*//')
  local has_r=false has_f=false
  for token in $rm_part; do
    case "$token" in
      --recursive) has_r=true ;;
      --force) has_f=true ;;
      -*)
        case "$token" in -*r*|-*R*) has_r=true ;; esac
        case "$token" in -*f*) has_f=true ;; esac
        ;;
    esac
  done
  "$has_r" && "$has_f" || return 1
  case "$rm_part" in
    *" /"*|*" ~"*|*' $HOME'*|*" /Users/"*|*" /home/"*) return 0 ;;
  esac
  return 1
}

# Check command against blocked patterns; sets MSG or returns 1
_check_blocked() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
  case "$cmd" in
    *"git push"*|*"git commit"*|*"gh pr create"*|*"gh pr merge"*)
      MSG="git/gh commands" ;;
    *"shutdown"*|*"reboot"*)
      MSG="system commands" ;;
    *"tmux kill-session"*|*"tmux kill-server"*|*"tmux send-keys"*)
      MSG="tmux commands" ;;
    *)
      if _is_destructive_rm "$cmd"; then
        MSG="destructive rm"
      else
        return 1
      fi
      ;;
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
    _log_block "TOOL_BLOCKED" "Watchdog cannot use $TOOL_NAME" "monitoring role only"
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
      _log_block "TOOL_BLOCKED" "send /rename via send-keys blocked" "opens interactive prompt"
      echo "BLOCKED: Never send /rename via send-keys — it opens an interactive prompt that eats the next paste." >&2
      echo "Use: tmux select-pane -t \"\$PANE\" -T \"task-name\"" >&2
      exit 2 ;;
  esac
  exit 0
fi

# Git Agent: allow git/gh commands, block other dangerous patterns via _check_blocked
if [ "$_DOEY_ROLE" = "git_agent" ]; then
  TOOL_COMMAND=$(_json_str tool_input.command)
  [ -z "$TOOL_COMMAND" ] && exit 0
  # _check_blocked catches git/gh too — skip that match for git_agent
  case "$TOOL_COMMAND" in *"git push"*|*"git commit"*|*"gh pr create"*|*"gh pr merge"*) exit 0 ;; esac
  if _check_blocked "$TOOL_COMMAND"; then
    _log_block "TOOL_BLOCKED" "Git Agent $MSG blocked" "$TOOL_COMMAND"
    echo "BLOCKED: Git Agent cannot run ${MSG}." >&2; exit 2
  fi
  exit 0
fi

# Worker fast path: skip init_hook entirely (saves 4+ tmux/subprocess calls)
if [ "$_DOEY_ROLE" = "worker" ]; then
  TOOL_COMMAND=$(_json_str tool_input.command)
  [ -z "$TOOL_COMMAND" ] && exit 0
  if _check_blocked "$TOOL_COMMAND"; then
    _log_block "TOOL_BLOCKED" "Worker $MSG blocked" "$TOOL_COMMAND"
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
      # _targets_manager: true if command targets pane .0 (Manager) via expanded
      # value, unexpanded ${TEAM_WINDOW}, or $TEAM_WINDOW literal references
      _targets_manager() {
        case "$1" in
          *":${TEAM_WINDOW}.0"*) return 0 ;;
          *'${TEAM_WINDOW}.0'*) return 0 ;;
          *'$TEAM_WINDOW.0'*) return 0 ;;
          *'${DOEY_TEAM_WINDOW}.0'*) return 0 ;;
          *'$DOEY_TEAM_WINDOW.0'*) return 0 ;;
        esac
        return 1
      }
      if [ -n "$TEAM_WINDOW" ] && [ -f "${RUNTIME_DIR}/status/manager_crashed_W${TEAM_WINDOW}" ]; then
        if _targets_manager "$TOOL_COMMAND"; then
            _log_block "TOOL_BLOCKED" "Watchdog send-keys to crashed manager blocked" "pane ${TEAM_WINDOW}.0"
            echo "BLOCKED: Watchdog cannot send keys to crashed Manager pane ${TEAM_WINDOW}.0." >&2
            echo "Write an alert file for the Session Manager instead." >&2
            exit 2
        fi
      fi
      CLEAN_CMD=$(echo "$TOOL_COMMAND" | sed 's/[[:space:]]*2>\/dev\/null[[:space:]]*$//')
      echo "$CLEAN_CMD" | grep -qE '^[[:space:]]*tmux copy-mode[[:space:]]' && exit 0
      if [ -n "$TEAM_WINDOW" ]; then
        _targets_manager "$TOOL_COMMAND" && exit 0
      fi
      _TP='(\"[^\"]*\"|[^[:space:]]+)'
      echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+\"?(/login|/compact)\"?[[:space:]]+Enter[[:space:]]*$" && exit 0
      echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+Enter[[:space:]]*$" && exit 0
      echo "$CLEAN_CMD" | grep -qE "^[[:space:]]*tmux send-keys[[:space:]]+-t[[:space:]]+${_TP}[[:space:]]+Escape[[:space:]]*$" && exit 0
      _log_block "TOOL_BLOCKED" "Watchdog unauthorized keystroke blocked" "$TOOL_COMMAND"
      echo "BLOCKED: Watchdog cannot send keystrokes to worker panes." >&2
      echo "Report stuck workers to the Window Manager instead." >&2
      exit 2 ;;
  esac
fi

# Blocked patterns for Workers and Watchdog
ROLE="worker"; is_watchdog && ROLE="watchdog"
if _check_blocked "$TOOL_COMMAND"; then
  _log_block "TOOL_BLOCKED" "$ROLE $MSG blocked" "$TOOL_COMMAND"
  echo "BLOCKED: ${ROLE} cannot run ${MSG}. Only the Window Manager can do this." >&2
  exit 2
fi
exit 0
