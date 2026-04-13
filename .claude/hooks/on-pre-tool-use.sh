#!/usr/bin/env bash
# PreToolUse hook — blocks dangerous commands per role. Hot path: must be fast.
# Exit codes: 0=allow, 2=block. ERR trap prevents accidental cancellation.
set -euo pipefail
trap 'exit 0' ERR

# Stats emit (task #521 Phase 2) — fire tool_blocked ONLY when the hook
# exits with 2 (DENY). Allow path (exit 0) triggers no emit, ensuring a
# tool-call storm creates zero writes.
# Polling-loop sentinel (task #525/#536) — on allow-path (exit 0), touch
# the sentinel so violation_bump_counter knows real tool work happened.
_doey_stats_on_exit() {
  _doey_exit_code=$?
  if [ "$_doey_exit_code" = "2" ] && command -v doey-stats-emit.sh >/dev/null 2>&1; then
    (doey-stats-emit.sh worker tool_blocked "reason=${_DOEY_BLOCK_REASON:-deny}" &) 2>/dev/null || true
  fi
  if [ "$_doey_exit_code" = "0" ] && [ -n "${_RD:-}" ] && [ -n "${_PS:-}" ]; then
    : > "${_RD}/status/${_PS}.tool_used_this_turn" 2>/dev/null || true
  fi
}
trap '_doey_stats_on_exit' EXIT

# Self-repair: if hooks were deleted (e.g. gitignored + branch switch), re-copy from Doey repo.
# Fast path: skip if common.sh exists (most hooks depend on it, so it's a good canary).
_doey_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ ! -f "${_doey_hook_dir}/common.sh" ]; then
  _doey_repo=""
  if [ -f "${_doey_hook_dir}/../../shell/doey-roles.sh" ]; then
    _doey_repo="$(cd "${_doey_hook_dir}/../.." && pwd)"
  elif [ -f "$HOME/.claude/doey/repo-path" ]; then
    _doey_repo="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null)" || _doey_repo=""
  fi
  if [ -n "$_doey_repo" ] && [ -d "${_doey_repo}/.claude/hooks" ]; then
    cp "${_doey_repo}"/.claude/hooks/*.sh "${_doey_hook_dir}/" 2>/dev/null || true
    chmod +x "${_doey_hook_dir}"/*.sh 2>/dev/null || true
  fi
fi

# Source centralized role definitions — resolve via multiple fallbacks
_DOEY_ROLES_FILE=""
# Method 1: Relative to this hook file (works inside Doey repo)
if [ -f "${_doey_hook_dir}/../../shell/doey-roles.sh" ]; then
    _DOEY_ROLES_FILE="$(cd "${_doey_hook_dir}/../../shell" && pwd)/doey-roles.sh"
fi
# Method 2: Installed copy in ~/.local/bin
if [ -z "$_DOEY_ROLES_FILE" ] && [ -f "$HOME/.local/bin/doey-roles.sh" ]; then
    _DOEY_ROLES_FILE="$HOME/.local/bin/doey-roles.sh"
fi
# Method 3: Repo path from install config
if [ -z "$_DOEY_ROLES_FILE" ] && [ -f "$HOME/.claude/doey/repo-path" ]; then
    _doey_repo="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null)" || _doey_repo=""
    if [ -n "$_doey_repo" ] && [ -f "${_doey_repo}/shell/doey-roles.sh" ]; then
        _DOEY_ROLES_FILE="${_doey_repo}/shell/doey-roles.sh"
    fi
    unset _doey_repo
fi
unset _doey_hook_dir
_DOEY_ROLES_LOADED=false
if [ -n "$_DOEY_ROLES_FILE" ]; then
    source "$_DOEY_ROLES_FILE"
    _DOEY_ROLES_LOADED=true
else
    echo "[doey] WARNING: doey-roles.sh not found — role detection unavailable" >&2
fi

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
  # Bridge to SQLite event system
  if command -v doey-ctl >/dev/null 2>&1; then
    local _proj="${DOEY_PROJECT_DIR:-}"
    [ -z "$_proj" ] && _proj=$(git rev-parse --show-toplevel 2>/dev/null) || true
    if [ -n "$_proj" ]; then
      local _evt_data="role=${_role}|tool=${TOOL_NAME:-n/a}|${detail:-}"
      (doey event log --type "error_hook_block" --source "$_pid" --data "${msg} | ${_evt_data}" --project-dir "$_proj" &) 2>/dev/null
    fi
  fi
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

_forward_action() {
  local _tool="$1" _cmd="$2" _reason="$3" _target_override="${4:-}"
  local _rtd="${_RD:-${DOEY_RUNTIME:-}}"
  [ -z "$_rtd" ] && return 1
  local _sn="${SESSION_NAME:-}"; [ -z "$_sn" ] && _sn=$(_rk SESSION_NAME "${_rtd}/session.env")
  [ -z "$_sn" ] && return 1
  local _wi="${DOEY_WINDOW_INDEX:-}"; [ -z "$_wi" ] && _wi=$(_rk DOEY_WINDOW_INDEX "${_rtd}/session.env")

  # Determine target pane
  local _target_safe=""
  if [ -n "$_target_override" ]; then
    _target_safe="$_target_override"
  else
    local _sn_safe; _sn_safe=$(printf '%s' "$_sn" | tr ':.-' '_')
    case "$_DOEY_ROLE" in
      "$DOEY_ROLE_ID_BOSS")
        _target_safe=$(printf '%s_1_0' "$_sn_safe") ;;
      "$DOEY_ROLE_ID_WORKER")
        [ -z "$_wi" ] && return 1
        _target_safe=$(printf '%s_%s_0' "$_sn_safe" "$_wi") ;;
      "$DOEY_ROLE_ID_COORDINATOR")
        _target_safe=$(printf '%s_2_0' "$_sn_safe") ;;
      "$DOEY_ROLE_ID_TEAM_LEAD")
        _target_safe=$(printf '%s_1_0' "$_sn_safe") ;;
      *)
        [ -z "$_wi" ] && return 1
        _target_safe=$(printf '%s_%s_0' "$_sn_safe" "$_wi") ;;
    esac
  fi
  [ -z "$_target_safe" ] && return 1

  # Check target status — skip if ERROR or RESPAWNING
  if [ -f "${_rtd}/status/${_target_safe}.status" ]; then
    local _tgt_status; _tgt_status=$(cat "${_rtd}/status/${_target_safe}.status" 2>/dev/null) || _tgt_status=""
    case "$_tgt_status" in
      ERROR|RESPAWNING) return 1 ;;
    esac
  fi

  # Build body with structured fields
  local _cmd_trunc; _cmd_trunc=$(printf '%.500s' "$_cmd")
  local _body; _body=$(printf 'ACTION_TYPE: %s\nTOOL: %s\nCOMMAND: %s\nREQUESTER_PANE: %s\nREASON: %s' \
    "$_reason" "$_tool" "$_cmd_trunc" "${_WP:-unknown}" "$_reason")
  if [ -n "${DOEY_TASK_ID:-}" ]; then
    _body=$(printf '%s\nTASK_ID: %s' "$_body" "$DOEY_TASK_ID")
  fi

  # Try doey-ctl msg send first
  if command -v doey-ctl >/dev/null 2>&1; then
    if doey-ctl msg send \
      --from "${_PS:-unknown}" \
      --to "$_target_safe" \
      --subject "action_request" \
      --body "$_body" \
      --runtime "$_rtd" \
      --no-nudge 2>/dev/null; then
      touch "${_rtd}/triggers/${_target_safe}.trigger" 2>/dev/null || true
      return 0
    fi
  fi

  # Fallback: file-based IPC
  mkdir -p "${_rtd}/messages" 2>/dev/null || return 1
  printf 'FROM: %s\nSUBJECT: action_request\n%s\n' \
    "${_PS:-unknown}" "$_body" \
    > "${_rtd}/messages/${_target_safe}_$(date +%s)_$$.msg" 2>/dev/null || return 1
  touch "${_rtd}/triggers/${_target_safe}.trigger" 2>/dev/null || true
  return 0
}

_check_vcs_segments() {
  # Helper: reads newline-delimited segments from stdin, returns 0 if any is a VCS write command.
  # Extracted to work around bash 3.2 parser bug: case-in-while-in-$() fails because
  # the parser confuses case pattern ')' with the command substitution closing ')'.
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//; s/^[A-Z_][A-Z_0-9]*=[^[:space:]]* *//')
    case "$seg" in
      git\ commit*|git\ push*|gh\ pr\ create*|gh\ pr\ merge*) return 0 ;;
    esac
  done
  return 1
}

