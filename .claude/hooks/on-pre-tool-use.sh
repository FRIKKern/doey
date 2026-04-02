#!/usr/bin/env bash
# PreToolUse hook — blocks dangerous commands per role. Hot path: must be fast.
# Exit codes: 0=allow, 2=block. ERR trap prevents accidental cancellation.
set -euo pipefail
trap 'exit 0' ERR

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

# Read key=value from env file (no common.sh — this hook must be self-contained for speed)
_rk() { grep "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }

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
  local _sn="${SESSION_NAME:-}"; [ -z "$_sn" ] && _sn=$(_rk SESSION_NAME "${_rtd}/session.env")
  [ -z "$_sn" ] && return 0
  local _wi="${DOEY_WINDOW_INDEX:-}"; [ -z "$_wi" ] && _wi=$(_rk DOEY_WINDOW_INDEX "${_rtd}/session.env")
  [ -z "$_wi" ] && return 0
  local _mgr_safe; _mgr_safe=$(printf '%s_%s_0' "$_sn" "$_wi" | tr ':.-' '_')
  mkdir -p "${_rtd}/messages" 2>/dev/null || return 0
  printf 'FROM: %s\nSUBJECT: permission_request\nTOOL: %s\nCOMMAND: %.200s\nREASON: %s\nPANE: %s\n' \
    "${_PS:-unknown}" "$_tool" "$_cmd" "$_reason" "${_WP:-unknown}" \
    > "${_rtd}/messages/${_mgr_safe}_$(date +%s)_$$.msg" 2>/dev/null || true
  touch "${_rtd}/triggers/${_mgr_safe}.trigger" 2>/dev/null || true
}

_check_blocked() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
  case "$cmd" in
    *"git commit"*|*"git push"*|*"gh pr create"*|*"gh pr merge"*)
      MSG="git write operations (git commit/push, gh pr). Send a message to ${DOEY_ROLE_COORDINATOR} with what you need committed" ;;
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
_BASH_CMD=""
[ "$TOOL_NAME" = "Bash" ] && _BASH_CMD=$(_json_str tool_input.command)

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

if [ -z "$_DOEY_ROLE" ] && [ -n "${_WP:-}" ] && [ -n "${_RD:-}" ]; then
  _di_wi="${_WP#*:}"; _di_wi="${_di_wi%.*}"
  _di_pi="${_WP##*.}"
  _di_tp=$(_rk TASKMASTER_PANE "${_RD}/session.env")
  _di_ct_win="${_di_tp%%.*}"
  if [ "$_di_wi" = "0" ]; then
    case "$_di_pi" in
      1) _DOEY_ROLE="$DOEY_ROLE_ID_BOSS" ;;
      0) _DOEY_ROLE="info_panel" ;;
      *) [ "0.${_di_pi}" = "${_di_tp:-0.2}" ] && _DOEY_ROLE="$DOEY_ROLE_ID_COORDINATOR" ;;
    esac
  elif [ -n "$_di_ct_win" ] && [ "$_di_wi" = "$_di_ct_win" ]; then
    # Core Team window
    case "$_di_pi" in
      0) _DOEY_ROLE="$DOEY_ROLE_ID_COORDINATOR" ;;
      1) _DOEY_ROLE="$DOEY_ROLE_ID_TASK_REVIEWER" ;;
      2) _DOEY_ROLE="$DOEY_ROLE_ID_DEPLOYMENT" ;;
      3) _DOEY_ROLE="$DOEY_ROLE_ID_DOEY_EXPERT" ;;
    esac
  else
    _di_tt=$(_rk TEAM_TYPE "${_RD}/team_${_di_wi}.env")
    if [ "$_di_tt" != "$DOEY_ROLE_ID_FREELANCER" ]; then
      _di_mp=$(_rk MANAGER_PANE "${_RD}/team_${_di_wi}.env")
      [ "$_di_pi" = "${_di_mp:-0}" ] && _DOEY_ROLE="$DOEY_ROLE_ID_TEAM_LEAD"
    fi
    [ -z "$_DOEY_ROLE" ] && _DOEY_ROLE="$DOEY_ROLE_ID_WORKER"
  fi
fi

