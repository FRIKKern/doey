#!/usr/bin/env bash
# PreToolUse hook — blocks dangerous commands per role.
# Hot path: runs before EVERY tool call. Must be fast.
set -euo pipefail

INPUT=$(cat)

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

_escalate_permission() {
  local _tool="$1" _cmd="$2" _reason="$3"
  local _rtd="${_RD:-${DOEY_RUNTIME:-}}"
  [ -z "$_rtd" ] && return 0
  local _sn="${SESSION_NAME:-}"
  [ -z "$_sn" ] && _sn=$(grep '^SESSION_NAME=' "${_rtd}/session.env" 2>/dev/null | head -1 | sed 's/^SESSION_NAME=//;s/^"//;s/"$//') || true
  [ -z "$_sn" ] && return 0
  local _wi="${DOEY_WINDOW_INDEX:-}"
  [ -z "$_wi" ] && _wi=$(grep '^DOEY_WINDOW_INDEX=' "${_rtd}/session.env" 2>/dev/null | head -1 | sed 's/^DOEY_WINDOW_INDEX=//') || true
  [ -z "$_wi" ] && return 0
  local _mgr_safe; _mgr_safe=$(printf '%s_%s_0' "$_sn" "$_wi" | tr ':.-' '_')
  local _pane_id="${_WP:-unknown}"
  local _pane_safe="${_PS:-unknown}"
  local _cmd_short; _cmd_short=$(printf '%.200s' "$_cmd")
  local _msg_dir="${_rtd}/messages"
  mkdir -p "$_msg_dir" 2>/dev/null || return 0
  printf 'FROM: %s\nSUBJECT: permission_request\nTOOL: %s\nCOMMAND: %s\nREASON: %s\nPANE: %s\n' \
    "$_pane_safe" "$_tool" "$_cmd_short" "$_reason" "$_pane_id" \
    > "${_msg_dir}/${_mgr_safe}_$(date +%s)_$$.msg" 2>/dev/null || true
  touch "${_rtd}/triggers/${_mgr_safe}.trigger" 2>/dev/null || true
}

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

# Per-pane role file is authoritative (tmux env may be stale)
_DOEY_ROLE="${DOEY_ROLE:-}"
if [ -n "${TMUX_PANE:-}" ]; then
  _RD="${DOEY_RUNTIME:-}"
  [ -z "$_RD" ] && _RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
  if [ -n "$_RD" ]; then
    _WP=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || true
    if [ -n "$_WP" ]; then
      _PS=$(echo "$_WP" | tr ':.-' '_')
      [ -f "${_RD}/status/${_PS}.role" ] && _DOEY_ROLE=$(cat "${_RD}/status/${_PS}.role" 2>/dev/null) || true
    fi
  fi
fi

# Defense-in-depth: infer role from pane position if .role file was missing
if [ -z "$_DOEY_ROLE" ] && [ -n "${_WP:-}" ] && [ -n "${_RD:-}" ]; then
  _di_wi="${_WP#*:}"; _di_wi="${_di_wi%.*}"
  _di_pi="${_WP##*.}"
  if [ "$_di_wi" = "0" ]; then
    case "$_di_pi" in
      1) _DOEY_ROLE="boss" ;;
      0) _DOEY_ROLE="info_panel" ;;
      *) _sm_p=""; [ -f "${_RD}/session.env" ] && _sm_p=$(grep '^SM_PANE=' "${_RD}/session.env" 2>/dev/null | head -1 | sed 's/^SM_PANE=//;s/^"//;s/"$//')
         [ "0.${_di_pi}" = "${_sm_p:-0.2}" ] && _DOEY_ROLE="session_manager" ;;
    esac
  else
    _di_tt=""; [ -f "${_RD}/team_${_di_wi}.env" ] && _di_tt=$(grep '^TEAM_TYPE=' "${_RD}/team_${_di_wi}.env" 2>/dev/null | head -1 | sed 's/^TEAM_TYPE=//;s/^"//;s/"$//')
    if [ "$_di_tt" != "freelancer" ]; then
      _di_mp=""; [ -f "${_RD}/team_${_di_wi}.env" ] && _di_mp=$(grep '^MANAGER_PANE=' "${_RD}/team_${_di_wi}.env" 2>/dev/null | head -1 | sed 's/^MANAGER_PANE=//;s/^"//;s/"$//')
      [ "$_di_pi" = "${_di_mp:-0}" ] && _DOEY_ROLE="manager"
    fi
    [ -z "$_DOEY_ROLE" ] && _DOEY_ROLE="worker"
  fi
