#!/usr/bin/env bash
# Common utilities for Doey hooks — sourced by hook scripts, do not run directly.

set -euo pipefail

# ERR trap: report failing command to stderr so Claude Code shows it instead of "No stderr output"
trap '_doey_hook_err=$?; if [ -n "${RUNTIME_DIR:-}" ]; then printf "[%s] [%s] ERR at line %s: exit %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "${_DOEY_HOOK_NAME:-hook}" "${LINENO:-?}" "$_doey_hook_err" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null; fi; exit 0' ERR

init_hook() {
  if [ -z "${INPUT:-}" ]; then INPUT=$(cat); fi
  [ -z "${TMUX_PANE:-}" ] && exit 0

  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0

  # -t "$TMUX_PANE" resolves THIS pane (without -t, workers misidentify as Manager)
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[-:.]/_}
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  local wp="${PANE#*:}"
  WINDOW_INDEX="${wp%.*}"
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')

  _ensure_dirs
  _init_debug
}

_ensure_dirs() {
  [ -f "${RUNTIME_DIR}/.dirs_created" ] && return 0
  mkdir -p "${RUNTIME_DIR}"/{status,research,reports,results,messages,logs,errors,lifecycle}
  touch "${RUNTIME_DIR}/.dirs_created"
}

# Rotate a log file if it exceeds 500KB, keeping last 200 lines.
# Usage: _rotate_log <file>
_rotate_log() {
  local f="$1"
  [ -f "$f" ] || return 0
  local sz
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || sz=0
  if [ "${sz:-0}" -gt 512000 ]; then
    tail -200 "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null
  fi
}

# --- Debug mode infrastructure ---

# Parse debug.conf as flat key=value. NEVER source it.
_init_debug() {
  _DOEY_DEBUG=""
  _DOEY_DEBUG_HOOKS=""
  _DOEY_DEBUG_LIFECYCLE=""
  _DOEY_DEBUG_STATE=""
  _DOEY_DEBUG_MESSAGES=""

  _DOEY_DEBUG_DISPLAY=""
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
  return 0
}

# Millisecond timestamp (macOS bash 3.2 compatible)
_ms_now() {
  /usr/bin/perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' 2>/dev/null \
    || echo "$(date +%s)000"
}

# Write JSONL to per-pane category file. No-op when debug off.
# Usage: _debug_log <category> <msg> [key=value ...]
_debug_log() {
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
  # Rotate every ~100 writes via modulo on timestamp
  case "$ts" in *00)
    _rotate_log "${pane_dir}/${cat}.jsonl"
  ;; esac
  return 0
}

# Log hook entry, set EXIT trap for hook exit timing.
# Only active when _DOEY_DEBUG_HOOKS=true.
_debug_hook_entry() {
  [ "${_DOEY_DEBUG_HOOKS:-}" = "true" ] || return 0
  _HOOK_START_MS=$(_ms_now)
  _debug_log hooks "entry" "hook=${_DOEY_HOOK_NAME:-unknown}"
  trap '_debug_hook_exit $?' EXIT
  return 0
}

# Log hook exit with duration and exit code.
_debug_hook_exit() {
  [ "${_DOEY_DEBUG_HOOKS:-}" = "true" ] || return 0
  local exit_code="${1:-0}" end_ms dur_ms
  end_ms=$(_ms_now)
  dur_ms=$(( end_ms - ${_HOOK_START_MS:-$end_ms} ))
  [ "$dur_ms" -lt 0 ] && dur_ms=0
  _debug_log hooks "exit" "hook=${_DOEY_HOOK_NAME:-unknown}" "dur_ms=$dur_ms" "exit=$exit_code"
  return 0
}

_log() {
  local msg="$1"
  local pane_id="${DOEY_PANE_ID:-unknown}"
  local log_file="${RUNTIME_DIR}/logs/${pane_id}.log"
  _rotate_log "$log_file"
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$msg" >> "$log_file" 2>/dev/null
}