if [ -n "${_RD:-}" ] && [ -n "${_PS:-}" ]; then
  _HB_FILE="${_RD}/status/${_PS}.heartbeat"
  _hb_write=true
  if [ -f "$_HB_FILE" ]; then
    _hb_mtime=$(stat -c%Y "$_HB_FILE" 2>/dev/null || stat -f%m "$_HB_FILE" 2>/dev/null || echo 0)
    [ "$(( $(date +%s) - _hb_mtime ))" -lt 10 ] && _hb_write=false
  fi
  [ "$_hb_write" = "true" ] && \
    printf '%s %s %s\n' "$(date +%s)" "${DOEY_TASK_ID:-}" "${DOEY_PANE_ID:-${_PS}}" > "${_HB_FILE}.tmp" && mv "${_HB_FILE}.tmp" "$_HB_FILE"
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

if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] && [ "$TOOL_NAME" = "Bash" ]; then
  _BOSS_CMD="$_BASH_CMD"
  _boss_tm_pane=$(get_taskmaster_pane)
  _boss_tm_safe=$(echo "$_boss_tm_pane" | tr '.' '_')
  case "$_BOSS_CMD" in *"send-keys"*"-t"*)
    _boss_target=$(echo "$_BOSS_CMD" | sed 's/.*send-keys[[:space:]]*-t[[:space:]]*//;s/[[:space:]].*//;s/^"//;s/"$//')
    case "$_boss_target" in
      *:${_boss_tm_pane}|*_${_boss_tm_safe}*|${_boss_tm_pane})
        _dbg_write "allow_boss_sendkeys_coordinator"
        ;; # fall through to boss exit 0
      *)
        _log_block "TOOL_BLOCKED" "${DOEY_ROLE_BOSS} send-keys to non-${DOEY_ROLE_COORDINATOR} pane blocked" "$_BOSS_CMD"
        _dbg_write "block_boss_sendkeys_${_boss_target}"
        echo "BLOCKED: ${DOEY_ROLE_BOSS} may only send-keys to ${DOEY_ROLE_COORDINATOR} pane (${_boss_tm_pane})" >&2
        exit 2 ;;
    esac
  ;; esac
fi

# Scratchpad bypass — all roles may Read/Edit/Write/Glob/Grep inside scratchpad
if [ -n "${_RD:-}" ]; then
  case "$TOOL_NAME" in
    Read|Edit|Write|Glob|Grep)
      _SP_PATH=$(_json_str tool_input.file_path)
      [ -z "$_SP_PATH" ] && _SP_PATH=$(_json_str tool_input.path)
      [ -z "$_SP_PATH" ] && _SP_PATH=$(_json_str tool_input.pattern)
      case "${_SP_PATH:-}" in
        "${_RD}/scratchpad/"*|"${_RD}/scratchpad")
          _dbg_write "allow_scratchpad_${_DOEY_ROLE:-unknown}_${TOOL_NAME}"
          exit 0 ;;
      esac
      ;;
  esac
fi