_is_direct_vcs_cmd() {
  local cmd="$1"
  # Strip heredoc bodies so VCS keywords in data content don't false-positive.
  # e.g. cat <<'EOF'\nrun git push && deploy\nEOF  (task #141)
  local cleaned
  case "$cmd" in
    *"<<"*)
      cleaned=$(printf '%s\n' "$cmd" | awk '
        BEGIN{s=0;d=""}
        s{t=$0;gsub(/^[[:space:]]+/,"",t);if(t==d)s=0;next}
        /<</{
          i=index($0,"<<")
          if(i>0){
            r=substr($0,i+2);gsub(/^-?[[:space:]]*/,"",r)
            rc=r;gsub(/^["'"'"'\\]?/,"",rc)
            if(match(rc,/^[A-Za-z_][A-Za-z_0-9]*/)){
              d=substr(rc,RSTART,RLENGTH);s=1
              tail=substr(rc,RSTART+RLENGTH)
              sub(/^["'"'"'\\]?/,"",tail)
              print substr($0,1,i-1) tail;next
            }
          }
        }
        {print}
      ' | tr '\n' ';')
      ;;
    *)
      cleaned=$(printf '%s' "$cmd" | tr '\n' ';')
      ;;
  esac
  # Strip quoted strings
  cleaned=$(printf '%s' "$cleaned" | sed "s/\"[^\"]*\"//g; s/'[^']*'//g")
  # Split on chain operators, check if any segment starts with a VCS command
  printf '%s\n' "$cleaned" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g' | _check_vcs_segments
}