fi

# ── Heartbeat emission (for stale detection by SM) ──
if [ -n "${_RD:-}" ] && [ -n "${_PS:-}" ]; then
  _HB_FILE="${_RD}/status/${_PS}.heartbeat"
  _hb_write=true
  if [ -f "$_HB_FILE" ]; then
    _hb_age=$(( $(date +%s) - $(stat -f%m "$_HB_FILE" 2>/dev/null || echo 0) ))
    [ "$_hb_age" -lt 10 ] && _hb_write=false
  fi
  if [ "$_hb_write" = "true" ]; then
    _hb_tmp="${_HB_FILE}.tmp"
    printf '%s %s %s\n' "$(date +%s)" "${DOEY_TASK_ID:-}" "${DOEY_PANE_ID:-${_PS}}" > "$_hb_tmp" && mv "$_hb_tmp" "$_HB_FILE"
  fi
fi

_DBG=false
[ -n "${_RD:-}" ] && [ -f "${_RD}/debug.conf" ] && _DBG=true

_dbg_write() {
  [ "$_DBG" = "true" ] || return 0
  local _action="$1" _pdir="${_RD}/debug/${_PS:-unknown}"
  [ -d "$_pdir" ] || mkdir -p "$_pdir" 2>/dev/null
  printf '{"ts":"%s","pane":"%s","role":"%s","cat":"hooks","msg":"%s","hook":"on-pre-tool-use","tool":"%s"}\n' \
    "$(date +%s)000" "${_WP:-unknown}" "${_DOEY_ROLE:-unknown}" "$_action" "$TOOL_NAME" \
    >> "$_pdir/hooks.jsonl" 2>/dev/null
}

if [ "$_DOEY_ROLE" = "boss" ] && [ "$TOOL_NAME" = "Bash" ]; then
  _BOSS_CMD=$(_json_str tool_input.command)
  case "$_BOSS_CMD" in *"send-keys"*"-t"*)
    _boss_target=$(echo "$_BOSS_CMD" | sed 's/.*-t[[:space:]]*//' | sed 's/[[:space:]].*//' | sed 's/^"//;s/"$//')
    case "$_boss_target" in
      *:0.2|*_0_2*|0.2)
        _dbg_write "allow_boss_sendkeys_sm"
        ;; # fall through to boss exit 0
      *)
        _log_block "TOOL_BLOCKED" "Boss send-keys to non-SM pane blocked" "$_BOSS_CMD"
        _dbg_write "block_boss_sendkeys_${_boss_target}"
        echo "BLOCKED: Boss may only send-keys to SM pane (0.2)" >&2
        exit 2 ;;
    esac
  ;; esac
fi

if [ "$_DOEY_ROLE" = "boss" ]; then
  _dbg_write "allow_boss_unrestricted"
  exit 0
fi

