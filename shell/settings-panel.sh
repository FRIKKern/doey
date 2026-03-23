#!/bin/bash
# Doey Settings Panel — shows configuration values, swappable with Info Panel via Prefix+S
set -uo pipefail

RUNTIME_DIR="${1:-${DOEY_RUNTIME:-}}"
if [ -z "$RUNTIME_DIR" ]; then
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
fi

# Colors
C_RESET='\033[0m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_BOLD_CYAN='\033[1;36m'
C_BOLD_WHITE='\033[1;97m'
C_BOLD_GREEN='\033[1;32m'

repeat_char() {
  local ch="$1" len="$2" out="" i=0
  while [ "$i" -lt "$len" ]; do out="${out}${ch}"; i=$((i + 1)); done
  printf '%s' "$out"
}

_config_val() {
  local var="$1"
  local global_config="${HOME}/.config/doey/config.sh"
  local project_config=""
  # Find project config via RUNTIME_DIR -> PROJECT_DIR
  if [ -n "$RUNTIME_DIR" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
    local proj_dir
    proj_dir=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    [ -n "$proj_dir" ] && [ -f "${proj_dir}/.doey/config.sh" ] && project_config="${proj_dir}/.doey/config.sh"
  fi
  # Check project config first (highest priority), then global
  local val=""
  if [ -n "$project_config" ] && [ -f "$project_config" ]; then
    val=$(bash -c "source '$project_config' 2>/dev/null; echo \"\${$var:-}\"")
    [ -n "$val" ] && printf '%s' "$val" && return 0
  fi
  if [ -f "$global_config" ]; then
    val=$(bash -c "source '$global_config' 2>/dev/null; echo \"\${$var:-}\"")
    [ -n "$val" ] && printf '%s' "$val" && return 0
  fi
  return 1
}

_settings_row() {
  local var_name="$1" default_val="$2" current_val="$3"
  local config_val indicator label dots_needed name_len val_len
  if config_val=$(_config_val "$var_name") && [ "$config_val" != "$default_val" ]; then
    indicator="$(printf '%b●%b' "${C_BOLD_GREEN}" "${C_RESET}")"
    label="$(printf '%s  (custom)' "$current_val")"
  else
    indicator="$(printf '%b○%b' "${C_DIM}" "${C_RESET}")"
    label="$current_val"
  fi
  name_len=${#var_name}
  val_len=${#label}
  dots_needed=$((50 - name_len - val_len))
  [ "$dots_needed" -lt 2 ] && dots_needed=2
  printf '    %s %s %b%s%b %s\n' "$indicator" "$var_name" "${C_DIM}" "$(repeat_char '.' "$dots_needed")" "${C_RESET}" "$label"
}

_doey_load_config() {
  local config_file="${DOEY_CONFIG:-${HOME}/.config/doey/config.sh}"
  [ -f "$config_file" ] && source "$config_file"
  # Overlay project config if available
  if [ -n "$RUNTIME_DIR" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
    local proj_dir
    proj_dir=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [ -n "$proj_dir" ] && [ -f "${proj_dir}/.doey/config.sh" ]; then
      source "${proj_dir}/.doey/config.sh"
    fi
  fi
}

_render_teams() {
  local _tw _wc _wt _mm _wm _tn _tr _line _detail _type _team_file
  printf '  %b Teams%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  if [ -z "${RUNTIME_DIR:-}" ] || [ ! -d "${RUNTIME_DIR:-}" ]; then
    printf '    %b(no runtime data)%b\n' "${C_DIM}" "${C_RESET}"
    return
  fi
  _tw=""
  [ -f "${RUNTIME_DIR}/session.env" ] && \
    _tw=$(grep '^TEAM_WINDOWS=' "${RUNTIME_DIR}/session.env" | cut -d= -f2- | tr -d '"')
  if [ -z "$_tw" ]; then
    printf '    %b(no active session)%b\n' "${C_DIM}" "${C_RESET}"
    return
  fi
  for _w in $(echo "$_tw" | tr ',' ' '); do
    _team_file="${RUNTIME_DIR}/team_${_w}.env"
    [ -f "$_team_file" ] || continue
    _wc=$(grep '^WORKER_COUNT=' "$_team_file" | cut -d= -f2- | tr -d '"')
    _wt=$(grep '^WORKTREE_DIR=' "$_team_file" | cut -d= -f2- | tr -d '"')
    _mm=$(grep '^MANAGER_MODEL=' "$_team_file" | cut -d= -f2- | tr -d '"')
    _wm=$(grep '^WORKER_MODEL=' "$_team_file" | cut -d= -f2- | tr -d '"')
    _tn=$(grep '^TEAM_NAME=' "$_team_file" | cut -d= -f2- | tr -d '"')
    _tr=$(grep '^TEAM_ROLE=' "$_team_file" | cut -d= -f2- | tr -d '"')
    _type="local"
    [ -n "$_wt" ] && _type="worktree"
    _line="Team ${_w}"
    [ -n "$_tn" ] && _line="${_tn}"
    _detail="${_wc:-0} workers (${_type})"
    [ -n "$_mm" ] && _detail="${_detail} — mgr:${_mm}"
    [ -n "$_wm" ] && _detail="${_detail} wkr:${_wm}"
    [ -n "$_tr" ] && _detail="${_detail} [${_tr}]"
    printf '    %b●%b %s %b..%b %s\n' "${C_GREEN}" "${C_RESET}" "$_line" "${C_DIM}" "${C_RESET}" "$_detail"
  done
}

while true; do
  _doey_load_config
  DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"

  DOEY_INITIAL_WORKER_COLS="${DOEY_INITIAL_WORKER_COLS:-3}"
  DOEY_INITIAL_TEAMS="${DOEY_INITIAL_TEAMS:-2}"
  DOEY_INITIAL_WORKTREE_TEAMS="${DOEY_INITIAL_WORKTREE_TEAMS:-2}"
  DOEY_MAX_WORKERS="${DOEY_MAX_WORKERS:-20}"
  DOEY_MAX_WATCHDOG_SLOTS="${DOEY_MAX_WATCHDOG_SLOTS:-6}"
  DOEY_WORKER_LAUNCH_DELAY="${DOEY_WORKER_LAUNCH_DELAY:-3}"
  DOEY_TEAM_LAUNCH_DELAY="${DOEY_TEAM_LAUNCH_DELAY:-15}"
  DOEY_MANAGER_LAUNCH_DELAY="${DOEY_MANAGER_LAUNCH_DELAY:-3}"
  DOEY_WATCHDOG_LAUNCH_DELAY="${DOEY_WATCHDOG_LAUNCH_DELAY:-3}"
  DOEY_MANAGER_BRIEF_DELAY="${DOEY_MANAGER_BRIEF_DELAY:-15}"
  DOEY_WATCHDOG_BRIEF_DELAY="${DOEY_WATCHDOG_BRIEF_DELAY:-20}"
  DOEY_WATCHDOG_LOOP_DELAY="${DOEY_WATCHDOG_LOOP_DELAY:-25}"
  DOEY_IDLE_COLLAPSE_AFTER="${DOEY_IDLE_COLLAPSE_AFTER:-60}"
  DOEY_IDLE_REMOVE_AFTER="${DOEY_IDLE_REMOVE_AFTER:-300}"
  DOEY_PASTE_SETTLE_MS="${DOEY_PASTE_SETTLE_MS:-500}"
  DOEY_MANAGER_MODEL="${DOEY_MANAGER_MODEL:-opus}"
  DOEY_WORKER_MODEL="${DOEY_WORKER_MODEL:-sonnet}"
  DOEY_WATCHDOG_MODEL="${DOEY_WATCHDOG_MODEL:-haiku}"
  DOEY_SESSION_MANAGER_MODEL="${DOEY_SESSION_MANAGER_MODEL:-opus}"

  printf '\033[2J\033[H'

  TERM_W=$(tput cols 2>/dev/null || echo 80)
  HR=$(repeat_char "=" "$TERM_W")

  printf '\n'
  printf '  %b⚙  DOEY SETTINGS%b\n' "${C_BOLD_CYAN}" "${C_RESET}"
  printf '  %b%s%b\n\n' "${C_DIM}" "$HR" "${C_RESET}"

  # Config hierarchy display
  _GLOBAL_CONFIG="${HOME}/.config/doey/config.sh"
  _PROJECT_CONFIG=""
  if [ -n "$RUNTIME_DIR" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
    _PROJ_DIR=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" | cut -d= -f2- | tr -d '"')
    [ -n "$_PROJ_DIR" ] && [ -f "${_PROJ_DIR}/.doey/config.sh" ] && _PROJECT_CONFIG="${_PROJ_DIR}/.doey/config.sh"
  fi

  if [ -f "$_GLOBAL_CONFIG" ]; then
    printf '  %bConfig (global):%b  %s %b(loaded)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_GLOBAL_CONFIG" "${C_GREEN}" "${C_RESET}"
  else
    printf '  %bConfig (global):%b  %s %b(not found — using defaults)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_GLOBAL_CONFIG" "${C_DIM}" "${C_RESET}"
  fi
  if [ -n "$_PROJECT_CONFIG" ]; then
    printf '  %bConfig (project):%b %s %b(loaded — overrides global)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_PROJECT_CONFIG" "${C_GREEN}" "${C_RESET}"
  fi
  printf '\n'

  printf '  %b Grid & Teams%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_INITIAL_WORKER_COLS"    "3"   "$DOEY_INITIAL_WORKER_COLS"
  _settings_row "DOEY_INITIAL_TEAMS"          "2"   "$DOEY_INITIAL_TEAMS"
  _settings_row "DOEY_INITIAL_WORKTREE_TEAMS" "2"   "$DOEY_INITIAL_WORKTREE_TEAMS"
  _settings_row "DOEY_MAX_WORKERS"            "20"  "$DOEY_MAX_WORKERS"
  _settings_row "DOEY_MAX_WATCHDOG_SLOTS"     "6"   "$DOEY_MAX_WATCHDOG_SLOTS"
  printf '\n'

  printf '  %b Models%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_MANAGER_MODEL"          "opus"    "$DOEY_MANAGER_MODEL"
  _settings_row "DOEY_WORKER_MODEL"           "sonnet"  "$DOEY_WORKER_MODEL"
  _settings_row "DOEY_WATCHDOG_MODEL"         "haiku"   "$DOEY_WATCHDOG_MODEL"
  _settings_row "DOEY_SESSION_MANAGER_MODEL"  "opus"    "$DOEY_SESSION_MANAGER_MODEL"
  printf '\n'

  printf '  %b Auth & Launch Timing%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_WORKER_LAUNCH_DELAY"    "3"   "$DOEY_WORKER_LAUNCH_DELAY"
  _settings_row "DOEY_TEAM_LAUNCH_DELAY"      "15"  "$DOEY_TEAM_LAUNCH_DELAY"
  _settings_row "DOEY_MANAGER_LAUNCH_DELAY"   "3"   "$DOEY_MANAGER_LAUNCH_DELAY"
  _settings_row "DOEY_WATCHDOG_LAUNCH_DELAY"  "3"   "$DOEY_WATCHDOG_LAUNCH_DELAY"
  _settings_row "DOEY_MANAGER_BRIEF_DELAY"    "15"  "$DOEY_MANAGER_BRIEF_DELAY"
  _settings_row "DOEY_WATCHDOG_BRIEF_DELAY"   "20"  "$DOEY_WATCHDOG_BRIEF_DELAY"
  _settings_row "DOEY_WATCHDOG_LOOP_DELAY"    "25"  "$DOEY_WATCHDOG_LOOP_DELAY"
  printf '\n'

  printf '  %b Dynamic Grid Behavior%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_IDLE_COLLAPSE_AFTER"    "60"  "$DOEY_IDLE_COLLAPSE_AFTER"
  _settings_row "DOEY_IDLE_REMOVE_AFTER"      "300" "$DOEY_IDLE_REMOVE_AFTER"
  _settings_row "DOEY_PASTE_SETTLE_MS"        "500" "$DOEY_PASTE_SETTLE_MS"
  printf '\n'

  _render_teams
  printf '\n'

  printf '  %b%s%b\n' "${C_DIM}" "$HR" "${C_RESET}"
  printf '  %bdoey config%b to edit  %b│%b  %bdoey config --reset%b to reset  %b│%b  %bdoey reload%b to apply\n' \
    "${C_BOLD_WHITE}" "${C_RESET}" "${C_DIM}" "${C_RESET}" \
    "${C_BOLD_WHITE}" "${C_RESET}" "${C_DIM}" "${C_RESET}" \
    "${C_BOLD_WHITE}" "${C_RESET}"
  printf '\n  %bPrefix + S%b to toggle back to Dashboard\n' "${C_BOLD_CYAN}" "${C_RESET}"

  sleep "$DOEY_INFO_PANEL_REFRESH"
done
