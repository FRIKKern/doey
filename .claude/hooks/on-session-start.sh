#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

source "$(dirname "$0")/common.sh"
_DOEY_HOOK_NAME="on-session-start"
if type _init_debug >/dev/null 2>&1; then
  _init_debug; _debug_hook_entry
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME=""
while IFS='=' read -r key value; do
  value="${value%\"}"; value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
  esac
done < "$SESSION_ENV"

DOEY_LIB=""
if [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then DOEY_LIB="${PROJECT_DIR}/shell"
elif [ -f "$HOME/.local/bin/doey-task-helpers.sh" ]; then DOEY_LIB="$HOME/.local/bin"
fi

# Self-heal: ensure the project's hook files are in sync with the doey repo.
# Projects launched before new hooks were added (e.g. stop-reviewer-metrics.sh)
# can reference hooks in settings.local.json that don't exist on disk, producing
# "Stop hook error: ...: not found" errors. Re-sync when the repo hooks dir is
# newer than our sync marker, or the marker is missing.
_DOEY_REPO=""
[ -f "$HOME/.claude/doey/repo-path" ] && _DOEY_REPO=$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null) || true
if [ -n "$_DOEY_REPO" ] && [ -n "$PROJECT_DIR" ] && [ "$_DOEY_REPO" != "$PROJECT_DIR" ] \
   && [ -d "${_DOEY_REPO}/.claude/hooks" ] && [ -d "${PROJECT_DIR}/.claude/hooks" ]; then
  _DOEY_SYNC_MARKER="${PROJECT_DIR}/.claude/hooks/.doey-synced"
  if [ ! -f "$_DOEY_SYNC_MARKER" ] || [ "${_DOEY_REPO}/.claude/hooks" -nt "$_DOEY_SYNC_MARKER" ]; then
    cp -f "${_DOEY_REPO}/.claude/hooks/"*.sh "${PROJECT_DIR}/.claude/hooks/" 2>/dev/null || true
    chmod +x "${PROJECT_DIR}/.claude/hooks/"*.sh 2>/dev/null || true
    touch -r "${_DOEY_REPO}/.claude/hooks" "$_DOEY_SYNC_MARKER" 2>/dev/null || \
      touch "$_DOEY_SYNC_MARKER" 2>/dev/null || true
  fi
  unset _DOEY_SYNC_MARKER
fi
unset _DOEY_REPO

# Ensure .doey/.gitignore contains discord-binding (Phase 1 of Discord integration).
# Idempotent: grep -q ... || echo >>. Tolerates parallel sessions appending the same
# line (race only produces at most one duplicate, which `grep -q` will then detect).
# Silent on failure — never break session start if .doey/ is read-only.
if [ -n "$PROJECT_DIR" ] && [ -d "${PROJECT_DIR}/.doey" ]; then
  _gi="${PROJECT_DIR}/.doey/.gitignore"
  touch "$_gi" 2>/dev/null || true
  grep -q '^discord-binding$' "$_gi" 2>/dev/null || echo 'discord-binding' >> "$_gi" 2>/dev/null || true
  unset _gi
fi

REMOTE=$(grep '^REMOTE=' "$SESSION_ENV" 2>/dev/null | head -1 | cut -d= -f2-) || true
TUNNEL_URL=""
[ -f "${RUNTIME_DIR}/tunnel.env" ] && TUNNEL_URL=$(grep '^TUNNEL_URL=' "${RUNTIME_DIR}/tunnel.env" 2>/dev/null | head -1 | cut -d= -f2-) || true

# Pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

ROLE="$DOEY_ROLE_ID_WORKER"
TEAM_WINDOW="$WINDOW_INDEX"

# Extract Core Team window from TASKMASTER_PANE
_core_team_window=""
_tm_pane_val=$(_read_team_key "$SESSION_ENV" TASKMASTER_PANE)
[ -n "$_tm_pane_val" ] && _core_team_window="${_tm_pane_val%%.*}"

if [ "$WINDOW_INDEX" = "0" ]; then
  # Dashboard window
  case "$PANE_INDEX" in
    0) ROLE="info_panel" ;;
    1) ROLE="$DOEY_ROLE_ID_BOSS" ;;
  esac
elif [ -n "$_core_team_window" ] && [ "$WINDOW_INDEX" = "$_core_team_window" ]; then
  # Core Team window
  case "$PANE_INDEX" in
    0) ROLE="$DOEY_ROLE_ID_COORDINATOR" ;;
    1) ROLE="$DOEY_ROLE_ID_TASK_REVIEWER" ;;
    2) ROLE="$DOEY_ROLE_ID_DEPLOYMENT" ;;
    3) ROLE="$DOEY_ROLE_ID_DOEY_EXPERT" ;;
  esac
