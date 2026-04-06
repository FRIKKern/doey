#!/usr/bin/env bash
# Common utilities for Doey hooks — sourced by hook scripts, do not run directly.

set -euo pipefail

# Source centralized role definitions — resolve via multiple fallbacks
_DOEY_ROLES_FILE=""
# Method 1: Relative to this hook file (works inside Doey repo)
_doey_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
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
    # Source canonical send-keys helper (lives alongside doey-roles.sh)
    _doey_send_file="$(dirname "$_DOEY_ROLES_FILE")/doey-send.sh"
    if [ -f "$_doey_send_file" ]; then
        source "$_doey_send_file"
    fi
    unset _doey_send_file
else
    echo "[doey] WARNING: doey-roles.sh not found — role detection unavailable" >&2
fi

# ERR trap: report failing command to stderr so Claude Code shows it instead of "No stderr output"
trap '_doey_hook_err=$?; if [ -n "${RUNTIME_DIR:-}" ]; then printf "[%s] [%s] ERR at line %s: exit %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "${_DOEY_HOOK_NAME:-hook}" "${LINENO:-?}" "$_doey_hook_err" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null; fi; trap - EXIT; exit 0' ERR

init_hook() {
  if [ -z "${INPUT:-}" ]; then INPUT=$(cat); fi
  [ -z "${TMUX_PANE:-}" ] && exit 0

  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0

  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=$(printf '%s' "$PANE" | tr ':.-' '_')
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  local wp="${PANE#*:}"
  WINDOW_INDEX="${wp%.*}"
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')

  _ensure_dirs
  _init_debug
}

init_named_hook() {  # init_hook + set hook name + debug entry
  init_hook
  _DOEY_HOOK_NAME="${1:-unknown}"
  type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry
}

_resolve_project_dir() {
  local dir="${DOEY_PROJECT_DIR:-${DOEY_TEAM_DIR:-}}"
  [ -z "$dir" ] && dir=$(git rev-parse --show-toplevel 2>/dev/null) || true
  echo "${dir:-}"
}

_check_cooldown() {  # Returns 1 if within cooldown period
  local key="$1" seconds="${2:-60}"
  [ -n "${RUNTIME_DIR:-}" ] || return 0
  local file="${RUNTIME_DIR}/status/notif_cooldown_${key}"
  local last now
  last=$(cat "$file" 2>/dev/null) || last=0
  now=$(date +%s)
  [ "$((now - last))" -lt "$seconds" ] && return 1
  echo "$now" > "$file" 2>/dev/null || true
}

_parse_tool_field() {  # Parse field from tool hook JSON (jq preferred, grep fallback)
  local f="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$INPUT" | jq -r ".$f // empty" 2>/dev/null || echo ""
  else
    local k="${f##*.}"
    echo "$INPUT" | grep -oE "\"${k}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" | head -1 \
      | sed "s/.*\"${k}\"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//" 2>/dev/null || echo ""
  fi
}

_ensure_dirs() {
  [ -f "${RUNTIME_DIR}/.dirs_created" ] && return 0
  mkdir -p "${RUNTIME_DIR}"/{status,research,reports,results,messages,logs,errors,lifecycle}
  touch "${RUNTIME_DIR}/.dirs_created"
}

_rotate_log() {  # Rotate log if >500KB, keep last 200 lines
  local f="$1"
  [ -f "$f" ] || return 0
  local sz
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || sz=0
  if [ "${sz:-0}" -gt 512000 ]; then
    tail -200 "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null
  fi
}

# Parse debug.conf as flat key=value. NEVER source it.
_init_debug() {
  _DOEY_DEBUG="" _DOEY_DEBUG_HOOKS="" _DOEY_DEBUG_LIFECYCLE=""
  _DOEY_DEBUG_STATE="" _DOEY_DEBUG_MESSAGES="" _DOEY_DEBUG_DISPLAY=""
  [ -f "${RUNTIME_DIR}/debug.conf" ] || return 0
  while IFS='=' read -r _dk _dv; do
    case "$_dk" in
      DOEY_DEBUG)           _DOEY_DEBUG="$_dv" ;;
      DOEY_DEBUG_HOOKS)     _DOEY_DEBUG_HOOKS="$_dv" ;;
      DOEY_DEBUG_LIFECYCLE) _DOEY_DEBUG_LIFECYCLE="$_dv" ;;
      DOEY_DEBUG_STATE)     _DOEY_DEBUG_STATE="$_dv" ;;
      DOEY_DEBUG_MESSAGES)  _DOEY_DEBUG_MESSAGES="$_dv" ;;
      DOEY_DEBUG_DISPLAY)   _DOEY_DEBUG_DISPLAY="$_dv" ;;
    esac
  done < "${RUNTIME_DIR}/debug.conf"
}

