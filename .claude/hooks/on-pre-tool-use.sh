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

# Parse a JSON field via jq (with python3 fallback, then grep for top-level only)
_json_str() {
  local f="$1"
  if [ "${_HAS_JQ:-}" = "1" ]; then
    echo "$INPUT" | jq -r ".${f} // empty" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    echo "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in '${f}'.split('.'):
  d=d.get(k,'') if isinstance(d,dict) else ''
print(d if isinstance(d,str) else '')" 2>/dev/null || echo ""
  else
    # grep only handles top-level keys; nested fields (e.g. tool_input.command) fail
    case "$f" in
      *.*) _log_block "TOOL_RISK" "No jq or python3: cannot parse nested field '$f'" "Bash commands will be blocked for safety"
           echo "__PARSE_FAILED__" ;;
      *)   echo "$INPUT" | grep -o "\"${f}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*\"${f}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" || echo "" ;;
    esac
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
    *"git commit"*|*"git push"*|*"gh pr create"*|*"gh pr merge"*)
      MSG="git write operations (git commit/push, gh pr). Send a message to Session Manager with what you need committed" ;;
    *"shutdown"*|*"reboot"*)
      MSG="system commands" ;;
    *"tmux kill-session"*|*"tmux kill-server"*|*"tmux send-keys"*)
      MSG="tmux commands. Use file-based IPC (write to \$DOEY_RUNTIME/messages/) instead of send-keys" ;;
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

# Debug: one stat() when off, date+printf when on
_DBG=false
[ -n "${_RD:-}" ] && [ -f "${_RD}/debug.conf" ] && _DBG=true

# Helper: write inline debug entry (no subprocesses beyond date)
_dbg_write() {
  [ "$_DBG" = "true" ] || return 0
  local _action="$1"
  local _pdir="${_RD}/debug/${_PS:-unknown}"
  [ -d "$_pdir" ] || mkdir -p "$_pdir" 2>/dev/null
  printf '{"ts":"%s","pane":"%s","role":"%s","cat":"hooks","msg":"%s","hook":"on-pre-tool-use","tool":"%s"}\n' \
    "$(date +%s)000" "${_WP:-unknown}" "${_DOEY_ROLE:-unknown}" "$_action" "$TOOL_NAME" \
    >> "$_pdir/hooks.jsonl" 2>/dev/null
  return 0
}

# Non-Bash tool checks
if [ "$TOOL_NAME" != "Bash" ]; then
  # AskUserQuestion: only Boss may ask the user directly
  if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
    case "$_DOEY_ROLE" in
      boss) _dbg_write "allow_boss_ask_user"; exit 0 ;;
      "")   _dbg_write "allow_no_role_ask_user"; exit 0 ;;
      *)
        _log_block "TOOL_BLOCKED" "$_DOEY_ROLE cannot use AskUserQuestion" "only Boss asks the user"
        _dbg_write "block_ask_user_${_DOEY_ROLE}"
        echo "BLOCKED: Only Boss can ask the user questions directly." >&2
        echo "Send a message to Boss with your question instead:" >&2
        echo '  BOSS_SAFE="${SESSION_NAME//[-:.]/_}_0_1"' >&2
        echo '  printf "FROM: ...\nSUBJECT: question\nQUESTION: ...\n" > "${RUNTIME_DIR}/messages/${BOSS_SAFE}_$(date +%s)_$$.msg"' >&2
        exit 2 ;;
    esac
  fi
  # Non-Bash tools: allow for all remaining roles
  _dbg_write "allow_non_bash"
  exit 0
fi

# Git commit/push: blocked for all roles except session_manager
# Read-only git commands (status, diff, log, show, branch) are always allowed
if [ "$_DOEY_ROLE" != "session_manager" ]; then
  _GIT_CMD=$(_json_str tool_input.command)
  if [ -n "$_GIT_CMD" ] && [ "$_GIT_CMD" != "__PARSE_FAILED__" ]; then
    case "$_GIT_CMD" in
      *"git commit"*|*"git push"*|*"gh pr create"*|*"gh pr merge"*)
        _log_block "TOOL_BLOCKED" "${_DOEY_ROLE:-unknown} git write operation blocked" "$_GIT_CMD"
        _dbg_write "block_git_write_${_DOEY_ROLE:-unknown}"
        echo "BLOCKED: Git operations are handled by Session Manager. Send a task_complete message to your Manager." >&2
        exit 2 ;;
    esac
  fi