else
  # Worker team window
  _team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  _team_type=""; [ -f "$_team_file" ] && _team_type=$(_read_team_key "$_team_file" TEAM_TYPE)
  if [ "$_team_type" != "$DOEY_ROLE_ID_FREELANCER" ]; then
    mgr_pane=""; [ -f "$_team_file" ] && mgr_pane=$(_read_team_key "$_team_file" MANAGER_PANE)
    [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="$DOEY_ROLE_ID_TEAM_LEAD"
  fi
fi

PROJECT_ACRONYM=$(_read_team_key "$SESSION_ENV" PROJECT_ACRONYM)
[ -z "$PROJECT_ACRONYM" ] && PROJECT_ACRONYM=$(echo "$PROJECT_NAME" | awk -F- '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-4)

case "$ROLE" in
  "$DOEY_ROLE_ID_BOSS")            PANE_ID="boss" ;;
  "$DOEY_ROLE_ID_COORDINATOR") PANE_ID="taskmaster" ;;
  info_panel)      PANE_ID="info" ;;
  "$DOEY_ROLE_ID_TASK_REVIEWER") PANE_ID="task-reviewer" ;;
  "$DOEY_ROLE_ID_DEPLOYMENT")    PANE_ID="deployment" ;;
  "$DOEY_ROLE_ID_DOEY_EXPERT")   PANE_ID="doey-expert" ;;
  "$DOEY_ROLE_ID_TEAM_LEAD")         PANE_ID="t${WINDOW_INDEX}-mgr" ;;
  "$DOEY_ROLE_ID_WORKER")
    if [ "${_team_type:-}" = "$DOEY_ROLE_ID_FREELANCER" ]; then
      PANE_ID="t${WINDOW_INDEX}-f${PANE_INDEX}"
    else
      PANE_ID="t${WINDOW_INDEX}-w${PANE_INDEX}"
    fi
    ;;
  *)               PANE_ID="t${WINDOW_INDEX}-p${PANE_INDEX}" ;;
esac
FULL_PANE_ID="${PROJECT_ACRONYM}-${PANE_ID}"

PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${PANE_INDEX}" | tr ':.-' '_')
mkdir -p "${RUNTIME_DIR}/status" "${RUNTIME_DIR}/scratchpad" "${RUNTIME_DIR}/lifecycle" "${RUNTIME_DIR}/ready"
atomic_write "${RUNTIME_DIR}/status/${PANE_SAFE}.role" "$ROLE"

# Emit ready marker — the genuine "Claude is booted in this pane" signal.
# `doey wait-for-ready <W.P>` inotify-watches this directory, so callers can
# block on a real hello instead of polling fake-READY status files.
touch "${RUNTIME_DIR}/ready/pane_${WINDOW_INDEX}_${PANE_INDEX}" 2>/dev/null || true