# Manager restrictions on non-Bash tools (coordinator only — no project source access)
if [ "$_DOEY_ROLE" = "manager" ] && [ "$TOOL_NAME" != "Bash" ]; then
  case "$TOOL_NAME" in
    Agent)
      _log_block "TOOL_BLOCKED" "Manager cannot use Agent tool" "delegate to workers instead"
      _dbg_write "block_manager_agent"
      echo "BLOCKED: Managers coordinate — they don't spawn agents. Dispatch to workers instead." >&2
      exit 2 ;;
    Read|Edit|Write|Glob|Grep)
      _MGR_PATH=$(_json_str tool_input.file_path)
      [ -z "$_MGR_PATH" ] && _MGR_PATH=$(_json_str tool_input.path)
      _mgr_allowed=false
      case "${_MGR_PATH:-}" in
        */.doey/tasks/*|*/.doey/tasks) _mgr_allowed=true ;;
        "${_RD:-__none__}"/*|*/tmp/doey/*) _mgr_allowed=true ;;
      esac
      if [ "$_mgr_allowed" = "false" ]; then
        _log_block "TOOL_BLOCKED" "Manager $TOOL_NAME on project source blocked" "${_MGR_PATH:-project root}"
        _dbg_write "block_manager_source_${TOOL_NAME}"
        echo "BLOCKED: Managers cannot $TOOL_NAME project source files. Delegate file operations to workers." >&2
        exit 2
      fi
      _dbg_write "allow_manager_taskfile_${TOOL_NAME}"
      exit 0 ;;
  esac
fi

if [ "$TOOL_NAME" != "Bash" ]; then
  if [ "$TOOL_NAME" = "AskUserQuestion" ] && [ -n "$_DOEY_ROLE" ]; then
    _log_block "TOOL_BLOCKED" "$_DOEY_ROLE cannot use AskUserQuestion" "only Boss asks the user"
    _dbg_write "block_ask_user_${_DOEY_ROLE}"
    echo "BLOCKED: Only Boss can ask the user questions directly." >&2
    echo "Send a message to Boss with your question instead:" >&2
    echo '  BOSS_SAFE="${SESSION_NAME//[-:.]/_}_0_1"' >&2
    echo '  printf "FROM: ...\nSUBJECT: question\nQUESTION: ...\n" > "${RUNTIME_DIR}/messages/${BOSS_SAFE}_$(date +%s)_$$.msg"' >&2
    exit 2
  fi
  _dbg_write "allow_non_bash"
  exit 0
fi

# Whitelist: file writes whose CONTENT may contain blocked substrings (e.g. "git commit").
# Redirects to task files, runtime dirs, reports, and /tmp/ dispatch helpers are safe.
_WL_CMD=$(_json_str tool_input.command)
case "${_WL_CMD:-}" in
  *">>"*".doey/tasks/"*.task|*">"*".doey/tasks/"*.task) _dbg_write "allow_task_write"; exit 0 ;;
  *">>"*"/tmp/doey/"*|*">"*"/tmp/doey/"*)              _dbg_write "allow_runtime_write"; exit 0 ;;
  *">>"*"/reports/"*|*">"*"/reports/"*)                 _dbg_write "allow_report_write"; exit 0 ;;
  *">"*"/tmp/"*".sh"*|*">"*"/tmp/"*".md"*)              _dbg_write "allow_tmp_script"; exit 0 ;;
esac

# Manager tmux dispatch: allow safe tmux commands, block destructive ones.
# Must run BEFORE git check — tmux payloads may contain git-related strings.
if [ "$_DOEY_ROLE" = "manager" ] && [ "$TOOL_NAME" = "Bash" ]; then
  _TMUX_CMD=$(_json_str tool_input.command)
  _tmux_stripped=$(echo "$_TMUX_CMD" | sed 's/^[[:space:]]*//')
  case "$_tmux_stripped" in
    "tmux kill-session"*|"tmux kill-server"*|"tmux kill-window"*)
      _log_block "TOOL_BLOCKED" "Manager destructive tmux command blocked" "$_tmux_stripped"
      _dbg_write "block_manager_tmux_destructive"
      echo "BLOCKED: Managers cannot run destructive tmux commands (kill-session/server/window)." >&2
      exit 2 ;;
    "tmux send-keys"*|"tmux load-buffer"*|"tmux paste-buffer"*|\
    "tmux select-pane"*|"tmux list-panes"*|"tmux capture-pane"*|\
    "tmux display-message"*|"tmux copy-mode"*)
      _dbg_write "allow_manager_tmux_dispatch"
      exit 0 ;;
  esac
fi

if [ "$_DOEY_ROLE" != "session_manager" ]; then
  _GIT_CMD=$(_json_str tool_input.command)
  if [ -n "$_GIT_CMD" ] && [ "$_GIT_CMD" != "__PARSE_FAILED__" ]; then
    case "$_GIT_CMD" in
      *"git commit"*|*"git push"*|*"gh pr create"*|*"gh pr merge"*)
        _log_block "TOOL_BLOCKED" "${_DOEY_ROLE:-unknown} git write operation blocked" "$_GIT_CMD"
        _dbg_write "block_git_write_${_DOEY_ROLE:-unknown}"
        if [ "$_DOEY_ROLE" = "worker" ]; then
          _escalate_permission "Bash" "$_GIT_CMD" "git write operations blocked for workers"
          echo "BLOCKED: Git operations are handled by Session Manager. Send a task_complete message to your Manager. Manager notified — it may approve this for you." >&2
        else
          echo "BLOCKED: Git operations are handled by Session Manager. Send a task_complete message to your Manager." >&2
        fi
        exit 2 ;;
    esac
  fi
