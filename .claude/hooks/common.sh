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
# Source stats emitter library (alongside doey-roles.sh). One-liner: silent-fail, idempotent.
if [ -n "${_DOEY_ROLES_FILE:-}" ] && [ -f "$(dirname "$_DOEY_ROLES_FILE")/doey-stats.sh" ]; then . "$(dirname "$_DOEY_ROLES_FILE")/doey-stats.sh" 2>/dev/null || true; fi
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

# Enforcement mode for AskUserQuestion hook (shadow|block|off).
# shadow = log violations, never block. block = log + deny. off = disabled.
DOEY_ENFORCE_QUESTIONS="${DOEY_ENFORCE_QUESTIONS:-shadow}"
case "$DOEY_ENFORCE_QUESTIONS" in
  shadow|block|off) ;;
  *)
    printf '[%s] enforce-askuserquestion: unknown DOEY_ENFORCE_QUESTIONS=%s, using shadow\n' "$(date +%H:%M:%S)" "$DOEY_ENFORCE_QUESTIONS" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null || true
    DOEY_ENFORCE_QUESTIONS=shadow
    ;;
esac

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

_violations_dir() {
  local pd
  pd=$(_resolve_project_dir) || return 1
  printf '%s/.doey/violations' "$pd"
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

# _strip_excerpt: stdin → JSON-safe single-line excerpt, ≤200 bytes.
# NOTE: byte-based truncation may split a multi-byte UTF-8 character.
# Local audit logs tolerate this; transport-critical callers should re-encode.
_strip_excerpt() {
  tr '\n\r\t' '   ' | sed 's/  */ /g' | cut -c1-200 | sed 's/\\/\\\\/g; s/"/\\"/g'
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

is_planner() {
  local tr="${DOEY_TEAM_ROLE:-}"
  if [ -z "$tr" ] && [ -n "${RUNTIME_DIR:-}" ] && [ -n "${PANE_SAFE:-}" ]; then
    tr=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.team_role" 2>/dev/null) || tr=""
  fi
  [ "$tr" = "$DOEY_ROLE_ID_PLANNER" ]
}

is_boss_or_planner() { is_boss || is_planner; }

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

transition_state() {  # Validate and execute a pane status transition against the state machine
  local pane_id="${1:-}" target_state="${2:-}"
  [ -z "$pane_id" ] || [ -z "$target_state" ] && return 1

  # Read current state from status file
  local status_file="${RUNTIME_DIR}/status/${pane_id}.status"
  local current_state=""
  if [ -f "$status_file" ]; then
    current_state=$(grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //')
  fi

  # If no status file exists, allow any transition (new/uninitialized pane)
  if [ -z "$current_state" ]; then
    write_pane_status "$status_file" "$target_state"
    return 0
  fi

  # Validate transition against state machine using case statements (bash 3.2 safe)
  local valid=false
  case "$current_state" in
    BOOTING)
      case "$target_state" in READY) valid=true ;; esac
      ;;
    READY)
      case "$target_state" in BUSY) valid=true ;; esac
      ;;
    BUSY)
      case "$target_state" in FINISHED|ERROR|RESERVED|RESPAWNING) valid=true ;; esac
      ;;
    FINISHED)
      case "$target_state" in READY) valid=true ;; esac
      ;;
    ERROR)
      case "$target_state" in READY) valid=true ;; esac
      ;;
  esac

  if [ "$valid" = "true" ]; then
    write_pane_status "$status_file" "$target_state"
    return 0
  fi

  # Invalid transition — log warning to issues directory
  local issues_dir="${RUNTIME_DIR}/issues"
  mkdir -p "$issues_dir" 2>/dev/null || true
  local ts
  ts=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "unknown")
  local w_idx="${WINDOW_INDEX:-${DOEY_WINDOW_INDEX:-0}}"
  local p_idx="${PANE_INDEX:-${DOEY_PANE_INDEX:-0}}"
  printf 'WINDOW: %s | PANE: %s | SEVERITY: HIGH\nCATEGORY: state_transition\nInvalid transition: %s -> %s at %s\nPane: %s\n' \
    "$w_idx" "$p_idx" "$current_state" "$target_state" "$ts" "$pane_id" \
    >> "${issues_dir}/state_transitions.log" 2>/dev/null
  _debug_log "state" "invalid_transition" "from=$current_state" "to=$target_state" "pane=$pane_id"
  return 1
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