# Write BOOTING status so other components know this pane exists but isn't ready yet.
# Skip if status is already READY — doey.sh pre-writes READY for key panes so the
# loading screen can detect them immediately. Overwriting would create a race where
# the loading screen sees BOOTING and hangs until a briefing flips it back.
if [ "$ROLE" != "info_panel" ]; then
  _existing_status=""
  if [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.status" ]; then
    _existing_status=$(grep '^STATUS: ' "${RUNTIME_DIR}/status/${PANE_SAFE}.status" 2>/dev/null | head -1 | cut -d' ' -f2-) || _existing_status=""
  fi
  if [ "$_existing_status" != "READY" ]; then
    transition_state "$PANE_SAFE" "BOOTING"
  fi
  emit_lifecycle_event "pane_boot" "$PANE_SAFE" "" "" "{\"role\":\"${ROLE}\"}"
fi

# Save launch command for respawn replay (stop-respawn.sh reads this)
if [ -f "/proc/$PPID/cmdline" ]; then
  tr '\0' ' ' < "/proc/$PPID/cmdline" \
    > "${RUNTIME_DIR}/status/${PANE_SAFE}.launch_cmd.tmp" \
    && mv "${RUNTIME_DIR}/status/${PANE_SAFE}.launch_cmd.tmp" \
          "${RUNTIME_DIR}/status/${PANE_SAFE}.launch_cmd"
fi

# Clean up stale respawn request files (orphaned from dead agents)
if [ -d "${RUNTIME_DIR}/respawn" ]; then
  find "${RUNTIME_DIR}/respawn" -name "*.request" -mmin +1 -delete 2>/dev/null || true
fi

wt_dir=$(_read_team_key "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)
_team_task_id=$(_read_team_key "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" TASK_ID)

_repo_path=""
[ -f "$HOME/.claude/doey/repo-path" ] && _repo_path=$(cat "$HOME/.claude/doey/repo-path")
if [ -n "$_repo_path" ] && [ -d "$_repo_path/.claude/skills" ]; then
  _skill_target="${wt_dir:-$PROJECT_DIR}"
  # Skip sync when source and target are the same directory (e.g. running inside the Doey repo)
  _src_canon="$(cd "$_repo_path" 2>/dev/null && pwd)" || _src_canon="$_repo_path"
  _tgt_canon="$(cd "$_skill_target" 2>/dev/null && pwd)" || _tgt_canon="$_skill_target"
  if [ "$_src_canon" = "$_tgt_canon" ]; then
    _repo_path=""
  fi
fi
if [ -n "$_repo_path" ] && [ -d "$_repo_path/.claude/skills" ]; then
  _skill_target="${wt_dir:-$PROJECT_DIR}"
  mkdir -p "$_skill_target/.claude/skills"
  LOCK_DIR="${RUNTIME_DIR}/.skill_sync_lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
    for _sd in "$_repo_path"/.claude/skills/doey-*/; do
      [ -d "$_sd" ] && cp -R "$_sd" "$_skill_target/.claude/skills/"
    done
    for _sd in "$_skill_target"/.claude/skills/doey-*/; do
      [ -d "$_sd" ] || continue
      [ ! -d "$_repo_path/.claude/skills/$(basename "$_sd")" ] && rm -rf "$_sd"
    done
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT
  else
    sleep 1
  fi
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ] && touch "$CLAUDE_ENV_FILE" 2>/dev/null; then
  cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_RUNTIME="$RUNTIME_DIR"
export SESSION_NAME="$SESSION_NAME"
export PROJECT_DIR="$PROJECT_DIR"
export PROJECT_NAME="$PROJECT_NAME"
export DOEY_ROLE="$ROLE"
export DOEY_PANE_INDEX="$PANE_INDEX"
export DOEY_WINDOW_INDEX="$WINDOW_INDEX"
export DOEY_TEAM_WINDOW="$TEAM_WINDOW"
export DOEY_TEAM_DIR="${wt_dir:-$PROJECT_DIR}"
export DOEY_PROJECT_ACRONYM="$PROJECT_ACRONYM"
export DOEY_PANE_ID="$PANE_ID"
export DOEY_FULL_PANE_ID="$FULL_PANE_ID"
export DOEY_PANE_SAFE="$PANE_SAFE"
export DOEY_REMOTE="${REMOTE:-false}"
export DOEY_TUNNEL_URL="${TUNNEL_URL:-}"
export DOEY_LIB="${DOEY_LIB}"
export DOEY_SCRATCHPAD="${RUNTIME_DIR}/scratchpad"
export DOEY_USER_PANES="0.1"
EOF
  # Propagate TASK_ID from ephemeral team env to worker
  if [ -n "${_team_task_id:-}" ]; then
    echo "export DOEY_TASK_ID=\"${_team_task_id}\"" >> "$CLAUDE_ENV_FILE"
  fi
  # Unattended mode — non-Boss panes auto-accept hooks
  if [ "$ROLE" != "$DOEY_ROLE_ID_BOSS" ] && [ "$ROLE" != "info_panel" ]; then
    echo "export DOEY_UNATTENDED=true" >> "$CLAUDE_ENV_FILE"
  fi
fi

_team_def=$(grep '^TEAM_DEF=' "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
if [ -n "$_team_def" ]; then
  _teamdef_env="${RUNTIME_DIR}/teamdef_${_team_def}.env"
  if [ -f "$_teamdef_env" ]; then
    _team_role=$(grep "^PANE_${PANE_INDEX}_ROLE=" "$_teamdef_env" 2>/dev/null | cut -d= -f2-) || true
    _team_pane_name=$(grep "^PANE_${PANE_INDEX}_NAME=" "$_teamdef_env" 2>/dev/null | cut -d= -f2-) || true
    if [ -w "$CLAUDE_ENV_FILE" ]; then
      [ -n "$_team_role" ] && echo "DOEY_TEAM_ROLE=$_team_role" >> "$CLAUDE_ENV_FILE"
      [ -n "$_team_pane_name" ] && echo "DOEY_TEAM_PANE_NAME=$_team_pane_name" >> "$CLAUDE_ENV_FILE"
    fi
    [ -n "$_team_role" ] && [ -n "${PANE_SAFE:-}" ] && \
      echo "$_team_role" > "${RUNTIME_DIR}/status/${PANE_SAFE}.team_role"
  fi
fi

# --- Context overlay injection ---
# Project-specific per-role context files from .doey/context/
_overlay_base="${wt_dir:-$PROJECT_DIR}/.doey/context"
_overlay_role=""
_overlay_all=""
# Priority 1: team-specific role overlay (e.g., seo-technical.md)
if [ -n "${_team_role:-}" ] && [ -f "${_overlay_base}/${_team_role}.md" ]; then
  _overlay_role="${_overlay_base}/${_team_role}.md"
# Priority 2: base role overlay (e.g., worker.md, coordinator.md)
elif [ -f "${_overlay_base}/${ROLE}.md" ]; then
  _overlay_role="${_overlay_base}/${ROLE}.md"
fi
# Always check for all.md (shared context across all roles)
if [ -f "${_overlay_base}/all.md" ]; then
  _overlay_all="${_overlay_base}/all.md"
fi
# Export paths via CLAUDE_ENV_FILE so agents/hooks can read them
if [ -w "${CLAUDE_ENV_FILE:-/dev/null}" ]; then
  [ -n "$_overlay_role" ] && echo "export DOEY_CONTEXT_OVERLAY=\"${_overlay_role}\"" >> "$CLAUDE_ENV_FILE"
  [ -n "$_overlay_all" ] && echo "export DOEY_CONTEXT_OVERLAY_ALL=\"${_overlay_all}\"" >> "$CLAUDE_ENV_FILE"
fi

_TITLE=""
case "$ROLE" in
  "$DOEY_ROLE_ID_BOSS")            _TITLE="${PROJECT_NAME} ${DOEY_ROLE_BOSS}" ;;
  "$DOEY_ROLE_ID_TEAM_LEAD")         _TITLE="${PROJECT_NAME} T${WINDOW_INDEX} ${DOEY_ROLE_TEAM_LEAD}" ;;
  "$DOEY_ROLE_ID_COORDINATOR") _TITLE="${PROJECT_NAME} ${DOEY_ROLE_COORDINATOR}" ;;
  "$DOEY_ROLE_ID_TASK_REVIEWER") _TITLE="${PROJECT_NAME} ${DOEY_ROLE_TASK_REVIEWER}" ;;
  "$DOEY_ROLE_ID_DEPLOYMENT")    _TITLE="${PROJECT_NAME} ${DOEY_ROLE_DEPLOYMENT}" ;;
  "$DOEY_ROLE_ID_DOEY_EXPERT")   _TITLE="${PROJECT_NAME} ${DOEY_ROLE_DOEY_EXPERT}" ;;
  "$DOEY_ROLE_ID_WORKER")          _TITLE=$([ "${_team_type:-}" = "$DOEY_ROLE_ID_FREELANCER" ] && echo "$DOEY_ROLE_FREELANCER" || echo "$DOEY_ROLE_WORKER") ;;