_check_blocked() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
  # Use segment-based check for VCS commands (avoids false positives from heredocs/payloads)
  if _is_direct_vcs_cmd "$cmd"; then
    MSG="git write operations (git commit/push, gh pr). Send a message to ${DOEY_ROLE_COORDINATOR} with what you need committed"
    return 0
  fi
  case "$cmd" in
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

# Check staged files for credentials/secrets before git commit.
# Universal — applies to ALL roles with no exceptions.
_check_staged_credentials() {
  local staged_files
  staged_files=$(git diff --cached --name-only 2>/dev/null) || return 0
  [ -z "$staged_files" ] && return 0

  local found_issue=false
  local matched_file="" matched_desc="" matched_line=""

  # Check filenames for dangerous patterns
  local fname base_name
  while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    base_name="${fname##*/}"
    case "$base_name" in
      .env|credentials.json|id_rsa|id_ed25519|id_dsa)
        matched_file="$fname"; matched_desc="sensitive filename ($base_name)"; found_issue=true; break ;;
      *.key|*_key.pem)
        matched_file="$fname"; matched_desc="private key file ($base_name)"; found_issue=true; break ;;
      .env.*)
        # Allow safe templates
        case "$base_name" in
          .env.example|.env.sample|.env.template) ;;
          *) matched_file="$fname"; matched_desc="environment file ($base_name)"; found_issue=true; break ;;
        esac ;;
    esac
  done <<EOF
