#!/usr/bin/env bash
# Common utilities for Doey hooks — sourced by hook scripts, do not run directly.

set -euo pipefail

init_hook() {
  if [ -z "${INPUT:-}" ]; then INPUT=$(cat); fi
  [ -z "${TMUX_PANE:-}" ] && exit 0

  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0

  # -t "$TMUX_PANE" resolves THIS pane (without -t, workers misidentify as Manager)
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[:.]/_}
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  local wp="${PANE#*:}"
  WINDOW_INDEX="${wp%.*}"
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')

  _ensure_dirs
}

_ensure_dirs() {
  [ -f "${RUNTIME_DIR}/.dirs_created" ] && return 0
  mkdir -p "${RUNTIME_DIR}"/{status,research,reports,results,messages,logs,errors}
  touch "${RUNTIME_DIR}/.dirs_created"
}

_log() {
  local msg="$1"
  local pane_id="${DOEY_PANE_ID:-unknown}"
  local log_file="${RUNTIME_DIR}/logs/${pane_id}.log"
  # Rotate if > 500KB
  if [ -f "$log_file" ]; then
    local size
    size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ') || size=0
    if [ "$size" -gt 512000 ]; then
      tail -200 "$log_file" > "${log_file}.tmp" 2>/dev/null && mv "${log_file}.tmp" "$log_file" 2>/dev/null
    fi
  fi
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
  local log_size
  log_size=$(wc -c < "$err_log" 2>/dev/null | tr -d ' ') || log_size=0
  if [ "${log_size:-0}" -gt 512000 ]; then
    tail -200 "$err_log" > "${err_log}.tmp" 2>/dev/null && mv "${err_log}.tmp" "$err_log" 2>/dev/null
  fi

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

is_watchdog() {
  [ -n "${_DOEY_IS_WD+x}" ] && return "$_DOEY_IS_WD"
  _DOEY_IS_WD=1
  [ "$WINDOW_INDEX" != "0" ] && return 1
  for _wd_tf in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$_wd_tf" ] || continue
    if [ "$(_read_team_key "$_wd_tf" WATCHDOG_PANE)" = "0.${PANE_INDEX}" ]; then
      _DOEY_IS_WD=0; break
    fi
  done
  return "$_DOEY_IS_WD"
}

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
  echo "0.1"
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

send_notification() {
  local title="${1:-Claude Code}" body="${2:-Task completed}"
  is_session_manager || return 0

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
