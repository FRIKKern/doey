#!/usr/bin/env bash
# Stop hook (async): respawn Claude in the same pane if a respawn request exists
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-respawn"

# Only proceed if a respawn was requested for this pane
RESPAWN_DIR="${RUNTIME_DIR}/respawn"
RESPAWN_REQ="${RESPAWN_DIR}/${PANE_SAFE}.request"
[ -f "$RESPAWN_REQ" ] || exit 0

_log "stop-respawn: respawn requested for ${PANE_SAFE}"

# Cooldown check: prevent rapid respawn loops (300s = 5 minutes)
COOLDOWN_FILE="${RESPAWN_DIR}/${PANE_SAFE}.cooldown"
if [ -f "$COOLDOWN_FILE" ]; then
  _last_respawn=$(cat "$COOLDOWN_FILE" 2>/dev/null) || _last_respawn=0
  _now=$(date +%s)
  if [ "$((_now - _last_respawn))" -lt 300 ]; then
    _log "stop-respawn: cooldown active for ${PANE_SAFE} ($((_now - _last_respawn))s < 300s)"
    echo "stop-respawn: cooldown active — refusing respawn for ${PANE_SAFE}" >&2
    _status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
    PROJECT_DIR=$(_resolve_project_dir)
    write_pane_status "$_status_file" "ERROR" "respawn-cooldown"
    rm -f "$RESPAWN_REQ" "${RESPAWN_REQ}.tmp" 2>/dev/null || true
    exit 1
  fi
fi

# Parse target pane from request file (PANE= line), default to self
TARGET_PANE="$PANE"
if [ -f "$RESPAWN_REQ" ]; then
  _req_pane=$(grep '^PANE=' "$RESPAWN_REQ" 2>/dev/null | head -1 | cut -d= -f2-) || _req_pane=""
  [ -n "$_req_pane" ] && TARGET_PANE="$_req_pane"
fi

# Verify the target pane still exists in tmux
if ! tmux display-message -t "$TARGET_PANE" -p '#{pane_pid}' >/dev/null 2>&1; then
  _log "stop-respawn: target pane ${TARGET_PANE} no longer exists — aborting"
  echo "stop-respawn: target pane ${TARGET_PANE} gone — aborting" >&2
  rm -f "$RESPAWN_REQ" "${RESPAWN_REQ}.tmp" 2>/dev/null || true
  exit 0
fi

# Ensure doey_send_command is available (common.sh sources doey-send.sh, but guard)
if ! type doey_send_command >/dev/null 2>&1; then
  for _try in \
    "$(cd "$(dirname "$0")/../../shell" 2>/dev/null && pwd)/doey-send.sh" \
    "$HOME/.local/bin/doey-send.sh"; do
    if [ -f "$_try" ]; then source "$_try"; break; fi
  done
  if ! type doey_send_command >/dev/null 2>&1; then
    _log_error "RESPAWN" "doey-send.sh not found — cannot respawn" "pane=$PANE_SAFE"
    rm -f "$RESPAWN_REQ" "${RESPAWN_REQ}.tmp" 2>/dev/null || true
    exit 0
  fi
fi

# Read the launch command — file-based or derive from role
LAUNCH_CMD=""
LAUNCH_CMD_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.launch_cmd"
if [ -f "$LAUNCH_CMD_FILE" ]; then
  LAUNCH_CMD=$(cat "$LAUNCH_CMD_FILE" 2>/dev/null) || LAUNCH_CMD=""
fi

# Derive default if no saved launch command
if [ -z "$LAUNCH_CMD" ]; then
  LAUNCH_CMD="claude --dangerously-skip-permissions --model opus"
  # Add settings file if present
  [ -f "${RUNTIME_DIR}/doey-settings.json" ] && \
    LAUNCH_CMD="${LAUNCH_CMD} --settings \"${RUNTIME_DIR}/doey-settings.json\""
fi

# Kill any existing Claude process in the target pane (SIGTERM → SIGKILL)
_pane_pid=$(tmux display-message -t "$TARGET_PANE" -p '#{pane_pid}' 2>/dev/null) || _pane_pid=""
if [ -n "$_pane_pid" ]; then
  _child_pid=$(pgrep -P "$_pane_pid" 2>/dev/null | head -1) || _child_pid=""
  if [ -n "$_child_pid" ]; then
    kill "$_child_pid" 2>/dev/null || true
    sleep 0.5
    # Retry with SIGKILL if still running
    _child_pid=$(pgrep -P "$_pane_pid" 2>/dev/null | head -1) || _child_pid=""
    [ -n "$_child_pid" ] && kill -9 "$_child_pid" 2>/dev/null || true
  fi
fi

sleep 2

# Relaunch Claude in the target pane
_log "stop-respawn: relaunching ${TARGET_PANE} with: ${LAUNCH_CMD}"
doey_send_command "$TARGET_PANE" "$LAUNCH_CMD"

# Write cooldown timestamp (atomic)
mkdir -p "$RESPAWN_DIR" 2>/dev/null || true
date +%s > "${COOLDOWN_FILE}.tmp" && mv "${COOLDOWN_FILE}.tmp" "$COOLDOWN_FILE"

# Cleanup request files
rm -f "$RESPAWN_REQ" "${RESPAWN_REQ}.tmp" 2>/dev/null || true

echo "stop-respawn: successfully relaunched ${TARGET_PANE}" >&2
_log "stop-respawn: respawn complete for ${PANE_SAFE}"
type _debug_log >/dev/null 2>&1 && _debug_log lifecycle "respawn" "pane=$PANE_SAFE" "target=$TARGET_PANE"

# Stats emit (task #521 Phase 2) — additive, silent-fail
if command -v doey-stats-emit.sh >/dev/null 2>&1; then
  (doey-stats-emit.sh worker worker_respawned "role=${DOEY_ROLE:-unknown}" "reason=respawn_request" &) 2>/dev/null || true
fi

exit 0