if { [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] || [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TEAM_LEAD" ] || [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_COORDINATOR" ]; } && [ "$TOOL_NAME" != "Bash" ]; then
  case "$TOOL_NAME" in
    Agent)
      _log_block "TOOL_BLOCKED" "${_DOEY_ROLE} cannot use Agent tool" ""
      _dbg_write "block_${_DOEY_ROLE}_agent"
      case "$_DOEY_ROLE" in
        "$DOEY_ROLE_ID_BOSS") echo "BLOCKED: ${DOEY_ROLE_BOSS} cannot spawn agents. Relay tasks to ${DOEY_ROLE_COORDINATOR} instead." >&2 ;;
        *)    echo "BLOCKED: Managers coordinate — they don't spawn agents. Dispatch to workers instead." >&2 ;;
      esac
      exit 2 ;;
    Read|Edit|Write|Glob|Grep)
      _CHK_PATH=$(_json_str tool_input.file_path)
      [ -z "$_CHK_PATH" ] && _CHK_PATH=$(_json_str tool_input.path)
      [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] && [ -z "$_CHK_PATH" ] && _CHK_PATH=$(_json_str tool_input.pattern)
      case "${_CHK_PATH:-}" in
        */.doey/tasks/*|*/.doey/tasks|\
        "${_RD:-__none__}"/*|*/tmp/doey/*)
          _dbg_write "allow_${_DOEY_ROLE}_taskfile_${TOOL_NAME}"; exit 0 ;;
      esac
      _log_block "TOOL_BLOCKED" "${_DOEY_ROLE} $TOOL_NAME on project source blocked" "${_CHK_PATH:-project root}"
      _dbg_write "block_${_DOEY_ROLE}_source_${TOOL_NAME}"
      case "$_DOEY_ROLE" in
        "$DOEY_ROLE_ID_BOSS")            _advice="Relay file operations to ${DOEY_ROLE_COORDINATOR}" ;;
        "$DOEY_ROLE_ID_COORDINATOR") _advice="Coordinate workers to handle file operations" ;;
        *)               _advice="Delegate file operations to workers" ;;
      esac
      echo "BLOCKED: Cannot $TOOL_NAME project source files. ${_advice}." >&2
      exit 2 ;;
  esac
fi

# Core Team specialists — Agent blocked for all three
if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TASK_REVIEWER" ] || \
   [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_DEPLOYMENT" ] || \
   [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_DOEY_EXPERT" ]; then
  if [ "$TOOL_NAME" = "Agent" ]; then
    _log_block "TOOL_BLOCKED" "${_DOEY_ROLE} cannot use Agent" ""
    _dbg_write "block_${_DOEY_ROLE}_agent"
    echo "BLOCKED: Core Team specialists cannot spawn agents." >&2
    exit 2
  fi
fi

# Task Reviewer: read-only project source + task file updates
if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TASK_REVIEWER" ]; then
  case "$TOOL_NAME" in
    Edit|Write)
      _CHK_PATH=$(_json_str tool_input.file_path)
      case "${_CHK_PATH:-}" in
        */.doey/tasks/*|"${_RD:-__none__}"/*|*/tmp/doey/*) ;; # allow task/runtime files
        *)
          _log_block "TOOL_BLOCKED" "Task Reviewer write blocked" "${_CHK_PATH:-}"
          _dbg_write "block_task_reviewer_write"
          echo "BLOCKED: Task Reviewer is read-only for project source. Only task files can be updated." >&2
          exit 2 ;;
      esac ;;
    Bash)
      case "${_BASH_CMD:-}" in *"tmux send-keys"*)
        _log_block "TOOL_BLOCKED" "Task Reviewer send-keys blocked" "$_BASH_CMD"
        _dbg_write "block_task_reviewer_sendkeys"
        echo "BLOCKED: Task Reviewer cannot use send-keys. Report results via task files." >&2
        exit 2 ;;
      esac ;;
  esac
fi

# Deployment: read-only project source, can run tests + git push/pr
if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_DEPLOYMENT" ]; then
  case "$TOOL_NAME" in
    Edit|Write)
      _CHK_PATH=$(_json_str tool_input.file_path)
      case "${_CHK_PATH:-}" in
        */.doey/tasks/*|"${_RD:-__none__}"/*|*/tmp/doey/*) ;; # allow task/runtime files
        *)
          _log_block "TOOL_BLOCKED" "Deployment write blocked" "${_CHK_PATH:-}"
          _dbg_write "block_deployment_write"
          echo "BLOCKED: Deployment cannot edit project source. Run tests and create PRs instead." >&2
          exit 2 ;;
      esac ;;
  esac
fi

# Doey Expert: can only access Doey source files (shell/, agents/, .claude/, docs/, tests/)
if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_DOEY_EXPERT" ]; then
  case "$TOOL_NAME" in
    Read|Edit|Write|Glob|Grep)
      _CHK_PATH=$(_json_str tool_input.file_path)
      [ -z "$_CHK_PATH" ] && _CHK_PATH=$(_json_str tool_input.path)
      [ "$TOOL_NAME" = "Glob" ] && [ -z "$_CHK_PATH" ] && _CHK_PATH=$(_json_str tool_input.pattern)
      case "${_CHK_PATH:-}" in
        */shell/*|*/agents/*|*/.claude/*|*/docs/*|*/tests/*|*/install.sh|\
        */.doey/*|"${_RD:-__none__}"/*|*/tmp/doey/*|*CLAUDE.md*) ;; # allow Doey source + task/runtime
        *)
          _log_block "TOOL_BLOCKED" "Doey Expert non-Doey access blocked" "${_CHK_PATH:-}"
          _dbg_write "block_doey_expert_${TOOL_NAME}"
          echo "BLOCKED: Doey Expert can only access Doey source files (shell/, agents/, .claude/, docs/, tests/)." >&2
          exit 2 ;;
      esac ;;
  esac
fi

if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ]; then
  _dbg_write "allow_boss"
  exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
  if [ "$TOOL_NAME" = "AskUserQuestion" ] && [ -n "$_DOEY_ROLE" ]; then
    _log_block "TOOL_BLOCKED" "$_DOEY_ROLE cannot use AskUserQuestion" "only ${DOEY_ROLE_BOSS} asks the user"
    _dbg_write "block_ask_user_${_DOEY_ROLE}"
    echo "BLOCKED: Only ${DOEY_ROLE_BOSS} can ask the user questions directly." >&2
    echo "Send a message to ${DOEY_ROLE_BOSS} with your question instead:" >&2
    echo '  BOSS_SAFE="${SESSION_NAME//[-:.]/_}_0_1"' >&2
    echo '  printf "FROM: ...\nSUBJECT: question\nQUESTION: ...\n" > "${RUNTIME_DIR}/messages/${BOSS_SAFE}_$(date +%s)_$$.msg"' >&2
    exit 2
  fi
  _dbg_write "allow_non_bash"
  exit 0
fi

# Whitelist: file writes whose content may contain blocked substrings
case "${_BASH_CMD:-}" in
  *">>"*".doey/tasks/"*.task|*">"*".doey/tasks/"*.task) _dbg_write "allow_task_write"; exit 0 ;;
  *">>"*"/tmp/doey/"*|*">"*"/tmp/doey/"*)              _dbg_write "allow_runtime_write"; exit 0 ;;
  *">>"*"/reports/"*|*">"*"/reports/"*)                 _dbg_write "allow_report_write"; exit 0 ;;
  *">"*"/tmp/"*".sh"*|*">"*"/tmp/"*".md"*)              _dbg_write "allow_tmp_script"; exit 0 ;;
esac

# Manager tmux dispatch (must run BEFORE git check — payloads may contain git strings)
if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TEAM_LEAD" ] && [ "$TOOL_NAME" = "Bash" ]; then
  _tmux_stripped=$(echo "$_BASH_CMD" | sed 's/^[[:space:]]*//')
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