$staged_files
EOF

  if [ "$found_issue" = "true" ]; then
    echo "BLOCKED: Potential secret detected in staged files" >&2
    echo "  File: $matched_file" >&2
    echo "  Match: $matched_desc" >&2
    echo "Remove the secret or add the file to .gitignore." >&2
    return 1
  fi

  # Check staged content for secret patterns
  local diff_content
  diff_content=$(git diff --cached 2>/dev/null) || return 0
  [ -z "$diff_content" ] && return 0

  # Filter to added lines only, skip safe files and comments
  local added_lines
  added_lines=$(echo "$diff_content" | grep '^+[^+]' | grep -v '^+++' || true)
  [ -z "$added_lines" ] && return 0

  # Remove comment lines
  added_lines=$(echo "$added_lines" | grep -v '^+[[:space:]]*#' || true)
  [ -z "$added_lines" ] && return 0

  # Check each secret pattern
  local patterns
  patterns="sk-ant-[a-zA-Z0-9]"
  patterns="${patterns}|sk-[a-zA-Z0-9]{20,}"
  patterns="${patterns}|ANTHROPIC_API_KEY=.+"
  patterns="${patterns}|OPENAI_API_KEY=.+"
  patterns="${patterns}|AKIA[0-9A-Z]{16}"
  patterns="${patterns}|aws_secret_access_key"
  patterns="${patterns}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY"
  patterns="${patterns}|(token|TOKEN|bearer|Bearer)[=: ]+[a-zA-Z0-9+/]{20,}"
  patterns="${patterns}|(password|passwd|PASSWORD)=[^\$[:space:]]{4,}"
  patterns="${patterns}|(secret|SECRET|client_secret)=[^\$[:space:]]{4,}"

  local hit
  hit=$(echo "$added_lines" | grep -E "$patterns" | head -1 || true)
  [ -z "$hit" ] && return 0

  # Strip leading + from diff
  hit="${hit##+}"

  # Check for placeholder values — skip if found
  local lower_hit
  lower_hit=$(echo "$hit" | tr '[:upper:]' '[:lower:]')
  case "$lower_hit" in
    *"placeholder"*|*"xxx"*|*"changeme"*|*"your-key-here"*|*"todo"*|*"replace_me"*) return 0 ;;
  esac
  # Skip template variable references
  case "$hit" in
    *'${'*|*'<'*) return 0 ;;
  esac

  # Check that the match is not in a safe file (test/docs/example files)
  local safe_file=false diff_file
  diff_file=$(echo "$diff_content" | grep '^+++ b/' | tail -1 || true)
  diff_file="${diff_file##+++ b/}"
  case "$diff_file" in
    test/*|tests/*|docs/*|*.md|*.env.example|*.env.sample|*.env.template)
      safe_file=true ;;
  esac

  if [ "$safe_file" = "true" ]; then
    return 0
  fi

  # Truncate the match for display
  local display_hit
  if [ "${#hit}" -gt 80 ]; then
    display_hit="${hit:0:77}..."
  else
    display_hit="$hit"
  fi

  echo "BLOCKED: Potential secret detected in staged files" >&2
  echo "  File: ${diff_file:-unknown}" >&2
  echo "  Match: secret pattern in content" >&2
  echo "  Line: $display_hit" >&2
  echo "Remove the secret or add the file to .gitignore." >&2
  return 1
}

_save_screenshot_attachment() {
  local file_path="$1"
  [ -z "$file_path" ] && return 0
  # Check image extension (case-insensitive via both cases)
  local ext="${file_path##*.}"
  case "$ext" in
    png|jpg|jpeg|gif|webp|bmp|PNG|JPG|JPEG|GIF|WEBP|BMP) ;;
    *) return 0 ;;
  esac
  # Need runtime dir and project dir
  local runtime_dir="${_RD:-${DOEY_RUNTIME:-}}"
  [ -z "$runtime_dir" ] && return 0
  local project_dir="${DOEY_PROJECT_DIR:-}"
  if [ -z "$project_dir" ]; then
    project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || true
  fi
  [ -z "$project_dir" ] && return 0
  # File must exist
  [ -f "$file_path" ] || return 0
  # Look up active task ID
  local pane_safe="${_PS:-}"
  [ -z "$pane_safe" ] && return 0
  local task_id=""
  if [ -f "${runtime_dir}/status/${pane_safe}.task_id" ]; then
    task_id=$(cat "${runtime_dir}/status/${pane_safe}.task_id" 2>/dev/null) || true
  fi
  [ -z "$task_id" ] && return 0
  # Create attachments dir
  local attach_dir="${project_dir}/.doey/tasks/${task_id}/attachments"
  mkdir -p "$attach_dir" 2>/dev/null || return 0
  local basename="${file_path##*/}"
  local name_no_ext="${basename%.*}"
  local timestamp
  timestamp=$(date +%s)
  # Skip if same basename already exists in attachments
  if ls "$attach_dir"/*"_screenshot_${basename}" >/dev/null 2>&1; then
    return 0
  fi
  # Copy image
  cp "$file_path" "${attach_dir}/${timestamp}_screenshot_${basename}" 2>/dev/null || return 0
  # Create sidecar .md file
  local sidecar="${attach_dir}/${timestamp}_screenshot_${name_no_ext}.md"
  local author="${DOEY_ROLE:-${_DOEY_ROLE:-user}}"
  cat > "$sidecar" <<SIDECAR_EOF
---
type: screenshot
title: ${name_no_ext}
author: ${author}
timestamp: ${timestamp}
task_id: ${task_id}
image_path: attachments/${timestamp}_screenshot_${basename}
---

Screenshot captured from: ${file_path}
SIDECAR_EOF
  # Update TASK_ATTACHMENTS in .task file
  local task_file="${project_dir}/.doey/tasks/${task_id}.task"
  if [ -f "$task_file" ]; then
    local current
    current=$(grep '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null | head -1 | cut -d= -f2-) || current=""
    # Skip if already recorded
    case "|${current}|" in *"|${sidecar}|"*) return 0 ;; esac
    local new_val="${sidecar}"
    [ -n "$current" ] && new_val="${current}|${sidecar}"
    local tmp_task="${task_file}.tmp.$$"
    if grep -q '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null; then
      sed "s|^TASK_ATTACHMENTS=.*|TASK_ATTACHMENTS=${new_val}|" "$task_file" > "$tmp_task" && mv "$tmp_task" "$task_file"
    else
      cp "$task_file" "$tmp_task" && printf 'TASK_ATTACHMENTS=%s\n' "$new_val" >> "$tmp_task" && mv "$tmp_task" "$task_file"
    fi
  fi
  return 0
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
      *) [ "${_di_wi}.${_di_pi}" = "${_di_tp:-1.0}" ] && _DOEY_ROLE="$DOEY_ROLE_ID_COORDINATOR" ;;
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

# Read custom team role for fine-grained whitelisting
_DOEY_TEAM_ROLE="${DOEY_TEAM_ROLE:-}"
if [ -z "$_DOEY_TEAM_ROLE" ] && [ -n "${_RD:-}" ] && [ -n "${_PS:-}" ]; then
  [ -f "${_RD}/status/${_PS}.team_role" ] && _DOEY_TEAM_ROLE=$(cat "${_RD}/status/${_PS}.team_role" 2>/dev/null) || true
fi

# Planner sub-role detection (team_role-based, mirrors interviewer pattern)
_IS_PLANNER=false
case "${_DOEY_TEAM_ROLE:-}" in
  planner) _IS_PLANNER=true ;;
esac

if [ -n "${_RD:-}" ] && [ -n "${_PS:-}" ]; then
  _HB_FILE="${_RD}/status/${_PS}.heartbeat"
  _hb_write=true
  if [ -f "$_HB_FILE" ]; then
    _hb_mtime=$(stat -c%Y "$_HB_FILE" 2>/dev/null || stat -f%m "$_HB_FILE" 2>/dev/null || echo 0)
    [ "$(( $(date +%s) - _hb_mtime ))" -lt 10 ] && _hb_write=false
  fi
  [ "$_hb_write" = "true" ] && \
    printf '%s %s %s\n' "$(date +%s)" "${DOEY_TASK_ID:-}" "${DOEY_PANE_ID:-${_PS}}" > "${_HB_FILE}.tmp" && mv "${_HB_FILE}.tmp" "$_HB_FILE"
  # Update status file with LAST_ACTIVITY and TOOL for live monitoring
  if [ "$_hb_write" = "true" ]; then
    _sf="${_RD}/status/${_PS}.status"
    if [ -f "$_sf" ]; then
      _now=$(date +%s)
      grep -v '^LAST_ACTIVITY: \|^TOOL: ' "$_sf" > "${_sf}.tmp" 2>/dev/null || cp "$_sf" "${_sf}.tmp"
      printf 'LAST_ACTIVITY: %s\nTOOL: %s\n' "$_now" "$TOOL_NAME" >> "${_sf}.tmp"
      mv "${_sf}.tmp" "$_sf"
    fi
  fi
fi

# Universal credential check — applies to ALL roles, no exceptions
if [ "$TOOL_NAME" = "Bash" ] && echo "$_BASH_CMD" | grep -q "git commit"; then
  if _check_staged_credentials; then
    : # clean, continue
  else
    exit 2
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

# Fail-closed: if role constants are unavailable but we're in a Doey session, block
if [ "$_DOEY_ROLES_LOADED" != "true" ] && [ -n "${_DOEY_ROLE:-}" ]; then
  echo "BLOCKED: Role constants unavailable — blocking tool for safety. Source doey-roles.sh." >&2
  exit 2
fi

# Info Panel (pane 0.0) runs shell scripts only — no role-based guards apply.
# Early exit prevents fall-through to worker guards at the bottom of this file.
if [ "$_DOEY_ROLE" = "info_panel" ]; then
  _dbg_write "allow_info_panel"
  exit 0
fi

if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] && [ "$TOOL_NAME" = "Bash" ]; then
  _BOSS_CMD="$_BASH_CMD"
  _boss_tm_pane="${DOEY_TASKMASTER_PANE:-1.0}"
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
        _forward_action "Bash" "$_BOSS_CMD" "send-keys relay" || true
        echo "FORWARDED: Command relay request sent to ${DOEY_ROLE_COORDINATOR}." >&2
        exit 2 ;;
    esac
  ;; esac
  # capture-pane: allow ALL panes (read-only observation)
  case "$_BOSS_CMD" in *"capture-pane"*)
    _dbg_write "allow_boss_capturepane"
    ;; # fall through to boss exit 0
  esac
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

# Screenshot auto-save — capture image reads as task attachments (side-effect only, never blocks)
if [ "$TOOL_NAME" = "Read" ]; then
  _ss_fp="${_SP_PATH:-$(_json_str tool_input.file_path)}"
  _save_screenshot_attachment "${_ss_fp:-}" || true
fi

if { [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] || [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TEAM_LEAD" ] || [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_COORDINATOR" ]; } && [ "$TOOL_NAME" != "Bash" ]; then
  case "$TOOL_NAME" in
    Agent)
      # Interviewer (team_lead with team_role=interviewer) may spawn agents for research
      if [ "${_DOEY_TEAM_ROLE:-}" = "interviewer" ]; then
        _dbg_write "allow_interviewer_agent"
        exit 0
      fi
      _log_block "TOOL_BLOCKED" "${_DOEY_ROLE} cannot use Agent tool" ""
      _dbg_write "block_${_DOEY_ROLE}_agent"
      _agent_desc=$(_json_str tool_input.description)
      _agent_prompt=$(_json_str tool_input.prompt)
      _agent_cmd="${_agent_desc:+[${_agent_desc}] }${_agent_prompt:-}"
      _forward_action "Agent" "$_agent_cmd" "agent spawn" || true
      echo "FORWARDED: Agent spawn request sent to ${DOEY_ROLE_COORDINATOR}." >&2
      exit 2 ;;
    Read|Edit|Write|Glob|Grep)
      _CHK_PATH=$(_json_str tool_input.file_path)
      [ -z "$_CHK_PATH" ] && _CHK_PATH=$(_json_str tool_input.path)
      [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] && [ -z "$_CHK_PATH" ] && _CHK_PATH=$(_json_str tool_input.pattern)
      # Boss can Read image files at any path (screenshots, attachments)
      if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_BOSS" ] && [ "$TOOL_NAME" = "Read" ]; then
        case "${_CHK_PATH:-}" in
          *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.bmp|*.ico|*.pdf)
            _dbg_write "allow_boss_read_image"
            exit 0 ;;
        esac
      fi
      case "${_CHK_PATH:-}" in
        */.doey/tasks/*|*/.doey/tasks|\
        */.doey/plans/*|*/.doey/plans|\
        "${_RD:-__none__}"/*|*/tmp/doey/*)
          _dbg_write "allow_${_DOEY_ROLE}_taskfile_${TOOL_NAME}"; exit 0 ;;
      esac
      _log_block "TOOL_BLOCKED" "${_DOEY_ROLE} $TOOL_NAME on project source blocked" "${_CHK_PATH:-project root}"
      _dbg_write "block_${_DOEY_ROLE}_source_${TOOL_NAME}"
      _fwd_detail="${_CHK_PATH:-}"
      if [ "$TOOL_NAME" = "Grep" ]; then
        _grep_pat=$(_json_str tool_input.pattern)
        [ -n "$_grep_pat" ] && _fwd_detail="${_CHK_PATH:-} (pattern: ${_grep_pat})"
      fi
      _forward_action "$TOOL_NAME" "$_fwd_detail" "source access" || true
      echo "FORWARDED: Source access request sent to ${DOEY_ROLE_COORDINATOR}. Continue with other work." >&2
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

# ── Universal git safety: force-push, main-branch push, --no-verify ──────
# Applies to ALL roles before any early exits
if [ "$TOOL_NAME" = "Bash" ] && [ -n "${_BASH_CMD:-}" ] && [ "$_BASH_CMD" != "__PARSE_FAILED__" ]; then
  # Clean command: strip heredoc bodies + quoted strings (mirrors _is_direct_vcs_cmd)
  _gsafe="${_BASH_CMD}"
  case "$_gsafe" in
    *"<<"*)
      _gsafe=$(printf '%s\n' "$_gsafe" | awk '
        BEGIN{s=0;d=""}
        s{t=$0;gsub(/^[[:space:]]+/,"",t);if(t==d)s=0;next}
        /<</{
          i=index($0,"<<")
          if(i>0){
            r=substr($0,i+2);gsub(/^-?[[:space:]]*/,"",r)
            rc=r;gsub(/^["'"'"'\\]?/,"",rc)
            if(match(rc,/^[A-Za-z_][A-Za-z_0-9]*/)){
              d=substr(rc,RSTART,RLENGTH);s=1
              print substr($0,1,i-1);next
            }
          }
        }
        {print}
      ' | tr '\n' ';') ;;
    *)
      _gsafe=$(printf '%s' "$_gsafe" | tr '\n' ';') ;;
  esac
  _gsafe=$(printf '%s' "$_gsafe" | sed "s/\"[^\"]*\"//g; s/'[^']*'//g")
  case "$_gsafe" in
    *"git push"*"--force"*|*"git push"*"--force-with-lease"*)
      _log_block "TOOL_BLOCKED" "Force push blocked" "$_BASH_CMD"
      _dbg_write "block_force_push"
      echo "Force push blocked. Use normal push." >&2
      exit 2 ;;
  esac
  case "$_gsafe" in
    *"git push"*" main"*|*"git push"*" master"*|*"git push"*":main"*|*"git push"*":master"*)
      if [ "${_DOEY_ROLE:-}" != "$DOEY_ROLE_ID_DEPLOYMENT" ]; then
        _log_block "TOOL_BLOCKED" "Direct push to main/master blocked" "$_BASH_CMD"
        _dbg_write "block_push_main"
        echo "Direct push to main/master blocked. Use a feature branch." >&2
        exit 2
      fi
      _dbg_write "allow_deployment_push_main" ;;
  esac
  case "$_gsafe" in
    *"git "*"--no-verify"*)
      _log_block "TOOL_BLOCKED" "--no-verify flag blocked" "$_BASH_CMD"
      _dbg_write "block_no_verify"
      echo "The --no-verify flag is not allowed." >&2
      exit 2 ;;
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
  # Desktop notification when Boss asks user a question
  if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
    if command -v osascript >/dev/null 2>&1; then
      osascript -e 'display notification "Boss has a question for you" with title "Doey — Question" sound name "Ping"' 2>/dev/null &
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "Doey — Question" "Boss has a question for you" 2>/dev/null &
    fi
  fi
  _dbg_write "allow_boss"
  exit 0