_ms_now() {  # Millisecond timestamp (bash 3.2 safe)
  /usr/bin/perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' 2>/dev/null \
    || echo "$(date +%s)000"
}

_debug_log() {  # JSONL to per-pane category file; no-op when debug off
  [ "${_DOEY_DEBUG:-}" = "true" ] || return 0
  local cat="$1" msg="$2"; shift 2
  local pane_dir="${RUNTIME_DIR}/debug/${PANE_SAFE:-unknown}"
  [ -d "$pane_dir" ] || mkdir -p "$pane_dir" 2>/dev/null
  local ts
  ts=$(_ms_now)
  local extras=""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    extras="${extras},\"${k}\":\"${v}\""
  done
  printf '{"ts":%s,"pane":"%s","role":"%s","cat":"%s","msg":"%s"%s}\n' \
    "$ts" "${PANE:-unknown}" "${DOEY_ROLE:-unknown}" "$cat" "$msg" "$extras" \
    >> "${pane_dir}/${cat}.jsonl" 2>/dev/null
  if [ "${_DOEY_DEBUG_DISPLAY:-}" = "true" ]; then
    printf '[DOEY-DEBUG] %s %s %s\n' "$cat" "$msg" "$*" >&2
  fi
  case "$ts" in *00) _rotate_log "${pane_dir}/${cat}.jsonl" ;; esac
}

_debug_hook_entry() {  # Log hook entry + set EXIT trap for timing
  [ "${_DOEY_DEBUG_HOOKS:-}" = "true" ] || return 0
  _HOOK_START_MS=$(_ms_now)
  _debug_log hooks "entry" "hook=${_DOEY_HOOK_NAME:-unknown}"
  trap '_debug_hook_exit $? || true' EXIT
}

_debug_hook_exit() {
  [ "${_DOEY_DEBUG_HOOKS:-}" = "true" ] || return 0
  local exit_code="${1:-0}" end_ms dur_ms
  end_ms=$(_ms_now)
  dur_ms=$(( end_ms - ${_HOOK_START_MS:-$end_ms} ))
  [ "$dur_ms" -lt 0 ] && dur_ms=0
  _debug_log hooks "exit" "hook=${_DOEY_HOOK_NAME:-unknown}" "dur_ms=$dur_ms" "exit=$exit_code"
}

_log() {
  local log_file="${RUNTIME_DIR}/logs/${DOEY_PANE_ID:-unknown}.log"
  _rotate_log "$log_file"
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >> "$log_file" 2>/dev/null
}

# Structured error logger — per-pane log + shared errors.log
_log_error() {
  local category="${1:-UNKNOWN}" msg="${2:-}" detail="${3:-}"
  local now; now=$(date '+%Y-%m-%dT%H:%M:%S')
  _log "ERROR [$category] ${msg}${detail:+ | $detail}"
  printf '[%s] %s | %s | %s | %s | %s | %s | %s\n' \
    "$now" "$category" "${DOEY_PANE_ID:-unknown}" "${DOEY_ROLE:-unknown}" \
    "${_DOEY_HOOK_NAME:-unknown}" "${_DOEY_TOOL_NAME:-n/a}" "${detail:-n/a}" "$msg" \
    >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null
  _rotate_log "${RUNTIME_DIR}/errors/errors.log"
}

# Bridge errors into SQLite event system — call after _log_error for DB persistence
doey_log_error() {
  local error_type="${1:-unknown}" source="${2:-${DOEY_PANE_ID:-unknown}}"
  local message="${3:-}" task_id="${4:-}" data="${5:-}"
  # Flat-file backward compat
  _log_error "${error_type}" "$message" "$data"
  # SQLite event (backgrounded, never blocks)
  if command -v doey-ctl >/dev/null 2>&1; then
    local _proj; _proj=$(_resolve_project_dir)
    if [ -n "$_proj" ]; then
      local _evt_args="--type error_${error_type} --source ${source}"
      [ -n "$task_id" ] && _evt_args="${_evt_args} --task-id ${task_id}"
      local _evt_data="${message}"
      [ -n "$data" ] && _evt_data="${_evt_data} | ${data}"
      (doey event log $_evt_args --data "$_evt_data" --project-dir "$_proj" &) 2>/dev/null
    fi
  fi
}