if [ "$_DOEY_ROLE" != "$DOEY_ROLE_ID_COORDINATOR" ] && [ "$_DOEY_ROLE" != "$DOEY_ROLE_ID_DEPLOYMENT" ]; then
  if [ -n "$_BASH_CMD" ] && [ "$_BASH_CMD" != "__PARSE_FAILED__" ]; then
    case "$_BASH_CMD" in
      *"git commit"*|*"git push"*|*"gh pr create"*|*"gh pr merge"*)
        _log_block "TOOL_BLOCKED" "${_DOEY_ROLE:-unknown} git write operation blocked" "$_BASH_CMD"
        _dbg_write "block_git_write_${_DOEY_ROLE:-unknown}"
        if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_WORKER" ]; then
          _escalate_permission "Bash" "$_BASH_CMD" "git write operations blocked for workers"
          echo "BLOCKED: Git operations are handled by ${DOEY_ROLE_COORDINATOR}. Send a task_complete message to your ${DOEY_ROLE_TEAM_LEAD}. ${DOEY_ROLE_TEAM_LEAD} notified — it may approve this for you." >&2
        else
          echo "BLOCKED: Git operations are handled by ${DOEY_ROLE_COORDINATOR}. Send a task_complete message to your ${DOEY_ROLE_TEAM_LEAD}." >&2
        fi
        exit 2 ;;
    esac
  fi
fi