fi

# Interviewer role can ask user questions directly (interview protocol requires it)
if [ "$TOOL_NAME" = "AskUserQuestion" ] && [ "${_DOEY_TEAM_ROLE:-}" = "interviewer" ]; then
  _dbg_write "allow_interviewer_ask_user"
  exit 0
fi

# Planner role can ask user questions directly (consensus loop clarifications)
if [ "$TOOL_NAME" = "AskUserQuestion" ] && [ "${_IS_PLANNER:-false}" = "true" ]; then
  _dbg_write "allow_planner_ask_user"
  exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
  if [ "$TOOL_NAME" = "AskUserQuestion" ] && [ -n "$_DOEY_ROLE" ]; then
    _log_block "TOOL_BLOCKED" "$_DOEY_ROLE cannot use AskUserQuestion" "only ${DOEY_ROLE_BOSS} asks the user"
    _dbg_write "block_ask_user_${_DOEY_ROLE}"
    _sn_ask="${SESSION_NAME:-}"; [ -z "$_sn_ask" ] && _sn_ask=$(_rk SESSION_NAME "${_RD:-}/session.env")
    _boss_safe=$(printf '%s_0_1' "$(printf '%s' "$_sn_ask" | tr ':.-' '_')")
    _ask_question=$(_json_str tool_input.question)
    _forward_action "AskUserQuestion" "$_ask_question" "user question" "$_boss_safe" || true
    echo "FORWARDED: Question forwarded to Boss for user interaction." >&2
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
      # --- Team-boundary guard: Subtaskmaster can only target own window, Dashboard, or Coordinator ---
      _tl_target=$(echo "$_tmux_stripped" | sed 's/.*[[:space:]]-t[[:space:]]*//;s/[[:space:]].*//;s/^"//;s/"$//')
      if [ -n "$_tl_target" ] && [ "$_tl_target" != "$_tmux_stripped" ]; then
        # Extract target window index (handle session:W.P or W.P)
        _tl_tgt_wp="$_tl_target"
        case "$_tl_tgt_wp" in *:*) _tl_tgt_wp="${_tl_tgt_wp#*:}" ;; esac
        _tl_tgt_wi="${_tl_tgt_wp%%.*}"
        # Sender window index
        _tl_my_wi="${DOEY_WINDOW_INDEX:-}"
        if [ -z "$_tl_my_wi" ] && [ -n "${_WP:-}" ]; then
          _tl_my_wp="${_WP#*:}"; _tl_my_wi="${_tl_my_wp%%.*}"
        fi
        # Coordinator window
        _tl_coord_pane="${DOEY_TASKMASTER_PANE:-1.0}"
        _tl_coord_wi="${_tl_coord_pane%%.*}"
        # Check boundary: own window, Dashboard (0), or Coordinator window
        if [ -n "$_tl_my_wi" ] && [ "$_tl_tgt_wi" != "$_tl_my_wi" ] && [ "$_tl_tgt_wi" != "0" ] && [ "$_tl_tgt_wi" != "$_tl_coord_wi" ]; then
          # Extract tmux subcommand
          _tl_subcmd="${_tmux_stripped#tmux }"; _tl_subcmd="${_tl_subcmd%% *}"
          case "$_tl_subcmd" in
            send-keys|paste-buffer|load-buffer)
              _log_block "TOOL_BLOCKED" "${DOEY_ROLE_TEAM_LEAD} cross-team dispatch to window ${_tl_tgt_wi} blocked (own: ${_tl_my_wi})" "$_tmux_stripped"
              _dbg_write "block_team_lead_cross_team_${_tl_tgt_wi}"
              echo "BLOCKED: ${DOEY_ROLE_TEAM_LEAD} cannot send-keys/dispatch outside own team window ${_tl_my_wi}. Target window ${_tl_tgt_wi} is out of scope. Route through ${DOEY_ROLE_COORDINATOR}." >&2
              exit 2 ;;
            *) _dbg_write "allow_team_lead_readonly_cross_team_${_tl_subcmd}" ;;
          esac
        fi
        # Check reserved pane
        _tl_tgt_safe=$(echo "$_tl_target" | tr ':.-' '___')
        # Prepend session name if target does not include one
        case "$_tl_target" in *:*) ;; *)
          _tl_sn="${SESSION_NAME:-}"; [ -z "$_tl_sn" ] && _tl_sn=$(_rk SESSION_NAME "${_RD:-}/session.env")
          [ -n "$_tl_sn" ] && _tl_tgt_safe=$(echo "${_tl_sn}:${_tl_target}" | tr ':.-' '___')
        ;; esac
        if [ -f "${_RD:-}/status/${_tl_tgt_safe}.reserved" ]; then
          _tl_subcmd2="${_tmux_stripped#tmux }"; _tl_subcmd2="${_tl_subcmd2%% *}"
          case "$_tl_subcmd2" in
            send-keys|paste-buffer|load-buffer)
              _log_block "TOOL_BLOCKED" "${DOEY_ROLE_TEAM_LEAD} dispatch to reserved pane ${_tl_target} blocked" "$_tmux_stripped"
              _dbg_write "block_team_lead_reserved_pane_${_tl_tgt_safe}"
              echo "BLOCKED: Target pane ${_tl_target} is reserved. Cannot dispatch to reserved panes." >&2
              exit 2 ;;
          esac
        fi
      fi
      _dbg_write "allow_manager_tmux_dispatch"
      exit 0 ;;
  esac