# ─── Polling-loop detector + circuit breaker (task #525 / #536) ───────
#
# Detects panes whose wait hook keeps re-firing without any tool work
# happening between wakes. Three thresholds inside a 120s rolling window:
#   consecutive=3 → warn event (observability)
#   consecutive=5 → breaker event + nudge owner + back off the next wake
#                   for 30s (latched until reset signal)
#
# Reset signal: ${RUNTIME_DIR}/status/<pane_safe>.tool_used_this_turn
# is touched by on-pre-tool-use.sh on every successful (allow-path) tool
# invocation. Presence of the sentinel = real work happened, clear the
# counter. Sentinel is consumed on read.
#
# All event writes go through `doey-ctl event log --class violation_polling`
# (no sqlite3, no jq dependency). Test harnesses set DOEY_VIOLATION_STUB
# to bypass doey-ctl entirely and append a JSONL line to a file.
#
# TEST-ONLY ENV (also documented in docs/violations.md):
#   DOEY_VIOLATION_STUB  - file path; if set, events appended here instead
#                          of being sent through doey-ctl
#   DOEY_TEST_CLOCK      - integer unix seconds; overrides `date +%s`
#                          for deterministic window-expiry testing

# Emit a violation event. Stub-mode-aware.
_violation_emit_event() {
  local severity="$1" wake_reason="$2" consec="$3" window_sec="$4"
  local session="$5" role="$6" window_id="$7" pane_safe="$8"
  if [ -n "${DOEY_VIOLATION_STUB:-}" ]; then
    printf '{"class":"violation_polling","severity":"%s","wake_reason":"%s","consecutive":%s,"window_sec":%s,"session":"%s","role":"%s","window_id":"%s","pane":"%s"}\n' \
      "$severity" "$wake_reason" "$consec" "$window_sec" "$session" "$role" "$window_id" "$pane_safe" \
      >> "$DOEY_VIOLATION_STUB" 2>/dev/null || true
    return 0
  fi
  command -v doey-ctl >/dev/null 2>&1 || return 0
  local _proj
  _proj=$(_resolve_project_dir 2>/dev/null) || _proj=""
  [ -z "$_proj" ] && return 0
  (doey-ctl event log \
    --class violation_polling \
    --severity "$severity" \
    --session "$session" \
    --role "$role" \
    --window-id "$window_id" \
    --wake-reason "$wake_reason" \
    --consecutive "$consec" \
    --window-sec "$window_sec" \
    --project-dir "$_proj" >/dev/null 2>&1 &) || true
}

# Send the breaker nudge to the owner pane (Boss for Taskmaster
# self-loops, Taskmaster otherwise). Skipped in stub mode.
_violation_send_nudge() {
  local pane_safe="$1" wake_reason="$2" consec="$3" window_sec="$4" session="$5"
  [ -n "${DOEY_VIOLATION_STUB:-}" ] && return 0
  command -v doey-ctl >/dev/null 2>&1 || return 0
  local _proj
  _proj=$(_resolve_project_dir 2>/dev/null) || _proj=""
  [ -z "$_proj" ] && return 0
  local _owner
  if [ "${DOEY_ROLE:-}" = "${DOEY_ROLE_ID_COORDINATOR:-coordinator}" ]; then
    _owner="0.1"
  else
    local _ctw
    _ctw=$(get_core_team_window 2>/dev/null) || _ctw="1"
    _owner="${_ctw}.0"
  fi
  local _body="pane=$pane_safe reason=$wake_reason consecutive=$consec window_sec=$window_sec session=$session"
  (doey-ctl msg send \
    --to "$_owner" \
    --from "polling-loop-detector" \
    --subject "polling_loop_breaker" \
    --body "$_body" \
    --project-dir "$_proj" >/dev/null 2>&1 &) || true
}