esac
[ -n "$_TITLE" ] && tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} | ${_TITLE}" 2>/dev/null || true

type _debug_log >/dev/null 2>&1 && \
  _debug_log lifecycle "session_start" "role=${ROLE:-unknown}" "team_window=${WINDOW_INDEX:-0}" "project=${PROJECT_NAME:-unknown}"

# Refresh agent registry in SQLite (fast, idempotent)
# Only run for first pane in session to avoid redundant work
if [ "${PANE_INDEX:-0}" = "0" ] && [ "${WINDOW_INDEX:-0}" = "0" ]; then
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    doey migrate --project-dir "$PROJECT_DIR" --runtime "${RUNTIME_DIR:-}" 2>/dev/null &
  fi
fi

# ── Stats system (task #521 Phase 1) ──────────────────────────────────
# 1) Atomic per-session UUID: first-writer-wins. All subsequent panes in
#    the same runtime dir read the same DOEY_SESSION_ID so emitted events
#    can be grouped by launch. Canonical path/format matches
#    shell/doey-stats.sh fallback reader: ${DOEY_RUNTIME}/session_id
#    containing a single raw UUID line (no keyval prefix).
export DOEY_RUNTIME="${RUNTIME_DIR}"
_sf="${DOEY_RUNTIME%/}/session_id"
if [ ! -f "$_sf" ]; then
  _tmp="$_sf.tmp.$$"
  _id="$(uuidgen 2>/dev/null || echo "s$(date +%s)-$$-${RANDOM:-0}")"
  printf '%s\n' "$_id" > "$_tmp" 2>/dev/null || true
  mv -n "$_tmp" "$_sf" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
fi
if [ -r "$_sf" ]; then
  DOEY_SESSION_ID=""
  IFS= read -r DOEY_SESSION_ID < "$_sf" 2>/dev/null || DOEY_SESSION_ID=""
  export DOEY_SESSION_ID
fi
unset _sf _tmp _id

# 2) session_start emit — one per pane/session attach, silent-fail.
#    install_run sentinel is owned by doey-stats-emit.sh (fires once per
#    runtime dir after the first session_start).
(command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh session session_start "role=${ROLE:-unknown}" "window=${WINDOW_INDEX:-0}" "pane=${PANE_INDEX:-0}" &) 2>/dev/null || true

emit_lifecycle_event "pane_ready" "$PANE_SAFE" "" "" "{\"role\":\"${ROLE}\"}"

exit 0