fi

if [ "$_DOEY_ROLE" != "$DOEY_ROLE_ID_DEPLOYMENT" ]; then
  if [ -n "$_BASH_CMD" ] && [ "$_BASH_CMD" != "__PARSE_FAILED__" ]; then
    # Fast-path: skip VCS check for TEAM_LEAD/COORDINATOR tmux dispatch
    _skip_vcs=false
    if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_TEAM_LEAD" ] || [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_COORDINATOR" ]; then
      case "$_BASH_CMD" in
        *"tmux send-keys"*|*"tmux load-buffer"*|*"tmux paste-buffer"*) _skip_vcs=true ;;
      esac
    fi
    # Freelancers are independent workers — allow direct VCS access
    if [ "$_skip_vcs" = "false" ] && [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_WORKER" ]; then
      _fl_tt="${DOEY_TEAM_TYPE:-}"
      if [ -z "$_fl_tt" ] && [ -n "${_RD:-}" ] && [ -n "${_WP:-}" ]; then
        _fl_wi="${_WP#*:}"; _fl_wi="${_fl_wi%.*}"
        _fl_tt=$(_rk TEAM_TYPE "${_RD}/team_${_fl_wi}.env")
      fi
      [ "$_fl_tt" = "$DOEY_ROLE_ID_FREELANCER" ] && _skip_vcs=true
    fi
    if [ "$_skip_vcs" = "true" ]; then
      _dbg_write "skip_vcs_team_lead_tmux_dispatch"
    elif _is_direct_vcs_cmd "$_BASH_CMD"; then
      _log_block "TOOL_BLOCKED" "${_DOEY_ROLE:-unknown} git write operation blocked" "$_BASH_CMD"
      _dbg_write "block_git_write_${_DOEY_ROLE:-unknown}"
      if [ "$_DOEY_ROLE" = "$DOEY_ROLE_ID_WORKER" ]; then
        _forward_action "Bash" "$_BASH_CMD" "git write operations blocked for workers" || true
        echo "FORWARDED: VCS request sent to ${DOEY_ROLE_TEAM_LEAD}. Continue with other work." >&2
      else
        _forward_action "Bash" "$_BASH_CMD" "VCS operations" || true
        echo "FORWARDED: VCS request sent to ${DOEY_ROLE_COORDINATOR}. Continue with other work." >&2
      fi
      exit 2
    fi
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
        # --- Reserved-team guard: Coordinator cannot dispatch to reserved team worker panes ---
        if [ "$_tgt_window" = "team" ]; then
          _coord_tgt=$(echo "$_CMD" | sed 's/.*[[:space:]]-t[[:space:]]*//;s/[[:space:]].*//;s/^"//;s/"$//')
          _coord_tgt_wp="$_coord_tgt"
          case "$_coord_tgt_wp" in *:*) _coord_tgt_wp="${_coord_tgt_wp#*:}" ;; esac
          _coord_tgt_wi="${_coord_tgt_wp%%.*}"
          _coord_tgt_pi="${_coord_tgt_wp#*.}"
          _coord_team_env="${_RD:-}/team_${_coord_tgt_wi}.env"
          if [ -f "$_coord_team_env" ]; then
            _coord_reserved=$(_rk RESERVED "$_coord_team_env")
            if [ "$_coord_reserved" = "true" ] && [ "$_coord_tgt_pi" != "0" ]; then
              _log_block "TOOL_BLOCKED" "${DOEY_ROLE_COORDINATOR} dispatch to reserved team window ${_coord_tgt_wi} blocked" "$_CMD"
              _dbg_write "block_coordinator_reserved_team_${_coord_tgt_wi}"
              echo "BLOCKED: Team window ${_coord_tgt_wi} is reserved. Cannot dispatch to reserved worker panes. Route through the team ${DOEY_ROLE_TEAM_LEAD}." >&2
              exit 2
            fi
          fi
        fi
        if [ -n "$_tgt_window" ]; then
          _has_active=false
          _task_pd="${DOEY_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
          if command -v doey-ctl >/dev/null 2>&1 && [ -n "$_task_pd" ]; then
            _ac=$(doey-ctl task list --status active --project-dir "$_task_pd" 2>/dev/null | awk 'NR>1 && /^[0-9]/{found=1} END{print found+0}')
            _ic=$(doey-ctl task list --status in_progress --project-dir "$_task_pd" 2>/dev/null | awk 'NR>1 && /^[0-9]/{found=1} END{print found+0}')
            [ "$((_ac + _ic))" -gt 0 ] && _has_active=true
          elif [ -d "${_task_pd}/.doey/tasks" ]; then
            for _tf in "${_task_pd}"/.doey/tasks/*.task; do
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
  # Block Write on existing report files (append-only)
  case "$TOOL_NAME" in
    Write)
      _CHK_PATH=$(_json_str tool_input.file_path)
      case "${_CHK_PATH:-}" in
        */reports/*.report)
          if [ -f "$_CHK_PATH" ]; then
            _dbg_write "block_worker_write_existing_report"
            _log_block "TOOL_BLOCKED" "Write to existing report file" "${_CHK_PATH:-}"
            echo "Report files are append-only. Use the Edit tool to append new sections instead of Write, which overwrites the entire file." >&2
            exit 2
          fi ;;
      esac ;;
  esac
  TOOL_COMMAND="$_BASH_CMD"
  [ -z "$TOOL_COMMAND" ] && exit 0
  [ "$TOOL_COMMAND" = "__PARSE_FAILED__" ] && { echo "BLOCKED: Install jq or python3 — cannot verify Bash command safety." >&2; exit 2; }
  # Exception: workers may send-keys to the coordinator pane
  case "$TOOL_COMMAND" in *"tmux send-keys"*)
    _rtd="${_RD:-${DOEY_RUNTIME:-}}"
    if [ -n "$_rtd" ] && [ -f "${_rtd}/session.env" ]; then
      _taskmaster_pane=$(_rk TASKMASTER_PANE "${_rtd}/session.env"); [ -z "$_taskmaster_pane" ] && _taskmaster_pane="${DOEY_TASKMASTER_PANE:-1.0}"
      _sn="${SESSION_NAME:-}"; [ -z "$_sn" ] && _sn=$(_rk SESSION_NAME "${_rtd}/session.env")
      case "$TOOL_COMMAND" in
        *"-t"*"${_sn}:${_taskmaster_pane}"*|*"-t"*"${_taskmaster_pane}"*)
          _dbg_write "allow_worker_sendkeys_taskmaster"; exit 0 ;;
      esac
    fi
  ;; esac
  # Freelancers (managerless workers) have direct VCS access — no Subtaskmaster to handle it
  if [ "${DOEY_TEAM_TYPE:-}" = "freelancer" ] && _is_direct_vcs_cmd "$TOOL_COMMAND"; then
    _dbg_write "allow_freelancer_vcs"; exit 0
  fi
  if _check_blocked "$TOOL_COMMAND"; then
    _log_block "TOOL_BLOCKED" "${DOEY_ROLE_WORKER} $MSG blocked" "$TOOL_COMMAND"
    _dbg_write "block_worker"
    _forward_action "Bash" "$TOOL_COMMAND" "${DOEY_ROLE_WORKER} blocked: $MSG" || true
    echo "FORWARDED: Request sent to ${DOEY_ROLE_TEAM_LEAD}. Continue with other work." >&2
    exit 2
  fi
  _dbg_write "allow_worker"
  exit 0
fi

_dbg_write "allow_fallback"
exit 0