parse_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$INPUT" | jq -r ".${field} // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" 2>/dev/null || echo ""
  fi
}

_read_team_key() {
  local val
  val=$(grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true
  val="${val%\"}"; val="${val#\"}"
  echo "$val"
}

team_role() {
  if [ -n "${DOEY_TEAM_ROLE:-}" ]; then
    echo "$DOEY_TEAM_ROLE"
  else
    echo "${DOEY_ROLE:-unknown}"
  fi
}

is_manager() {
  [ -n "${_DOEY_IS_MGR+x}" ] && return "$_DOEY_IS_MGR"
  _DOEY_IS_MGR=1
  [ "$WINDOW_INDEX" = "0" ] && return 1
  is_core_team && return 1
  local team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  [ -f "$team_file" ] || return 1
  [ "$PANE_INDEX" = "$(_read_team_key "$team_file" MANAGER_PANE)" ] && _DOEY_IS_MGR=0
  return "$_DOEY_IS_MGR"
}

is_taskmaster() {
  local _tm_pane _tm_win
  _tm_pane=$(get_taskmaster_pane)
  _tm_win="${_tm_pane%%.*}"
  [ "$WINDOW_INDEX" != "$_tm_win" ] && return 1
  [ "${WINDOW_INDEX}.${PANE_INDEX}" = "$_tm_pane" ]
}

is_boss() {
  [ "$WINDOW_INDEX" = "0" ] && [ "$PANE_INDEX" = "1" ]
}

is_worker() {
  [ "$WINDOW_INDEX" = "0" ] && return 1
  is_core_team && return 1
  ! is_manager
}

get_taskmaster_pane() {
  if [ -f "${RUNTIME_DIR}/session.env" ]; then
    local val
    val=$(_read_team_key "${RUNTIME_DIR}/session.env" TASKMASTER_PANE)
    [ -n "$val" ] && { echo "$val"; return; }
  fi
  echo "1.0"
}

# Extract Core Team window index from TASKMASTER_PANE (e.g., "1.0" → "1")
get_core_team_window() {
  local tm_pane
  tm_pane=$(get_taskmaster_pane)
  echo "${tm_pane%%.*}"
}

# True if this pane is in the Core Team window
is_core_team() {
  local _ctw
  _ctw=$(get_core_team_window)
  [ "$WINDOW_INDEX" = "$_ctw" ]
}

is_task_reviewer() {
  is_core_team && [ "$PANE_INDEX" = "1" ]
}

is_deployment() {
  is_core_team && [ "$PANE_INDEX" = "2" ]
}

is_doey_expert() {
  is_core_team && [ "$PANE_INDEX" = "3" ]
}

send_to_pane() {
  local target="$1" msg="$2"
  # Delegate to canonical helper if available
  if type doey_send_verified >/dev/null 2>&1; then
    doey_send_verified "$target" "$msg" 2>/dev/null || true
    return
  fi
  # Fallback: pre-clear + send-keys + settle + Enter
  tmux copy-mode -q -t "$target" 2>/dev/null || true
  tmux send-keys -t "$target" Escape 2>/dev/null || true
  sleep 0.1
  tmux send-keys -t "$target" C-u 2>/dev/null || true
  sleep 0.1
  tmux send-keys -t "$target" -- "$msg" 2>/dev/null || true
  sleep 0.15
  tmux send-keys -t "$target" Enter 2>/dev/null || true
}

sanitize_message() {
  local text="$1" max_len="${2:-100}"
  text=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/  */ /g')
  if [ "${#text}" -gt "$max_len" ]; then
    text="${text:0:$((max_len - 3))}..."
  fi
  echo "$text"
}

is_reserved() {
  [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]
}

# --- Health check utilities (doey fast-path with bash fallback) ---

# _pane_alive checks if a tmux pane exists and has a running process.
# Usage: _pane_alive <pane_id>  (e.g., "doey-foo:1.2")
_pane_alive() {
  tmux display-message -t "$1" -p '#{pane_pid}' >/dev/null 2>&1
}

# _read_pane_status reads the STATUS field from a pane's status file.
# Usage: _read_pane_status <pane_safe>
# Outputs: status string (e.g., "BUSY", "READY", "FINISHED")
_read_pane_status() {
  local pane_safe="$1"
  # Unified doey status get (auto-detects DB vs file)
  if command -v doey-ctl >/dev/null 2>&1; then
    doey status get --runtime "$RUNTIME_DIR" "$pane_safe" 2>/dev/null | grep '^status=' | cut -d= -f2-
  else
    # Bash fallback: grep status file directly
    local status_file="${RUNTIME_DIR}/status/${pane_safe}.status"
    grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //'
  fi
}

atomic_write() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

write_pane_status() {
  local target="$1" status="$2" task="${3:-}"
  # Try unified status command (writes DB + file)
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    doey status set \
      --pane-id "${DOEY_PANE_SAFE:-${PANE_SAFE:-}}" \
      --window-id "W${DOEY_WINDOW_INDEX:-${WINDOW_INDEX:-0}}" \
      --role "${DOEY_ROLE:-worker}" \
      --status "$status" \
      --project-dir "$PROJECT_DIR" 2>/dev/null || true
    # Still write file for backward compat during transition
  fi
  printf 'PANE: %s\nUPDATED: %s\nSTATUS: %s\nTASK: %s\n' "$PANE" "$NOW" "$status" "$task" > "$target.tmp" && mv "$target.tmp" "$target"
}

NL='
'

is_numeric() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }

write_activity() {  # Append JSONL activity event: write_activity <event> <data_json>
  local event="$1" data="${2:-"{}"}"
  local pane_safe="${PANE_SAFE:-${DOEY_PANE_SAFE:-unknown}}"
  # Try SQLite event log first
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    doey event log --type "activity_${event}" --source "${pane_safe}" --data "$data" --project-dir "$PROJECT_DIR" 2>/dev/null || true
  fi
  # Still write jsonl file for backward compat
  local ts pane_label activity_dir
  ts=$(date +%s)
  pane_label="W${WINDOW_INDEX:-${DOEY_WINDOW_INDEX:-0}}.${PANE_INDEX:-${DOEY_PANE_INDEX:-0}}"
  activity_dir="${RUNTIME_DIR:-/tmp/doey}/activity"
  mkdir -p "$activity_dir" 2>/dev/null || return 0
  printf '{"ts":%s,"pane":"%s","event":"%s","data":%s}\n' \
    "$ts" "$pane_label" "$event" "$data" \
    >> "${activity_dir}/${pane_safe}.jsonl" 2>/dev/null
}

notify_taskmaster() {  # Lifecycle event -> Taskmaster wake trigger
  # Don't self-notify
  if is_taskmaster; then return 0; fi
  local status="${1:-}" detail="${2:-}"
  local team_w="${DOEY_TEAM_WINDOW:-${WINDOW_INDEX:-}}"
  [ -z "$team_w" ] && return 0
  local pane_id="${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}"
  # Try SQLite event log
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    doey event log --type "lifecycle_${status}" --source "${pane_id}" --target "taskmaster" --data "{\"team\":\"W${team_w}\",\"detail\":\"${detail}\"}" --project-dir "$PROJECT_DIR" 2>/dev/null || true
  fi
  # Still write file-based lifecycle event for backward compat
  mkdir -p "${RUNTIME_DIR}/lifecycle" 2>/dev/null || return 0
  printf '%s|%s|%s|%s\n' "$pane_id" "$status" "$(date '+%H:%M:%S')" "$detail" \
    > "${RUNTIME_DIR}/lifecycle/W${team_w}_${pane_id}_$(date +%s).evt" 2>/dev/null
  # Taskmaster wake trigger removed — stop-notify.sh is the sole wake source
}

_send_desktop_notification() {  # Low-level, no role check, no cooldown
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript - "$title" "$body" <<'APPLESCRIPT' 2>/dev/null &
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name "Ping"
end run
APPLESCRIPT
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" 2>/dev/null &
  elif command -v powershell.exe >/dev/null 2>&1; then
    local ps_title="${title//\'/\'\'}" ps_body="${body//\'/\'\'}"
    powershell.exe -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('${ps_body}', '${ps_title}')" 2>/dev/null &
  fi
}

send_notification() {
  local title="${1:-Claude Code}" body="${2:-Task completed}"
  is_boss || return 0
  _check_cooldown "${title//[^a-zA-Z0-9]/_}" 60 || return 0
  _send_desktop_notification "$title" "$body"
}