fi

# Manager/Session Manager: only block /rename via send-keys
# Boss does NOT get send-keys access — it communicates via .msg files only
if [ "$_DOEY_ROLE" = "manager" ] || [ "$_DOEY_ROLE" = "session_manager" ]; then
  _CMD=$(_json_str tool_input.command)
  _CMD_STRIPPED=$(echo "$_CMD" | sed 's/^[[:space:]]*//')
  case "$_CMD_STRIPPED" in
    "tmux send-keys"*"/rename"*|*"&& tmux send-keys"*"/rename"*|*"; tmux send-keys"*"/rename"*)
      _log_block "TOOL_BLOCKED" "send /rename via send-keys blocked" "opens interactive prompt"
      echo "BLOCKED: Never send /rename via send-keys — it opens an interactive prompt that eats the next paste." >&2
      echo "Use: tmux select-pane -t \"\$PANE\" -T \"task-name\"" >&2
      _dbg_write "block_rename_sendkeys"
      exit 2 ;;
  esac
  _dbg_write "allow_manager"
  exit 0
fi

# Worker fast path: skip init_hook entirely (saves 4+ tmux/subprocess calls)
if [ "$_DOEY_ROLE" = "worker" ]; then
  TOOL_COMMAND=$(_json_str tool_input.command)
  [ -z "$TOOL_COMMAND" ] && exit 0
  [ "$TOOL_COMMAND" = "__PARSE_FAILED__" ] && { echo "BLOCKED: Install jq or python3 — cannot verify Bash command safety." >&2; exit 2; }
  # Exception: workers may send-keys to the Session Manager pane
  case "$TOOL_COMMAND" in *"tmux send-keys"*)
    _rtd="${_RD:-${DOEY_RUNTIME:-}}"
    if [ -n "$_rtd" ] && [ -f "${_rtd}/session.env" ]; then
      _sm_pane=$(grep '^SM_PANE=' "${_rtd}/session.env" 2>/dev/null | head -1 | sed 's/^SM_PANE=//;s/^"//;s/"$//')
      [ -z "$_sm_pane" ] && _sm_pane="0.2"
      _sn="${SESSION_NAME:-}"
      [ -z "$_sn" ] && _sn=$(grep '^SESSION_NAME=' "${_rtd}/session.env" 2>/dev/null | head -1 | sed 's/^SESSION_NAME=//;s/^"//;s/"$//')
      case "$TOOL_COMMAND" in
        *"-t"*"${_sn}:${_sm_pane}"*|*"-t"*"${_sm_pane}"*)
          _dbg_write "allow_worker_sendkeys_sm"
          exit 0 ;;
      esac
    fi
  ;; esac
  if _check_blocked "$TOOL_COMMAND"; then
    _log_block "TOOL_BLOCKED" "Worker $MSG blocked" "$TOOL_COMMAND"
    _dbg_write "block_worker"
    echo "BLOCKED: Workers cannot run ${MSG}. Only the Window Manager can do this." >&2
    exit 2
  fi
  _dbg_write "allow_worker"
  exit 0
fi

# Slow path: unknown role — needs full init_hook for role detection
source "$(dirname "$0")/common.sh"
init_hook

is_manager && { _dbg_write "allow_manager_slow"; exit 0; }
is_session_manager && { _dbg_write "allow_sm_slow"; exit 0; }
is_boss && { _dbg_write "allow_boss_slow"; exit 0; }

TOOL_COMMAND=$(_json_str tool_input.command)
[ -z "$TOOL_COMMAND" ] && exit 0
[ "$TOOL_COMMAND" = "__PARSE_FAILED__" ] && { echo "BLOCKED: Install jq or python3 — cannot verify Bash command safety." >&2; exit 2; }

# Blocked patterns for Workers
if _check_blocked "$TOOL_COMMAND"; then
  _log_block "TOOL_BLOCKED" "worker $MSG blocked" "$TOOL_COMMAND"
  _dbg_write "block_worker"
  echo "BLOCKED: Workers cannot run ${MSG}. Only the Window Manager can do this." >&2
  exit 2
fi
_dbg_write "allow_slow"
exit 0