# Structured error logger — writes to per-pane log AND shared errors.log + individual .err files.
# Usage: _log_error CATEGORY "message" [detail]
# Categories: TOOL_BLOCKED, LINT_ERROR, ANOMALY, HOOK_ERROR, DELIVERY_FAILED
_log_error() {
  local category="${1:-UNKNOWN}" msg="${2:-}" detail="${3:-}"
  local pane_id="${DOEY_PANE_ID:-unknown}"
  local role="${DOEY_ROLE:-unknown}"
  local hook_name="${_DOEY_HOOK_NAME:-unknown}"
  local tool="${_DOEY_TOOL_NAME:-}"
  local err_dir="${RUNTIME_DIR}/errors"
  local err_log="${err_dir}/errors.log"
  local now
  now=$(date '+%Y-%m-%dT%H:%M:%S')

  # 1. Log to per-pane log via existing _log()
  _log "ERROR [$category] ${msg}${detail:+ | $detail}"

  # 2. Append to shared errors.log (pipe-delimited for grep/awk)
  printf '[%s] %s | %s | %s | %s | %s | %s | %s\n' \
    "$now" "$category" "$pane_id" "$role" "$hook_name" "${tool:-n/a}" "${detail:-n/a}" "$msg" \
    >> "$err_log" 2>/dev/null

  # 3. Individual .err file for programmatic access
  local err_file="${err_dir}/${pane_id}_$(date +%s)_$$.err"
  cat > "$err_file" 2>/dev/null <<ERR_EOF
TIMESTAMP=$now
CATEGORY=$category
PANE_ID=$pane_id
ROLE=$role
HOOK=$hook_name
TOOL=${tool:-}
DETAIL=${detail:-}
MESSAGE=$msg
ERR_EOF

  # 4. Rotation: if errors.log > 500KB, keep last 200 lines
  _rotate_log "$err_log"

  # 5. Cleanup: remove .err files older than 1 hour, keep max 200
  local count
  count=$(find "$err_dir" -name '*.err' 2>/dev/null | wc -l | tr -d ' ') || count=0
  if [ "${count:-0}" -gt 200 ]; then
    find "$err_dir" -name '*.err' -mmin +60 -delete 2>/dev/null || true
    # If still over 200, remove oldest
    count=$(find "$err_dir" -name '*.err' 2>/dev/null | wc -l | tr -d ' ') || count=0
    if [ "${count:-0}" -gt 200 ]; then
      find "$err_dir" -name '*.err' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | tail -n +201 | xargs rm -f 2>/dev/null || true
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
  val=$(grep "^$2=" "$1" | cut -d= -f2-) || true
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

_read_teamdef_key() {
  local envfile="$1" key="$2"
  grep "^${key}=" "$envfile" 2>/dev/null | cut -d= -f2-
}

# Watchdog role eliminated — SM absorbs monitoring
is_watchdog() { return 1; }

is_manager() {
  [ -n "${_DOEY_IS_MGR+x}" ] && return "$_DOEY_IS_MGR"
  _DOEY_IS_MGR=1
  [ "$WINDOW_INDEX" = "0" ] && return 1
  local team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  [ -f "$team_file" ] || return 1
  [ "$PANE_INDEX" = "$(_read_team_key "$team_file" MANAGER_PANE)" ] && _DOEY_IS_MGR=0
  return "$_DOEY_IS_MGR"
}

is_session_manager() {
  [ "$WINDOW_INDEX" != "0" ] && return 1
  [ "${PANE#*:}" = "$(get_sm_pane)" ]
}

is_boss() {
  [ "$WINDOW_INDEX" = "0" ] && [ "$PANE_INDEX" = "1" ]
}

is_worker() {
  [ "$WINDOW_INDEX" = "0" ] && return 1
  ! is_manager
}

get_sm_pane() {
  if [ -f "${RUNTIME_DIR}/session.env" ]; then
    local val
    val=$(_read_team_key "${RUNTIME_DIR}/session.env" SM_PANE)
    [ -n "$val" ] && { echo "$val"; return; }
  fi
  echo "0.2"
}

send_to_pane() {
  local target="$1" msg="$2"
  tmux copy-mode -q -t "$target" 2>/dev/null
  tmux send-keys -t "$target" "$msg" Enter 2>/dev/null
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

# Atomic file write: content -> tmp -> mv
atomic_write() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

# Write structured pane status file atomically
# Usage: write_pane_status <target_file> <status> [task]
write_pane_status() {
  local target="$1" status="$2" task="${3:-}" tmp
  tmp=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || tmp=""
  [ -z "$tmp" ] || [ ! -f "$tmp" ] && tmp="$target"
  printf 'PANE: %s\nUPDATED: %s\nSTATUS: %s\nTASK: %s\n' "$PANE" "$NOW" "$status" "$task" > "$tmp"
  [ "$tmp" != "$target" ] && mv "$tmp" "$target"
}

NL='
'

is_numeric() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }

# Notify Session Manager of a lifecycle event.
# Writes event to lifecycle dir and triggers SM wake.
# Usage: notify_sm <status> [detail]
notify_sm() {
  local status="${1:-}" detail="${2:-}"
  local team_w="${DOEY_TEAM_WINDOW:-${WINDOW_INDEX:-}}"
  [ -z "$team_w" ] && return 0
  local pane_id="${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}"
  mkdir -p "${RUNTIME_DIR}/lifecycle" 2>/dev/null || return 0
  local evt_file="${RUNTIME_DIR}/lifecycle/W${team_w}_${pane_id}_$(date +%s).evt"
  printf '%s|%s|%s|%s\n' "$pane_id" "$status" "$(date '+%H:%M:%S')" "$detail" > "$evt_file" 2>/dev/null
  # Wake Session Manager
  touch "${RUNTIME_DIR}/status/sm_trigger" 2>/dev/null
  return 0
}
# Backward compatibility alias
notify_watchdog() { notify_sm "$@"; }

# Low-level desktop notification — no role check, no cooldown.
# Usage: _send_desktop_notification "Title" "Body"
_send_desktop_notification() {
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
  return 0
}

send_notification() {
  local title="${1:-Claude Code}" body="${2:-Task completed}"
  is_boss || return 0

  # 60-second cooldown per title
  if [ -n "${RUNTIME_DIR:-}" ]; then
    local title_safe="${title//[^a-zA-Z0-9]/_}"
    local cooldown_file="${RUNTIME_DIR}/status/notif_cooldown_${title_safe}"
    local last_sent now
    last_sent=$(cat "$cooldown_file" 2>/dev/null) || last_sent=0
    now=$(date +%s)
    [ "$((now - last_sent))" -lt 60 ] && return 0
    echo "$now" > "$cooldown_file" 2>/dev/null || true
  fi

  _send_desktop_notification "$title" "$body"
}
