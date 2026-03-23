#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

# Read unquoted value from env file: _env_val file key
_env_val() { local v; v=$(grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true; v="${v%\"}"; echo "${v#\"}"; }

# Single-pass read of session.env (avoid repeated grep subshells)
SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME=""
while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
  esac
done < "$SESSION_ENV"

# Pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Role detection
ROLE="worker"
TEAM_WINDOW="$WINDOW_INDEX"

if [ "$WINDOW_INDEX" = "0" ]; then
  sm_val=$(_env_val "$SESSION_ENV" SM_PANE)
  if [ "0.${PANE_INDEX}" = "${sm_val:-0.1}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  else
    for tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$tf" ] || continue
      wd_pane=$(_env_val "$tf" WATCHDOG_PANE)
      if [ "$wd_pane" = "0.${PANE_INDEX}" ]; then
        ROLE="watchdog"
        fn="${tf##*/}"
        TEAM_WINDOW="${fn#team_}"
        TEAM_WINDOW="${TEAM_WINDOW%.env}"
        break
      fi
    done
  fi
else
  mgr_pane=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
  [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="manager"
fi

# Compute pane identifiers
PROJECT_ACRONYM=$(_env_val "$SESSION_ENV" PROJECT_ACRONYM)
[ -z "$PROJECT_ACRONYM" ] && PROJECT_ACRONYM=$(echo "$PROJECT_NAME" | awk -F- '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-4)

case "$ROLE" in
  session_manager) PANE_ID="sm" ;;
  info_panel)      PANE_ID="info" ;;
  manager)         PANE_ID="t${WINDOW_INDEX}-mgr" ;;
  watchdog)        PANE_ID="t${TEAM_WINDOW}-wd" ;;
  worker)          PANE_ID="t${WINDOW_INDEX}-w${PANE_INDEX}" ;;
  *)               PANE_ID="t${WINDOW_INDEX}-p${PANE_INDEX}" ;;
esac
FULL_PANE_ID="${PROJECT_ACRONYM}-${PANE_ID}"

# Cache role per-pane for fast lookup by subsequent hooks
# NOTE: tmux set-environment is session-wide, so the last pane to start would
# overwrite everyone's role. Use per-pane files instead.
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${PANE_INDEX}" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"
echo "$ROLE" > "${RUNTIME_DIR}/status/${PANE_SAFE}.role"

wt_dir=$(_env_val "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)

# Sync doey skills from source repo into the working directory
_repo_path=""
[ -f "$HOME/.claude/doey/repo-path" ] && _repo_path=$(cat "$HOME/.claude/doey/repo-path")
if [ -n "$_repo_path" ] && [ -d "$_repo_path/.claude/skills" ]; then
  _skill_target="${wt_dir:-$PROJECT_DIR}"
  mkdir -p "$_skill_target/.claude/skills"
  LOCK_DIR="${RUNTIME_DIR}/.skill_sync_lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    _skill_lock_cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
    trap '_skill_lock_cleanup' EXIT
    for _sd in "$_repo_path"/.claude/skills/doey-*/; do
      [ -d "$_sd" ] || continue
      cp -R "$_sd" "$_skill_target/.claude/skills/"
    done
    for _sd in "$_skill_target"/.claude/skills/doey-*/; do
      [ -d "$_sd" ] || continue
      _sn="$(basename "$_sd")"
      [ ! -d "$_repo_path/.claude/skills/$_sn" ] && rm -rf "$_sd"
    done
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT
  else
    sleep 1
  fi
fi

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
EOF

# Pane title
case "$ROLE" in
  watchdog)        tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} Watchdog" ;;
  manager)         tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} Window Manager" ;;
  session_manager) tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} Session Manager" ;;
  worker)          tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} Worker" ;;
esac