# Read a numeric field from the JSON ledger.
_violation_ledger_int() {
  local file="$1" field="$2" default="${3:-0}"
  local val
  val=$(grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+$') || val=""
  printf '%s' "${val:-$default}"
}

# Read a string field from the JSON ledger.
_violation_ledger_str() {
  local file="$1" field="$2"
  grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# Write the JSON ledger atomically.
_violation_ledger_write() {
  local file="$1" reason="$2" consec="$3" win_start="$4" last="$5" next_e="$6" breaker="$7"
  printf '{"last_wake_reason":"%s","consecutive_count":%s,"window_start_ts":%s,"last_wake_ts":%s,"next_wake_earliest":%s,"breaker_tripped":%s}\n' \
    "$reason" "$consec" "$win_start" "$last" "$next_e" "$breaker" \
    > "${file}.tmp" 2>/dev/null && mv "${file}.tmp" "$file" 2>/dev/null || true
}

# violation_bump_counter — main detector entry point.
# Args: pane_safe wake_reason session role window_id
violation_bump_counter() {
  local pane_safe="${1:-}" wake_reason="${2:-}" session="${3:-}" role="${4:-}" window_id="${5:-}"

  # Step 1: enforcement mode gate
  local mode="${DOEY_ENFORCE_VIOLATIONS:-on}"
  case "$mode" in on|shadow|off) ;; *) mode=on ;; esac
  [ "$mode" = "off" ] && return 0

  # Step 2: doey-ctl gate (stub-mode skips this)
  if [ -z "${DOEY_VIOLATION_STUB:-}" ] && ! command -v doey-ctl >/dev/null 2>&1; then
    return 0
  fi

  [ -n "$pane_safe" ] || return 0
  [ -n "${RUNTIME_DIR:-}" ] || return 0

  # Step 12b: sanitize wake_reason — only [A-Z_]
  wake_reason=$(printf '%s' "$wake_reason" | tr -cd 'A-Z_')
  [ -n "$wake_reason" ] || wake_reason="UNKNOWN"

  local state_file="${RUNTIME_DIR}/wait-state-${pane_safe}.json"
  local lock_dir="${state_file}.lock"
  local sentinel="${RUNTIME_DIR}/status/${pane_safe}.tool_used_this_turn"

  # Step 3: acquire lock with stale-recovery + 3 retries @ 50ms
  local _attempts=0 _locked=false
  while [ "$_attempts" -lt 3 ]; do
    if mkdir "$lock_dir" 2>/dev/null; then _locked=true; break; fi
    if find "$lock_dir" -maxdepth 0 -mmin +0.5 2>/dev/null | grep -q .; then
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    sleep 0.05 2>/dev/null || true
    _attempts=$((_attempts + 1))
  done
  if [ "$_locked" != true ]; then
    _log "violation_lock_contention pane=$pane_safe" 2>/dev/null || true
    return 0
  fi

  local now="${DOEY_TEST_CLOCK:-$(date +%s)}"

  # Step 4: sentinel reset (real tool work observed since last wake)
  if [ -f "$sentinel" ]; then
    rm -f "$sentinel" 2>/dev/null || true
    _violation_ledger_write "$state_file" "$wake_reason" 1 "$now" "$now" 0 false
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi

  # Step 6: read existing ledger
  local last_reason="" consecutive=0 window_start=0 last_wake=0 next_earliest=0 breaker=false
  if [ -f "$state_file" ]; then
    last_reason=$(_violation_ledger_str "$state_file" last_wake_reason)
    consecutive=$(_violation_ledger_int "$state_file" consecutive_count 0)
    window_start=$(_violation_ledger_int "$state_file" window_start_ts 0)
    last_wake=$(_violation_ledger_int "$state_file" last_wake_ts 0)
    next_earliest=$(_violation_ledger_int "$state_file" next_wake_earliest 0)
    if grep -q '"breaker_tripped"[[:space:]]*:[[:space:]]*true' "$state_file" 2>/dev/null; then
      breaker=true
    fi
  fi

  # Step 5: backoff in progress — short-circuit (after sentinel check)
  if [ "$next_earliest" -gt 0 ] && [ "$now" -lt "$next_earliest" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi

  # Steps 7-9: counter logic
  if [ "$last_reason" != "$wake_reason" ]; then
    window_start="$now"
    consecutive=1
  elif [ "$((now - window_start))" -gt 120 ]; then
    window_start="$now"
    consecutive=1
  else
    consecutive=$((consecutive + 1))
  fi
  last_wake="$now"
  local window_sec=$((now - window_start))

  # Step 10: write ledger (mid-state, before any event side effects)
  _violation_ledger_write "$state_file" "$wake_reason" "$consecutive" \
    "$window_start" "$last_wake" "$next_earliest" "$breaker"

  # Step 11: warn at 3
  if [ "$consecutive" = "3" ]; then
    _violation_emit_event warn "$wake_reason" "$consecutive" "$window_sec" \
      "$session" "$role" "$window_id" "$pane_safe"
  fi

  # Step 12 + 13: breaker at 5 (single shot until reset)
  if [ "$consecutive" -ge 5 ] && [ "$breaker" != true ]; then
    _violation_emit_event breaker "$wake_reason" "$consecutive" "$window_sec" \
      "$session" "$role" "$window_id" "$pane_safe"
    breaker=true
    if [ "$mode" = "on" ]; then
      next_earliest=$((now + 30))
      _violation_send_nudge "$pane_safe" "$wake_reason" "$consecutive" "$window_sec" "$session"
    fi
    # Re-write ledger with breaker latch + (in `on`) backoff window
    _violation_ledger_write "$state_file" "$wake_reason" "$consecutive" \
      "$window_start" "$last_wake" "$next_earliest" "$breaker"
  fi

  # Step 14: release lock
  rmdir "$lock_dir" 2>/dev/null || true
  return 0
}
