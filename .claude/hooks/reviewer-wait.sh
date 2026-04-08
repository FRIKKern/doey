#!/usr/bin/env bash
# Reviewer wait — checks for review work, sleeps briefly if idle.
# Called by the Task Reviewer agent via Bash, not a registered hook.
set -euo pipefail

# ── Resolve runtime directory ─────────────────────────────────────────
if [ -n "${DOEY_RUNTIME:-}" ]; then RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then RUNTIME_DIR="$1"
else RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 5; exit 0; }
fi
if [ -f "${RUNTIME_DIR}/session.env" ]; then
  while IFS='=' read -r _key _value; do
    _value="${_value%\"}"; _value="${_value#\"}"
    case "$_key" in
      SESSION_NAME) SESSION_NAME="$_value" ;;
      PROJECT_DIR)  PROJECT_DIR="$_value" ;;
    esac
  done < "${RUNTIME_DIR}/session.env"
fi
trap 'exit 0' ERR
source "$(dirname "$0")/common.sh" 2>/dev/null || true

# ── Derive reviewer pane identity ─────────────────────────────────────
CORE_WINDOW="$(get_core_team_window 2>/dev/null || echo 1)"
REVIEWER_PANE="${CORE_WINDOW}.1"
REVIEWER_SAFE="${SESSION_NAME//[-:.]/_}_${REVIEWER_PANE//[-:.]/_}"
_REVIEWER_STATUS_FILE="${RUNTIME_DIR}/status/${REVIEWER_SAFE}.status"
MSG_DIR="${RUNTIME_DIR}/messages"

# EXIT trap: restore BUSY so the agent resumes after this script returns
trap 'NOW=$(date "+%Y-%m-%dT%H:%M:%S%z"); if command -v doey-ctl >/dev/null 2>&1; then doey status set "$REVIEWER_SAFE" "BUSY" 2>/dev/null || true; else write_pane_status "$_REVIEWER_STATUS_FILE" "BUSY" "Task Reviewer idle — listening" 2>/dev/null || true; fi' EXIT

# ── Wake helper ───────────────────────────────────────────────────────
_wake() { echo "WAKE_REASON=$1"; exit 0; }

# ── Check for actionable work ─────────────────────────────────────────
_check_work() {
  local elapsed="${1:-0}"

  # 1. Trigger files
  local _trig_found=false _tf
  [ -f "${RUNTIME_DIR}/status/reviewer_trigger" ] && _trig_found=true
  for _tf in "${RUNTIME_DIR}/triggers"/reviewer_*; do
    [ -f "$_tf" ] && { _trig_found=true; break; }
  done
  if [ "$_trig_found" = true ]; then
    rm -f "${RUNTIME_DIR}/status/reviewer_trigger" 2>/dev/null
    bash -c 'rm -f "${1}"/triggers/reviewer_* 2>/dev/null' _ "$RUNTIME_DIR"
    _wake "TRIGGERED"
  fi

  # 2. Unread messages for reviewer pane
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    _unread=$(doey msg count --to "$REVIEWER_PANE" --project-dir "$PROJECT_DIR" 2>/dev/null) || _unread=0
    [ "${_unread:-0}" -gt 0 ] && _wake "MSG"
  else
    local _mf _pane_safe="${REVIEWER_PANE//[-:.]/_}"
    for _mf in "$MSG_DIR"/${REVIEWER_SAFE}_*.msg "$MSG_DIR"/"${_pane_safe}"_*.msg; do
      [ -f "$_mf" ] && _wake "MSG"
    done
  fi

  # 3. Active in_progress tasks worth observing
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    _active=$(doey-ctl task list --status in_progress --project-dir "$PROJECT_DIR" 2>/dev/null | awk 'NR>1 && /^[0-9]/{n++} END{print n+0}') || _active=0
    [ "${_active:-0}" -gt 0 ] && _wake "ACTIVE_TASKS"
  elif [ -d "${PROJECT_DIR:-.}/.doey/tasks" ]; then
    local _atf _astatus
    for _atf in "${PROJECT_DIR:-.}"/.doey/tasks/*.task; do
      [ -f "$_atf" ] || continue
      _astatus=$(grep '^TASK_STATUS=' "$_atf" 2>/dev/null | head -1 | cut -d= -f2-) || continue
      [ "$_astatus" = "in_progress" ] && _wake "ACTIVE_TASKS"
    done
  fi

  return 1
}

# ── Main flow ─────────────────────────────────────────────────────────

# Immediate check
_check_work "0" || true

# No work found — sleep
_sleep_dur=60
if command -v inotifywait >/dev/null 2>&1; then
  mkdir -p "${RUNTIME_DIR}/triggers" 2>/dev/null
  inotifywait -qq -t "$_sleep_dur" -e create,modify \
    "${RUNTIME_DIR}/status/" \
    "${RUNTIME_DIR}/results/" \
    "${MSG_DIR}/" \
    "${RUNTIME_DIR}/triggers/" 2>/dev/null || true
else
  sleep "$_sleep_dur"
fi

# Post-sleep: consume trigger files (race edge case)
_trig_found=false
[ -f "${RUNTIME_DIR}/status/reviewer_trigger" ] && _trig_found=true
for _tf in "${RUNTIME_DIR}/triggers"/reviewer_*; do
  [ -f "$_tf" ] && { _trig_found=true; break; }
done
if [ "$_trig_found" = true ]; then
  rm -f "${RUNTIME_DIR}/status/reviewer_trigger" 2>/dev/null
  bash -c 'rm -f "${1}"/triggers/reviewer_* 2>/dev/null' _ "$RUNTIME_DIR"
  echo "WAKE_REASON=TRIGGERED"
  exit 0
fi

# Re-check for work that arrived during sleep
_check_work "$_sleep_dur" || true

echo "WAKE_REASON=TIMEOUT"
exit 0
