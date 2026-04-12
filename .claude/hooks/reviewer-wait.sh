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
_wake() {
  # Stats emit (task #521 Phase 2) — cooldown-gated so polling does NOT
  # flood stats.db. Emit on state change (idle → wake) only.
  if command -v doey-stats-emit.sh >/dev/null 2>&1 && _check_cooldown "reviewer_wake" 30 2>/dev/null; then
    (doey-stats-emit.sh worker reviewer_wake "reason=${1:-unknown}" &) 2>/dev/null || true
  fi
  echo "WAKE_REASON=$1"; exit 0;
}

# ── Polling-loop detector (task #525/#536) ────────────────────────────
# Runs on every wake cycle. If this pane keeps waking without any real
# tool work (no sentinel from on-pre-tool-use.sh), the counter bumps.
# At 3 → warn event, at 5 → breaker + nudge + 30s backoff.
violation_bump_counter "$REVIEWER_SAFE" "REVIEWER_WAIT" \
  "${SESSION_NAME:-}" "${DOEY_ROLE:-task_reviewer}" \
  "${CORE_WINDOW}" 2>/dev/null || true

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

  return 1
}

# ── Main flow ─────────────────────────────────────────────────────────

# Immediate check
_check_work "0" || true

# No work found — sleep
_sleep_dur=600
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