if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TEAM_LEAD" ] || [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_COORDINATOR" ]; then
  _CMD=$(echo "$_BASH_CMD" | sed 's/^[[:space:]]*//')
  case "$_CMD" in
    "tmux send-keys"*"/rename"*|*"&& tmux send-keys"*"/rename"*|*"; tmux send-keys"*"/rename"*)
      _log_block "TOOL_BLOCKED" "send /rename via send-keys blocked" "opens interactive prompt"
      echo "BLOCKED: Never send /rename via send-keys — it opens an interactive prompt that eats the next paste." >&2
      echo "Use: tmux select-pane -t \"\$PANE\" -T \"task-name\"" >&2
      _dbg_write "block_rename_sendkeys"
      exit 2 ;;
  esac
  case "$_CMD" in *"git commit"*)
    _staged_go=$(git diff --cached --name-only 2>/dev/null | grep -c '^tui/' 2>/dev/null) || _staged_go=0
    if [ "$_staged_go" -gt 0 ] 2>/dev/null; then
      _GO_BIN=""
      _project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
      if [ -f "${_project_dir}/shell/doey-go-helpers.sh" ]; then
        source "${_project_dir}/shell/doey-go-helpers.sh" 2>/dev/null || true
        type _find_go_bin >/dev/null 2>&1 && _GO_BIN="$(_find_go_bin)" || true
      fi
      if [ -z "$_GO_BIN" ]; then
        if command -v go >/dev/null 2>&1; then _GO_BIN="go"
        else
          for _d in /usr/local/go/bin /opt/homebrew/bin /snap/go/current/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
            [ -x "$_d/go" ] && { _GO_BIN="$_d/go"; break; }
          done
        fi
      fi
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

  if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_COORDINATOR" ]; then
    case "$_CMD" in
      "tmux send-keys"*|"tmux paste-buffer"*|"tmux load-buffer"*)
        _tgt_window=""
        case "$_CMD" in *":0."*) ;; *":"[0-9]*"."*) _tgt_window="team" ;; esac
        if [ -n "$_tgt_window" ]; then
          _has_active=false
          _task_dir="${DOEY_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.doey/tasks"
          if [ -d "$_task_dir" ]; then
            for _tf in "$_task_dir"/*.task; do
              [ -f "$_tf" ] || continue
              case "$(grep '^TASK_STATUS=' "$_tf" 2>/dev/null | head -1)" in
                *=active|*=in_progress) _has_active=true; break ;;
              esac
            done
          fi
          if [ "$_has_active" = false ]; then
            _log_block "TOOL_BLOCKED" "${DOEY_ROLE_COORDINATOR} dispatch without active .task file" "$_CMD"
            _dbg_write "block_coordinator_no_task"
            echo "BLOCKED: Create a .task file before dispatching work. Without active tasks in .doey/tasks/, ${DOEY_ROLE_COORDINATOR} will be put to sleep by the wait hook." >&2
            exit 2
          fi
        fi ;;
    esac
  fi

  _dbg_write "allow_manager"
  exit 0
fi

if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_WORKER" ]; then
  TOOL_COMMAND="$_BASH_CMD"
  [ -z "$TOOL_COMMAND" ] && exit 0
  [ "$TOOL_COMMAND" = "__PARSE_FAILED__" ] && { echo "BLOCKED: Install jq or python3 — cannot verify Bash command safety." >&2; exit 2; }
  # Exception: workers may send-keys to the coordinator pane
  case "$TOOL_COMMAND" in *"tmux send-keys"*)
    _rtd="${_RD:-${DOEY_RUNTIME:-}}"
    if [ -n "$_rtd" ] && [ -f "${_rtd}/session.env" ]; then
      _taskmaster_pane=$(_rk TASKMASTER_PANE "${_rtd}/session.env"); [ -z "$_taskmaster_pane" ] && _taskmaster_pane="$(get_taskmaster_pane)"
      _sn="${SESSION_NAME:-}"; [ -z "$_sn" ] && _sn=$(_rk SESSION_NAME "${_rtd}/session.env")
      case "$TOOL_COMMAND" in
        *"-t"*"${_sn}:${_taskmaster_pane}"*|*"-t"*"${_taskmaster_pane}"*)
          _dbg_write "allow_worker_sendkeys_taskmaster"; exit 0 ;;
      esac
    fi
  ;; esac
  if _check_blocked "$TOOL_COMMAND"; then
    _log_block "TOOL_BLOCKED" "${DOEY_ROLE_WORKER} $MSG blocked" "$TOOL_COMMAND"
    _dbg_write "block_worker"
    _escalate_permission "Bash" "$TOOL_COMMAND" "${DOEY_ROLE_WORKER} blocked: $MSG"
    echo "BLOCKED: Workers cannot run ${MSG}. Only the ${DOEY_ROLE_TEAM_LEAD} can do this. ${DOEY_ROLE_TEAM_LEAD} notified — it may approve this for you." >&2
    exit 2
  fi
  _dbg_write "allow_worker"
  exit 0
fi

_dbg_write "allow_fallback"
exit 0