fi

if [ "$_DOEY_ROLE" = "manager" ] || [ "$_DOEY_ROLE" = "session_manager" ]; then
  _CMD=$(_json_str tool_input.command)
  _CMD=$(echo "$_CMD" | sed 's/^[[:space:]]*//')
  case "$_CMD" in
    "tmux send-keys"*"/rename"*|*"&& tmux send-keys"*"/rename"*|*"; tmux send-keys"*"/rename"*)
      _log_block "TOOL_BLOCKED" "send /rename via send-keys blocked" "opens interactive prompt"
      echo "BLOCKED: Never send /rename via send-keys — it opens an interactive prompt that eats the next paste." >&2
      echo "Use: tmux select-pane -t \"\$PANE\" -T \"task-name\"" >&2
      _dbg_write "block_rename_sendkeys"
      exit 2 ;;
  esac
  # Go build gate: block commits if staged tui/ Go files don't compile
  case "$_CMD" in *"git commit"*)
    _staged_go=$(git diff --cached --name-only 2>/dev/null | grep -c '^tui/' 2>/dev/null) || _staged_go=0
    if [ "$_staged_go" -gt 0 ] 2>/dev/null; then
      _GO_BIN=""
      for _d in /snap/go/current/bin /usr/local/go/bin "$HOME/go/bin"; do
        if [ -x "$_d/go" ]; then _GO_BIN="$_d/go"; break; fi
      done
      if [ -z "$_GO_BIN" ]; then command -v go >/dev/null 2>&1 && _GO_BIN="go"; fi
      if [ -n "$_GO_BIN" ]; then
        _proj_dir="${DOEY_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
        if [ -d "${_proj_dir}/tui" ] && ! (cd "${_proj_dir}/tui" && "$_GO_BIN" build ./...) >/dev/null 2>&1; then
          _build_err=$(cd "${_proj_dir}/tui" && "$_GO_BIN" build ./... 2>&1) || true
          _log_block "TOOL_BLOCKED" "Go build failed — blocking commit" "$_build_err"
          _dbg_write "block_go_build_failed"
          echo "BLOCKED: Go build failed — fix compilation errors before committing:" >&2
          echo "$_build_err" >&2
          exit 2
        fi
      else
        _dbg_write "warn_no_go_binary"
      fi
    fi
  ;; esac
  _dbg_write "allow_manager"
  exit 0
fi

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
    _escalate_permission "Bash" "$TOOL_COMMAND" "Worker blocked: $MSG"
    echo "BLOCKED: Workers cannot run ${MSG}. Only the Window Manager can do this. Manager notified — it may approve this for you." >&2
    exit 2
  fi
  _dbg_write "allow_worker"
  exit 0
fi

source "$(dirname "$0")/common.sh"
init_hook

is_manager && { _dbg_write "allow_manager_slow"; exit 0; }
is_session_manager && { _dbg_write "allow_sm_slow"; exit 0; }
is_boss && { _dbg_write "allow_boss_slow"; exit 0; }

TOOL_COMMAND=$(_json_str tool_input.command)
[ -z "$TOOL_COMMAND" ] && exit 0
[ "$TOOL_COMMAND" = "__PARSE_FAILED__" ] && { echo "BLOCKED: Install jq or python3 — cannot verify Bash command safety." >&2; exit 2; }

if _check_blocked "$TOOL_COMMAND"; then
  _log_block "TOOL_BLOCKED" "worker $MSG blocked" "$TOOL_COMMAND"
  _dbg_write "block_worker"
  _escalate_permission "Bash" "$TOOL_COMMAND" "Worker blocked: $MSG"
  echo "BLOCKED: Workers cannot run ${MSG}. Only the Window Manager can do this. Manager notified — it may approve this for you." >&2
  exit 2
fi
_dbg_write "allow_slow"
exit 0
