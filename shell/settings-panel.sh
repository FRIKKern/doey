#!/usr/bin/env bash
# Doey Settings Panel — interactive TUI with cursor navigation, inline editing,
# team management, and agent property editing.
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
C_RED='\033[31m'
C_RED_DIM='\033[2;31m'
C_CYAN_DIM='\033[2;36m'
C_YELLOW='\033[33m'
C_BOLD_YELLOW='\033[1;33m'
C_REVERSE='\033[7m'

repeat_char() {
  local ch="$1" len="$2" out="" i=0
  while [ "$i" -lt "$len" ]; do out="${out}${ch}"; i=$((i + 1)); done
  printf '%s' "$out"
}

# Resolve project directory from session.env. Prints path or "." if unavailable.
_get_proj_dir() {
  local _d=""
  if [ -n "${RUNTIME_DIR:-}" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
    _d=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
  fi
  printf '%s' "${_d:-.}"
}

_config_val() {
  local var="$1" val=""
  local global_config="${HOME}/.config/doey/config.sh"
  local proj_dir project_config=""
  proj_dir=$(_get_proj_dir)
  [ -f "${proj_dir}/.doey/config.sh" ] && project_config="${proj_dir}/.doey/config.sh"
  # Project config (highest priority), then global
  for cfg in "$project_config" "$global_config"; do
    [ -n "$cfg" ] && [ -f "$cfg" ] || continue
    val=$(bash -c "source '$cfg' 2>/dev/null; echo \"\${$var:-}\"")
    [ -n "$val" ] && printf '%s' "$val" && return 0
  done
  return 1
}

_doey_load_config() {
  local config_file="${DOEY_CONFIG:-${HOME}/.config/doey/config.sh}" proj_dir
  [ -f "$config_file" ] && source "$config_file"
  proj_dir=$(_get_proj_dir)
  [ -f "${proj_dir}/.doey/config.sh" ] && source "${proj_dir}/.doey/config.sh"
}

_parse_agent_frontmatter() {
  local agent_file="$1" field="$2"
  [ -f "$agent_file" ] || return 1
  local in_front=false val=""
  while IFS= read -r line; do
    case "$line" in
      ---) if [ "$in_front" = false ]; then in_front=true; continue; else break; fi ;;
    esac
    if [ "$in_front" = true ]; then
      case "$line" in
        "${field}:"*) val=$(echo "$line" | sed "s/^${field}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//'); break ;;
      esac
    fi
  done < "$agent_file"
  [ -n "$val" ] && printf '%s' "$val"
}

_truncate() {
  local str="$1" max="$2"
  if [ ${#str} -gt "$max" ]; then
    printf '%s...' "$(printf '%.'"$((max - 3))"'s' "$str")"
  else
    printf '%s' "$str"
  fi
}

# ── Cursor State Management ──────────────────────────────────────────────────

_CURSOR_POS=0
_CURSOR_MAX=0
_EDIT_MODE=false
_EDIT_VAR=""
_STATUS_MSG=""
_STATUS_EXPIRE=0

_read_cursor() {
  local view="$1"
  local cursor_file="${RUNTIME_DIR}/status/settings_cursor_${view}"
  if [ -f "$cursor_file" ]; then
    _CURSOR_POS=$(cat "$cursor_file" 2>/dev/null)
    # Ensure numeric
    case "$_CURSOR_POS" in
      *[!0-9]*) _CURSOR_POS=0 ;;
    esac
  else
    _CURSOR_POS=0
  fi
}

_write_cursor() {
  local view="$1" pos="$2"
  local cursor_file="${RUNTIME_DIR}/status/settings_cursor_${view}"
  mkdir -p "${RUNTIME_DIR}/status" 2>/dev/null || true
  echo "$pos" > "$cursor_file"
}

_cursor_move() {
  local direction="$1" view="$2"
  if [ "$direction" = "up" ]; then
    _CURSOR_POS=$((_CURSOR_POS - 1))
    [ "$_CURSOR_POS" -lt 0 ] && _CURSOR_POS=$((_CURSOR_MAX - 1))
  else
    _CURSOR_POS=$((_CURSOR_POS + 1))
    [ "$_CURSOR_POS" -ge "$_CURSOR_MAX" ] && _CURSOR_POS=0
  fi
  _write_cursor "$view" "$_CURSOR_POS"
}

# ── Validation ───────────────────────────────────────────────────────────────

# Validate a setting value. Returns 0 if valid, 1 if not.
# Prints error message on failure.
_validate_setting() {
  local var="$1" val="$2"
  case "$var" in
    DOEY_MANAGER_MODEL|DOEY_WORKER_MODEL|DOEY_WATCHDOG_MODEL|DOEY_SESSION_MANAGER_MODEL)
      case "$val" in
        opus|sonnet|haiku) return 0 ;;
        *) printf 'Must be: opus, sonnet, or haiku'; return 1 ;;
      esac
      ;;
    DOEY_INITIAL_WORKER_COLS)
      case "$val" in *[!0-9]*) printf 'Must be a number 1-6'; return 1 ;; esac
      [ "$val" -ge 1 ] && [ "$val" -le 6 ] && return 0
      printf 'Must be 1-6'; return 1
      ;;
    DOEY_INITIAL_TEAMS)
      case "$val" in *[!0-9]*) printf 'Must be a number 1-10'; return 1 ;; esac
      [ "$val" -ge 1 ] && [ "$val" -le 10 ] && return 0
      printf 'Must be 1-10'; return 1
      ;;
    DOEY_INITIAL_WORKTREE_TEAMS|DOEY_INITIAL_FREELANCER_TEAMS)
      case "$val" in *[!0-9]*) printf 'Must be a number 0-10'; return 1 ;; esac
      [ "$val" -ge 0 ] && [ "$val" -le 10 ] && return 0
      printf 'Must be 0-10'; return 1
      ;;
    DOEY_MAX_WORKERS)
      case "$val" in *[!0-9]*) printf 'Must be a number 1-50'; return 1 ;; esac
      [ "$val" -ge 1 ] && [ "$val" -le 50 ] && return 0
      printf 'Must be 1-50'; return 1
      ;;
    DOEY_MAX_WATCHDOG_SLOTS)
      case "$val" in *[!0-9]*) printf 'Must be a number 1-6'; return 1 ;; esac
      [ "$val" -ge 1 ] && [ "$val" -le 6 ] && return 0
      printf 'Must be 1-6'; return 1
      ;;
    DOEY_INFO_PANEL_REFRESH)
      case "$val" in *[!0-9]*) printf 'Must be a number >= 1'; return 1 ;; esac
      [ "$val" -ge 1 ] && return 0
      printf 'Must be >= 1'; return 1
      ;;
    *)
      # All timing/delay vars: number >= 1
      case "$val" in *[!0-9]*) printf 'Must be a number >= 1'; return 1 ;; esac
      [ "$val" -ge 1 ] && return 0
      printf 'Must be >= 1'; return 1
      ;;
  esac
}

# Get validation hint for a setting (shown in edit prompt)
_validation_hint() {
  local var="$1"
  case "$var" in
    DOEY_MANAGER_MODEL|DOEY_WORKER_MODEL|DOEY_WATCHDOG_MODEL|DOEY_SESSION_MANAGER_MODEL)
      printf '(opus/sonnet/haiku)' ;;
    DOEY_INITIAL_WORKER_COLS) printf '(1-6)' ;;
    DOEY_INITIAL_TEAMS) printf '(1-10)' ;;
    DOEY_INITIAL_WORKTREE_TEAMS|DOEY_INITIAL_FREELANCER_TEAMS) printf '(0-10)' ;;
    DOEY_MAX_WORKERS) printf '(1-50)' ;;
    DOEY_MAX_WATCHDOG_SLOTS) printf '(1-6)' ;;
    *) printf '(number >= 1)' ;;
  esac
}

# ── Config Writing ───────────────────────────────────────────────────────────

# Write a setting to the project config file. Atomic write via tmp+mv.
_write_config_setting() {
  local var="$1" val="$2"
  local proj_dir config_file
  proj_dir=$(_get_proj_dir)
  config_file="${proj_dir}/.doey/config.sh"

  if [ ! -f "$config_file" ]; then
    mkdir -p "$(dirname "$config_file")"
    cp "${proj_dir}/shell/doey-config-default.sh" "$config_file" 2>/dev/null || {
      # Minimal config if default not found
      printf '#!/usr/bin/env bash\n# Doey project config\n' > "$config_file"
    }
  fi

  local tmp_file="${config_file}.tmp"
  # Check if var already exists (commented or uncommented)
  if grep -q "^${var}=" "$config_file" 2>/dev/null; then
    # Update existing uncommented line
    sed "s|^${var}=.*|${var}=${val}|" "$config_file" > "$tmp_file"
    mv "$tmp_file" "$config_file"
  elif grep -q "^# *${var}=" "$config_file" 2>/dev/null; then
    # Uncomment and set value
    sed "s|^# *${var}=.*|${var}=${val}|" "$config_file" > "$tmp_file"
    mv "$tmp_file" "$config_file"
  else
    # Append
    printf '%s=%s\n' "$var" "$val" >> "$config_file"
  fi

  # Touch refresh trigger
  local trigger="${RUNTIME_DIR}/status/settings_refresh_trigger"
  mkdir -p "$(dirname "$trigger")" 2>/dev/null || true
  touch "$trigger"
}

# ── Agent Frontmatter Writing ────────────────────────────────────────────────

_write_agent_frontmatter() {
  local agent_file="$1" field="$2" new_val="$3"
  [ -f "$agent_file" ] || return 1

  local tmp_file="${agent_file}.tmp"
  local in_front=false replaced=false
  while IFS= read -r line; do
    case "$line" in
      ---)
        if [ "$in_front" = false ]; then
          in_front=true
          printf '%s\n' "$line"
          continue
        else
          # End of frontmatter — if field wasn't found, insert before closing ---
          if [ "$replaced" = false ]; then
            printf '%s: %s\n' "$field" "$new_val"
          fi
          in_front=false
          printf '%s\n' "$line"
          continue
        fi
        ;;
    esac
    if [ "$in_front" = true ]; then
      case "$line" in
        "${field}:"*)
          printf '%s: %s\n' "$field" "$new_val"
          replaced=true
          continue
          ;;
      esac
    fi
    printf '%s\n' "$line"
  done < "$agent_file" > "$tmp_file"
  mv "$tmp_file" "$agent_file"

  # Copy to ~/.claude/agents/ if it exists
  local agents_dest="${HOME}/.claude/agents/$(basename "$agent_file")"
  if [ -d "${HOME}/.claude/agents" ]; then
    cp "$agent_file" "$agents_dest"
  fi
}

# ── Settings Row (cursor-aware) ──────────────────────────────────────────────

# Parallel arrays for settings items (populated during render)
_SETTINGS_VARS=""    # newline-separated var names
_SETTINGS_COUNT=0

_settings_row() {
  local var_name="$1" default_val="$2" current_val="$3"
  local row_idx="$4"  # cursor index for this row
  local config_val indicator label dots_needed name_len val_len
  local is_selected=false

  [ "$row_idx" -eq "$_CURSOR_POS" ] && is_selected=true

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

  if [ "$is_selected" = true ]; then
    printf '  %b▸ %s %s %b%s%b %s%b\n' \
      "${C_REVERSE}" "$indicator" "$var_name" \
      "${C_DIM}" "$(repeat_char '.' "$dots_needed")" "${C_RESET}${C_REVERSE}" \
      "$label" "${C_RESET}"
  else
    printf '    %s %s %b%s%b %s\n' \
      "$indicator" "$var_name" \
      "${C_DIM}" "$(repeat_char '.' "$dots_needed")" "${C_RESET}" \
      "$label"
  fi
}

# ── Render: Settings View ────────────────────────────────────────────────────

# Settings vars list (order matches render, used for cursor→var lookup)
_SETTINGS_VAR_LIST=""

_render_settings_view() {
  local _GLOBAL_CONFIG _PROJECT_CONFIG _PROJ_DIR
  _GLOBAL_CONFIG="${HOME}/.config/doey/config.sh"
  _PROJ_DIR=$(_get_proj_dir)
  _PROJECT_CONFIG=""
  [ -f "${_PROJ_DIR}/.doey/config.sh" ] && _PROJECT_CONFIG="${_PROJ_DIR}/.doey/config.sh"

  if [ -f "$_GLOBAL_CONFIG" ]; then
    printf '  %bConfig (global):%b  %s %b(loaded)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_GLOBAL_CONFIG" "${C_GREEN}" "${C_RESET}"
  else
    printf '  %bConfig (global):%b  %s %b(not found — using defaults)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_GLOBAL_CONFIG" "${C_DIM}" "${C_RESET}"
  fi
  if [ -n "$_PROJECT_CONFIG" ]; then
    printf '  %bConfig (project):%b %s %b(loaded — overrides global)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_PROJECT_CONFIG" "${C_GREEN}" "${C_RESET}"
  fi
  printf '\n'

  local _ri=0
  _SETTINGS_VAR_LIST=""

  printf '  %b Grid & Teams%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_INITIAL_WORKER_COLS"    "2"   "$DOEY_INITIAL_WORKER_COLS"    "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_INITIAL_WORKER_COLS "; _ri=$((_ri+1))
  _settings_row "DOEY_INITIAL_TEAMS"          "2"   "$DOEY_INITIAL_TEAMS"          "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_INITIAL_TEAMS "; _ri=$((_ri+1))
  _settings_row "DOEY_INITIAL_WORKTREE_TEAMS" "0"   "$DOEY_INITIAL_WORKTREE_TEAMS" "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_INITIAL_WORKTREE_TEAMS "; _ri=$((_ri+1))
  _settings_row "DOEY_MAX_WORKERS"            "20"  "$DOEY_MAX_WORKERS"            "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_MAX_WORKERS "; _ri=$((_ri+1))
  _settings_row "DOEY_MAX_WATCHDOG_SLOTS"     "6"   "$DOEY_MAX_WATCHDOG_SLOTS"     "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_MAX_WATCHDOG_SLOTS "; _ri=$((_ri+1))
  printf '\n'

  printf '  %b Models%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_MANAGER_MODEL"          "opus"    "$DOEY_MANAGER_MODEL"          "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_MANAGER_MODEL "; _ri=$((_ri+1))
  _settings_row "DOEY_WORKER_MODEL"           "opus"    "$DOEY_WORKER_MODEL"           "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_WORKER_MODEL "; _ri=$((_ri+1))
  _settings_row "DOEY_WATCHDOG_MODEL"         "sonnet"  "$DOEY_WATCHDOG_MODEL"         "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_WATCHDOG_MODEL "; _ri=$((_ri+1))
  _settings_row "DOEY_SESSION_MANAGER_MODEL"  "opus"    "$DOEY_SESSION_MANAGER_MODEL"  "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_SESSION_MANAGER_MODEL "; _ri=$((_ri+1))
  printf '\n'

  printf '  %b Auth & Launch Timing%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_WORKER_LAUNCH_DELAY"    "3"   "$DOEY_WORKER_LAUNCH_DELAY"    "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_WORKER_LAUNCH_DELAY "; _ri=$((_ri+1))
  _settings_row "DOEY_TEAM_LAUNCH_DELAY"      "15"  "$DOEY_TEAM_LAUNCH_DELAY"      "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_TEAM_LAUNCH_DELAY "; _ri=$((_ri+1))
  _settings_row "DOEY_MANAGER_LAUNCH_DELAY"   "3"   "$DOEY_MANAGER_LAUNCH_DELAY"   "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_MANAGER_LAUNCH_DELAY "; _ri=$((_ri+1))
  _settings_row "DOEY_WATCHDOG_LAUNCH_DELAY"  "3"   "$DOEY_WATCHDOG_LAUNCH_DELAY"  "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_WATCHDOG_LAUNCH_DELAY "; _ri=$((_ri+1))
  _settings_row "DOEY_MANAGER_BRIEF_DELAY"    "15"  "$DOEY_MANAGER_BRIEF_DELAY"    "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_MANAGER_BRIEF_DELAY "; _ri=$((_ri+1))
  _settings_row "DOEY_WATCHDOG_BRIEF_DELAY"   "20"  "$DOEY_WATCHDOG_BRIEF_DELAY"   "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_WATCHDOG_BRIEF_DELAY "; _ri=$((_ri+1))
  _settings_row "DOEY_WATCHDOG_LOOP_DELAY"    "25"  "$DOEY_WATCHDOG_LOOP_DELAY"    "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_WATCHDOG_LOOP_DELAY "; _ri=$((_ri+1))
  printf '\n'

  printf '  %b Dynamic Grid Behavior%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_IDLE_COLLAPSE_AFTER"    "60"  "$DOEY_IDLE_COLLAPSE_AFTER"    "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_IDLE_COLLAPSE_AFTER "; _ri=$((_ri+1))
  _settings_row "DOEY_IDLE_REMOVE_AFTER"      "300" "$DOEY_IDLE_REMOVE_AFTER"      "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_IDLE_REMOVE_AFTER "; _ri=$((_ri+1))
  _settings_row "DOEY_PASTE_SETTLE_MS"        "500" "$DOEY_PASTE_SETTLE_MS"        "$_ri"; _SETTINGS_VAR_LIST="${_SETTINGS_VAR_LIST}DOEY_PASTE_SETTLE_MS "; _ri=$((_ri+1))
  printf '\n'

  _CURSOR_MAX=$_ri
}

# Get the Nth var name from _SETTINGS_VAR_LIST (space-separated)
_settings_var_at() {
  local idx="$1" i=0
  for v in $_SETTINGS_VAR_LIST; do
    if [ "$i" -eq "$idx" ]; then
      printf '%s' "$v"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ── Render: Teams View (cursor-aware) ────────────────────────────────────────

# Team items list for cursor reference
_TEAM_ITEMS=""       # "running:W" or "startup:N" space-separated
_TEAM_ITEM_COUNT=0

# Lineup state (indexed variables pattern for bash 3.2)
_LINEUP_COUNT=0

# Derive the effective team lineup from config (explicit or legacy mode).
# Sets _LINEUP_COUNT and _LINEUP_<i>_TYPE, _LINEUP_<i>_DEF, _LINEUP_<i>_WORKERS,
# _LINEUP_<i>_NAME, _LINEUP_<i>_LABEL as indexed variables.
_derive_effective_lineup() {
  local _proj_dir _cfg_team_count=""
  _proj_dir=$(_get_proj_dir)

  # Source config files to get current values
  local _global_cfg="${HOME}/.config/doey/config.sh"
  local _project_cfg="${_proj_dir}/.doey/config.sh"
  # Reset relevant vars before sourcing
  DOEY_TEAM_COUNT=""
  [ -f "$_global_cfg" ] && source "$_global_cfg" 2>/dev/null
  [ -f "$_project_cfg" ] && source "$_project_cfg" 2>/dev/null

  _cfg_team_count="${DOEY_TEAM_COUNT:-}"
  local _default_workers=$(( ${DOEY_INITIAL_WORKER_COLS:-2} * ${DOEY_ROWS:-2} ))

  if [ -n "$_cfg_team_count" ] && [ "$_cfg_team_count" -gt 0 ] 2>/dev/null; then
    # Explicit mode: read DOEY_TEAM_<N>_* vars
    _LINEUP_COUNT="$_cfg_team_count"
    local _li=1
    while [ "$_li" -le "$_LINEUP_COUNT" ]; do
      eval "local _t=\${DOEY_TEAM_${_li}_TYPE:-local}"
      eval "local _d=\${DOEY_TEAM_${_li}_DEF:-}"
      eval "local _w=\${DOEY_TEAM_${_li}_WORKERS:-}"
      eval "local _n=\${DOEY_TEAM_${_li}_NAME:-}"
      [ -z "$_w" ] && _w="$_default_workers"
      local _lbl=""
      case "$_t" in
        premade)    _lbl="premade: ${_d:-?}" ;;
        freelancer) _lbl="${_w} workers (pool)" ;;
        worktree)   _lbl="${_w} workers (worktree)" ;;
        *)          _lbl="${_w} workers (default)" ;;
      esac
      eval "_LINEUP_${_li}_TYPE=\$_t"
      eval "_LINEUP_${_li}_DEF=\$_d"
      eval "_LINEUP_${_li}_WORKERS=\$_w"
      eval "_LINEUP_${_li}_NAME=\$_n"
      eval "_LINEUP_${_li}_LABEL=\$_lbl"
      _li=$((_li + 1))
    done
  else
    # Legacy mode: derive from DOEY_INITIAL_TEAMS, etc.
    local _lt="${DOEY_INITIAL_TEAMS:-2}"
    local _wt="${DOEY_INITIAL_WORKTREE_TEAMS:-0}"
    local _ft="${DOEY_INITIAL_FREELANCER_TEAMS:-1}"
    _LINEUP_COUNT=0
    local _li=1

    # Local teams
    local _c=0
    while [ "$_c" -lt "$_lt" ]; do
      eval "_LINEUP_${_li}_TYPE=local"
      eval "_LINEUP_${_li}_DEF="
      eval "_LINEUP_${_li}_WORKERS=$_default_workers"
      eval "_LINEUP_${_li}_NAME="
      eval "_LINEUP_${_li}_LABEL='$_default_workers workers (default)'"
      _li=$((_li + 1))
      _c=$((_c + 1))
    done

    # Worktree teams
    _c=0
    while [ "$_c" -lt "$_wt" ]; do
      eval "_LINEUP_${_li}_TYPE=worktree"
      eval "_LINEUP_${_li}_DEF="
      eval "_LINEUP_${_li}_WORKERS=$_default_workers"
      eval "_LINEUP_${_li}_NAME="
      eval "_LINEUP_${_li}_LABEL='$_default_workers workers (worktree)'"
      _li=$((_li + 1))
      _c=$((_c + 1))
    done

    # Freelancer teams
    _c=0
    while [ "$_c" -lt "$_ft" ]; do
      local _fw=$(( _default_workers + 2 ))
      eval "_LINEUP_${_li}_TYPE=freelancer"
      eval "_LINEUP_${_li}_DEF="
      eval "_LINEUP_${_li}_WORKERS=$_fw"
      eval "_LINEUP_${_li}_NAME="
      eval "_LINEUP_${_li}_LABEL='$_fw workers (pool)'"
      _li=$((_li + 1))
      _c=$((_c + 1))
    done

    _LINEUP_COUNT=$((_li - 1))
  fi
}

_render_team_blueprint() {
  local _proj_dir _i _type _workers _def _name
  local _cw
  _proj_dir=$(_get_proj_dir)

  _cw=$(( TERM_W - 6 ))
  [ "$_cw" -lt 40 ] && _cw=40

  _TEAM_ITEMS=""
  _TEAM_ITEM_COUNT=0
  local _ri=0

  # --- Section 0: Running Teams (live) ---
  printf '\n  %b─── Running Teams %b%s%b\n' \
    "${C_BOLD_WHITE}" "${C_DIM}" "$(repeat_char '─' $(( _cw - 19 )))" "${C_RESET}"

  local _rt_session _rt_runtime _rt_windows
  _rt_session=$(tmux show-environment -t "${SESSION_NAME:-}" DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)
  if [ -n "$_rt_session" ] && [ -n "${SESSION_NAME:-}" ]; then
    _rt_windows=$(grep '^TEAM_WINDOWS=' "${_rt_session}/session.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -n "$_rt_windows" ]; then
      local _rt_w _rt_tname _rt_ttype _rt_wcount _rt_tdef
      for _rt_w in $(echo "$_rt_windows" | tr ',' ' ' | sort -u -n); do
        local _rt_env="${_rt_session}/team_${_rt_w}.env"
        [ -f "$_rt_env" ] || continue
        _rt_tname=$(grep '^TEAM_NAME=' "$_rt_env" 2>/dev/null | cut -d= -f2 | tr -d '"')
        _rt_ttype=$(grep '^TEAM_TYPE=' "$_rt_env" 2>/dev/null | cut -d= -f2 | tr -d '"')
        _rt_wcount=$(grep '^WORKER_COUNT=' "$_rt_env" 2>/dev/null | cut -d= -f2 | tr -d '"')
        _rt_tdef=$(grep '^TEAM_DEF=' "$_rt_env" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -z "$_rt_tname" ] && _rt_tname="${_rt_tdef:-team}"
        [ -z "$_rt_ttype" ] && _rt_ttype="managed"
        [ -z "$_rt_wcount" ] && _rt_wcount="?"

        local _rt_label _rt_color
        if [ "$_rt_ttype" = "freelancer" ]; then
          _rt_label="freelancer"
          _rt_color="${C_GREEN}"
        else
          _rt_label="${_rt_ttype:-managed}"
          _rt_color="${C_CYAN}"
        fi

        local _is_sel=false
        [ "$_ri" -eq "$_CURSOR_POS" ] && _is_sel=true
        if [ "$_is_sel" = true ]; then
          printf '  %b▸ W%-2s %-12s %-12s %s workers%b\n' \
            "${C_REVERSE}" "$_rt_w" "$_rt_tname" "$_rt_label" "$_rt_wcount" "${C_RESET}"
        else
          printf '  %b W%-2s%b %b%-12s%b %b%-12s%b %b%s workers%b\n' \
            "${C_BOLD_WHITE}" "$_rt_w" "${C_RESET}" \
            "${C_BOLD_WHITE}" "$_rt_tname" "${C_RESET}" \
            "$_rt_color" "$_rt_label" "${C_RESET}" \
            "${C_DIM}" "$_rt_wcount" "${C_RESET}"
        fi
        _TEAM_ITEMS="${_TEAM_ITEMS}running:${_rt_w} "
        _ri=$((_ri + 1))
      done
    else
      printf '  %b(no teams running)%b\n' "${C_DIM}" "${C_RESET}"
    fi
  else
    printf '  %b(no active session)%b\n' "${C_DIM}" "${C_RESET}"
  fi

  # Derive lineup
  _derive_effective_lineup

  # --- Section 1: Startup Lineup ---
  printf '\n  %b─── Startup Lineup %b%s%b\n' \
    "${C_BOLD_WHITE}" "${C_DIM}" "$(repeat_char '─' $(( _cw - 20 )))" "${C_RESET}"

  if [ "$_LINEUP_COUNT" -gt 0 ]; then
    local _total_workers=0
    _i=1
    while [ "$_i" -le "$_LINEUP_COUNT" ]; do
      eval "_type=\${_LINEUP_${_i}_TYPE:-local}"
      eval "_workers=\${_LINEUP_${_i}_WORKERS:-4}"
      eval "_def=\${_LINEUP_${_i}_DEF:-}"
      eval "_name=\${_LINEUP_${_i}_NAME:-}"
      _total_workers=$(( _total_workers + _workers ))

      local _line_detail="" _is_sel=false
      [ "$_ri" -eq "$_CURSOR_POS" ] && _is_sel=true

      case "$_type" in
        premade)
          local _def_desc="" _def_file=""
          for _dd in "${HOME}/.local/share/doey/teams/${_def}.team.md" \
                     "${_proj_dir}/teams/${_def}.team.md" \
                     "${_proj_dir}/.doey/teams/${_def}.team.md"; do
            if [ -f "$_dd" ]; then _def_file="$_dd"; break; fi
          done
          if [ -n "$_def_file" ]; then
            _def_desc=$(grep '^description:' "$_def_file" | head -1 | sed 's/description:[[:space:]]*"//;s/"$//')
          fi
          [ -z "$_def_desc" ] && _def_desc="(no description)"
          _line_detail=$(printf '%b%-10s%b %b%-12s%b %b%s%b' \
            "${C_CYAN}" "premade" "${C_RESET}" \
            "${C_BOLD_CYAN}" "${_def:-?}" "${C_RESET}" \
            "${C_DIM}" "$(_truncate "$_def_desc" $(( _cw - 34 )))" "${C_RESET}")
          ;;
        freelancer)
          _line_detail=$(printf '%b%-10s%b %b%s workers%b  %b(pool)%b' \
            "${C_GREEN}" "freelancer" "${C_RESET}" \
            "${C_BOLD_GREEN}" "$_workers" "${C_RESET}" \
            "${C_DIM}" "${C_RESET}")
          ;;
        worktree)
          _line_detail=$(printf '%b%-10s%b %b%s workers%b  %b(worktree)%b' \
            "${C_CYAN}" "worktree" "${C_RESET}" \
            "${C_BOLD_GREEN}" "$_workers" "${C_RESET}" \
            "${C_DIM}" "${C_RESET}")
          ;;
        *)
          _line_detail=$(printf '%b%-10s%b %b%s workers%b  %b(default)%b' \
            "${C_CYAN}" "$_type" "${C_RESET}" \
            "${C_BOLD_GREEN}" "$_workers" "${C_RESET}" \
            "${C_DIM}" "${C_RESET}")
          ;;
      esac

      if [ "$_is_sel" = true ]; then
        printf '  %b▸%2d. %b%b\n' "${C_REVERSE}" "$_i" "$_line_detail" "${C_RESET}"
      else
        printf '  %b%2d.%b %b\n' "${C_BOLD_WHITE}" "$_i" "${C_RESET}" "$_line_detail"
      fi
      _TEAM_ITEMS="${_TEAM_ITEMS}startup:${_i} "
      _ri=$((_ri + 1))
      _i=$(( _i + 1 ))
    done

    printf '\n  %b%s teams · %s workers%b\n' \
      "${C_DIM}" "$_LINEUP_COUNT" "$_total_workers" "${C_RESET}"
  else
    printf '  %b(no teams configured)%b\n' "${C_DIM}" "${C_RESET}"
  fi

  _CURSOR_MAX=$_ri
  _TEAM_ITEM_COUNT=$_ri
}

# Get the Nth team item
_team_item_at() {
  local idx="$1" i=0
  for v in $_TEAM_ITEMS; do
    if [ "$i" -eq "$idx" ]; then
      printf '%s' "$v"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Add a team to config (with automatic migration from legacy to explicit)
# Usage: _add_team <type> [def_name]
#   type: local, freelancer, worktree, premade
#   def_name: only for premade type
_add_team() {
  local team_type="$1"
  local def_name="${2:-}"
  local proj_dir config_file
  proj_dir=$(_get_proj_dir)
  config_file="${proj_dir}/.doey/config.sh"

  if [ ! -f "$config_file" ]; then
    mkdir -p "$(dirname "$config_file")"
    cp "${proj_dir}/shell/doey-config-default.sh" "$config_file" 2>/dev/null || {
      printf '#!/usr/bin/env bash\n# Doey project config\n' > "$config_file"
    }
  fi

  # Derive current lineup (handles both explicit and legacy)
  _derive_effective_lineup

  local old_count="$_LINEUP_COUNT"
  local new_count=$(( old_count + 1 ))

  # Remove legacy vars from config
  local tmp_file="${config_file}.tmp"
  sed '/^DOEY_INITIAL_TEAMS=/d;/^DOEY_INITIAL_WORKTREE_TEAMS=/d;/^DOEY_INITIAL_FREELANCER_TEAMS=/d' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"
  sed '/^#.*DOEY_INITIAL_TEAMS=/d;/^#.*DOEY_INITIAL_WORKTREE_TEAMS=/d;/^#.*DOEY_INITIAL_FREELANCER_TEAMS=/d' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"

  # Remove all existing DOEY_TEAM_* lines to rewrite cleanly
  sed '/^DOEY_TEAM_[0-9]/d;/^DOEY_TEAM_COUNT=/d' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"

  # Write full explicit config
  printf '\nDOEY_TEAM_COUNT=%s\n' "$new_count" >> "$config_file"

  # Write existing teams
  local _wi=1
  while [ "$_wi" -le "$old_count" ]; do
    eval "local _et=\${_LINEUP_${_wi}_TYPE:-local}"
    eval "local _ed=\${_LINEUP_${_wi}_DEF:-}"
    eval "local _ew=\${_LINEUP_${_wi}_WORKERS:-}"
    printf 'DOEY_TEAM_%s_TYPE=%s\n' "$_wi" "$_et" >> "$config_file"
    [ -n "$_ed" ] && printf 'DOEY_TEAM_%s_DEF=%s\n' "$_wi" "$_ed" >> "$config_file"
    [ -n "$_ew" ] && printf 'DOEY_TEAM_%s_WORKERS=%s\n' "$_wi" "$_ew" >> "$config_file"
    _wi=$((_wi + 1))
  done

  # Write the new team
  printf 'DOEY_TEAM_%s_TYPE=%s\n' "$new_count" "$team_type" >> "$config_file"
  [ "$team_type" = "premade" ] && [ -n "$def_name" ] && \
    printf 'DOEY_TEAM_%s_DEF=%s\n' "$new_count" "$def_name" >> "$config_file"

  local trigger="${RUNTIME_DIR}/status/settings_refresh_trigger"
  mkdir -p "$(dirname "$trigger")" 2>/dev/null || true
  touch "$trigger"
}

# Remove a startup team by index (1-based), rewrite as explicit config
_remove_startup_team() {
  local remove_idx="$1"
  local proj_dir config_file
  proj_dir=$(_get_proj_dir)
  config_file="${proj_dir}/.doey/config.sh"
  [ -f "$config_file" ] || return 1

  # Derive current lineup (handles both explicit and legacy)
  _derive_effective_lineup
  [ "$_LINEUP_COUNT" -le 0 ] && return 1
  [ "$remove_idx" -gt "$_LINEUP_COUNT" ] && return 1

  local new_count=$(( _LINEUP_COUNT - 1 ))
  local tmp_file="${config_file}.tmp"

  # Remove legacy vars
  sed '/^DOEY_INITIAL_TEAMS=/d;/^DOEY_INITIAL_WORKTREE_TEAMS=/d;/^DOEY_INITIAL_FREELANCER_TEAMS=/d' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"
  sed '/^#.*DOEY_INITIAL_TEAMS=/d;/^#.*DOEY_INITIAL_WORKTREE_TEAMS=/d;/^#.*DOEY_INITIAL_FREELANCER_TEAMS=/d' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"

  # Remove all existing DOEY_TEAM_* lines
  sed '/^DOEY_TEAM_[0-9]/d;/^DOEY_TEAM_COUNT=/d' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"

  if [ "$new_count" -le 0 ]; then
    # No teams left — don't write DOEY_TEAM_COUNT
    :
  else
    printf '\nDOEY_TEAM_COUNT=%s\n' "$new_count" >> "$config_file"

    # Rewrite all teams except the removed one
    local _wi=1 _di=1
    while [ "$_wi" -le "$_LINEUP_COUNT" ]; do
      if [ "$_wi" -eq "$remove_idx" ]; then
        _wi=$((_wi + 1))
        continue
      fi
      eval "local _et=\${_LINEUP_${_wi}_TYPE:-local}"
      eval "local _ed=\${_LINEUP_${_wi}_DEF:-}"
      eval "local _ew=\${_LINEUP_${_wi}_WORKERS:-}"
      printf 'DOEY_TEAM_%s_TYPE=%s\n' "$_di" "$_et" >> "$config_file"
      [ -n "$_ed" ] && printf 'DOEY_TEAM_%s_DEF=%s\n' "$_di" "$_ed" >> "$config_file"
      [ -n "$_ew" ] && printf 'DOEY_TEAM_%s_WORKERS=%s\n' "$_di" "$_ew" >> "$config_file"
      _wi=$((_wi + 1))
      _di=$((_di + 1))
    done
  fi

  # Clamp cursor
  if [ "$_CURSOR_POS" -ge "$new_count" ] && [ "$_CURSOR_POS" -gt 0 ]; then
    _CURSOR_POS=$((_CURSOR_POS - 1))
    _write_cursor "teams" "$_CURSOR_POS"
  fi

  local trigger="${RUNTIME_DIR}/status/settings_refresh_trigger"
  mkdir -p "$(dirname "$trigger")" 2>/dev/null || true
  touch "$trigger"
}

# ── Render: Agents View (cursor-aware) ───────────────────────────────────────

_AGENT_FILES=""      # space-separated agent file paths
_AGENT_NAMES=""      # space-separated agent names
_AGENT_COUNT=0

_render_available_agents() {
  local _proj_dir _agents_dir _f _name _model _desc _color _memory _idx
  _proj_dir=$(_get_proj_dir)
  _agents_dir="${_proj_dir}/agents"

  printf '\n  %bAvailable Agents%b  %b(↑↓/jk to navigate, Enter to inspect)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  printf '  %b────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"

  if [ ! -d "$_agents_dir" ]; then
    printf '    %b(no agents directory)%b\n' "${C_DIM}" "${C_RESET}"
    _CURSOR_MAX=0
    return
  fi

  _idx=0
  _AGENT_FILES=""
  _AGENT_NAMES=""
  for _f in "$_agents_dir"/*.md; do
    [ -f "$_f" ] || continue
    _name=$(_parse_agent_frontmatter "$_f" "name")
    _model=$(_parse_agent_frontmatter "$_f" "model")
    _desc=$(_parse_agent_frontmatter "$_f" "description")
    _color=$(_parse_agent_frontmatter "$_f" "color")
    _memory=$(_parse_agent_frontmatter "$_f" "memory")
    [ -z "$_name" ] && _name=$(basename "$_f" .md)
    [ -z "$_model" ] && _model="?"
    [ -z "$_desc" ] && _desc="(no description)"

    _AGENT_FILES="${_AGENT_FILES}${_f} "
    _AGENT_NAMES="${_AGENT_NAMES}${_name} "

    local _is_sel=false
    [ "$_idx" -eq "$_CURSOR_POS" ] && _is_sel=true

    if [ "$_is_sel" = true ]; then
      printf '  %b▸ %-20s  %-8s  %s%b\n' \
        "${C_REVERSE}" "$_name" "$_model" \
        "$(_truncate "$_desc" $((TERM_W - 40)))" "${C_RESET}"
    else
      printf '    %b%-20s%b %b%-8s%b %b%s%b\n' \
        "${C_CYAN}" "$_name" "${C_RESET}" \
        "${C_GREEN}" "$_model" "${C_RESET}" \
        "${C_DIM}" "$(_truncate "$_desc" $((TERM_W - 40)))" "${C_RESET}"
    fi
    if [ "$_is_sel" = false ]; then
      [ -n "$_color" ] && printf '      %bcolor: %s%b' "${C_DIM}" "$_color" "${C_RESET}"
      [ -n "$_memory" ] && printf '  %bmemory: %s%b' "${C_DIM}" "$_memory" "${C_RESET}"
      if [ -n "$_color" ] || [ -n "$_memory" ]; then printf '\n'; fi
    fi
    _idx=$((_idx + 1))
  done
  [ "$_idx" -eq 0 ] && printf '    %b(no agent files found)%b\n' "${C_DIM}" "${C_RESET}"
  _CURSOR_MAX=$_idx
  _AGENT_COUNT=$_idx
}

# Get the Nth agent name/file
_agent_name_at() {
  local idx="$1" i=0
  for v in $_AGENT_NAMES; do
    if [ "$i" -eq "$idx" ]; then printf '%s' "$v"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

_agent_file_at() {
  local idx="$1" i=0
  for v in $_AGENT_FILES; do
    if [ "$i" -eq "$idx" ]; then printf '%s' "$v"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# ── Render: Agent Detail (cursor-aware) ──────────────────────────────────────

# Editable properties for agent detail cursor
_AGENT_DETAIL_PROPS=""   # space-separated: model color memory description
_AGENT_DETAIL_FILE=""

_render_agent_detail() {
  local _agent_name="$1"
  local _proj_dir _agents_dir _f="" _found=""
  _proj_dir=$(_get_proj_dir)
  _agents_dir="${_proj_dir}/agents"

  for _f in "$_agents_dir"/*.md; do
    [ -f "$_f" ] || continue
    local _n
    _n=$(_parse_agent_frontmatter "$_f" "name")
    [ -z "$_n" ] && _n=$(basename "$_f" .md)
    if [ "$_n" = "$_agent_name" ] || [ "$(basename "$_f" .md)" = "$_agent_name" ]; then
      _found="$_f"
      break
    fi
  done

  if [ -z "$_found" ]; then
    printf '\n  %bAgent not found: %s%b\n' "${C_RED}" "$_agent_name" "${C_RESET}"
    printf '  %bPress b to return to agent list%b\n' "${C_DIM}" "${C_RESET}"
    _CURSOR_MAX=0
    return
  fi

  _AGENT_DETAIL_FILE="$_found"
  _AGENT_DETAIL_PROPS="model color memory description"

  local _name _model _desc _color _memory
  _name=$(_parse_agent_frontmatter "$_found" "name")
  _model=$(_parse_agent_frontmatter "$_found" "model")
  _desc=$(_parse_agent_frontmatter "$_found" "description")
  _color=$(_parse_agent_frontmatter "$_found" "color")
  _memory=$(_parse_agent_frontmatter "$_found" "memory")
  [ -z "$_name" ] && _name=$(basename "$_found" .md)

  printf '\n  %b● %s%b\n' "${C_BOLD_CYAN}" "$_name" "${C_RESET}"
  printf '  %b──────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"

  # Editable properties with cursor (use indexed approach to avoid word-split issues)
  local _ri=0

  # Render each property row individually
  local _prop_names="model color memory description"
  local _prop_label _prop_val
  for _prop in $_prop_names; do
    case "$_prop" in
      model) _prop_label="Model"; _prop_val="${_model:-?}" ;;
      color) _prop_label="Color"; _prop_val="${_color:---}" ;;
      memory) _prop_label="Memory"; _prop_val="${_memory:---}" ;;
      description) _prop_label="Description"; _prop_val="${_desc:-(no description)}" ;;
    esac

    if [ "$_ri" -eq "$_CURSOR_POS" ]; then
      printf '  %b▸ %-12s %s%b\n' "${C_REVERSE}" "${_prop_label}:" "$_prop_val" "${C_RESET}"
    else
      printf '  %b%-12s%b %s\n' "${C_BOLD_WHITE}" "${_prop_label}:" "${C_RESET}" "$_prop_val"
    fi
    _ri=$((_ri + 1))
  done

  printf '  %bFile:%b       %s\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_found"
  printf '\n'

  # Read full body (everything after second ---)
  printf '  %bAgent Instructions%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  printf '  %b──────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"

  local _in_front=false _past_front=false _line_count=0
  local _max_lines=$(($(tput lines 2>/dev/null || echo 40) - 20))
  [ "$_max_lines" -lt 10 ] && _max_lines=30
  while IFS= read -r _line; do
    case "$_line" in
      ---)
        if [ "$_in_front" = false ]; then
          _in_front=true; continue
        else
          _past_front=true; continue
        fi
        ;;
    esac
    if [ "$_past_front" = true ]; then
      case "$_line" in
        "## "*)  printf '  %b%s%b\n' "${C_BOLD_WHITE}" "$_line" "${C_RESET}" ;;
        "### "*) printf '  %b%s%b\n' "${C_BOLD_WHITE}" "$_line" "${C_RESET}" ;;
        "| "*)   printf '  %b%s%b\n' "${C_DIM}" "$_line" "${C_RESET}" ;;
        "- "*)   printf '  %b%s%b\n' "${C_RESET}" "$_line" "${C_RESET}" ;;
        "")      printf '\n' ;;
        *)       printf '  %s\n' "$_line" ;;
      esac
      _line_count=$((_line_count + 1))
      if [ "$_line_count" -ge "$_max_lines" ]; then
        printf '\n  %b... (truncated — %d lines shown, use Read tool for full file)%b\n' "${C_DIM}" "$_line_count" "${C_RESET}"
        break
      fi
    fi
  done < "$_found"

  _CURSOR_MAX=$_ri
}

# Get the Nth agent detail property name
_agent_detail_prop_at() {
  local idx="$1" i=0
  for v in $_AGENT_DETAIL_PROPS; do
    if [ "$i" -eq "$idx" ]; then printf '%s' "$v"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# ── Render: Nav Bar ──────────────────────────────────────────────────────────

_render_nav_bar() {
  local _active="${1:-settings}"
  local _views="settings teams agents"
  local _v _label _i
  _i=1
  printf '  '
  for _v in $_views; do
    case "$_i" in
      1) _label="1:Settings" ;;
      2) _label="2:Teams" ;;
      3) _label="3:Agents" ;;
    esac
    if [ "$_v" = "$_active" ]; then
      printf '%b[%s]%b  ' "${C_BOLD_CYAN}" "$_label" "${C_RESET}"
    else
      printf '%b[%s]%b  ' "${C_DIM}" "$_label" "${C_RESET}"
    fi
    _i=$((_i + 1))
  done
  printf '\n'
}

# ── Context-Sensitive Footer ─────────────────────────────────────────────────

_render_footer() {
  local view="$1"
  printf '  %b%s%b\n' "${C_DIM}" "$HR" "${C_RESET}"

  # Status message (temporary feedback like "Reloading..." or "✓ Applied")
  if [ -n "${_STATUS_MSG:-}" ]; then
    local _now
    _now=$(date +%s)
    if [ "$_now" -lt "$_STATUS_EXPIRE" ]; then
      printf '  %b%s%b\n' "${C_GREEN}" "$_STATUS_MSG" "${C_RESET}"
    else
      _STATUS_MSG=""
    fi
  fi

  case "$view" in
    settings)
      printf '  %b[↑↓/jk]%b navigate  %b[Enter]%b edit  %b[r]%b reload  %b[1-3]%b views\n' \
        "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}" \
        "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}"
      ;;
    teams)
      # Context-sensitive footer based on cursor position
      local _foot_item=""
      _foot_item=$(_team_item_at "$_CURSOR_POS" 2>/dev/null) || true
      case "$_foot_item" in
        startup:*)
          printf '  %b[↑↓/jk]%b navigate  %b[d]%b remove  %b[r]%b reload  %b[1-3]%b views\n' \
            "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}" \
            "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}"
          ;;
        running:*)
          printf '  %b[↑↓/jk]%b navigate  %b[r]%b reload  %b[1-3]%b views\n' \
            "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}" \
            "${C_BOLD_CYAN}" "${C_RESET}"
          ;;
        *)
          printf '  %b[↑↓/jk]%b navigate  %b[r]%b reload  %b[1-3]%b views\n' \
            "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}" \
            "${C_BOLD_CYAN}" "${C_RESET}"
          ;;
      esac
      ;;
    agents)
      printf '  %b[↑↓/jk]%b navigate  %b[Enter]%b inspect  %b[1-3]%b views\n' \
        "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}" \
        "${C_BOLD_CYAN}" "${C_RESET}"
      ;;
    agent_detail)
      printf '  %b[↑↓/jk]%b navigate  %b[Enter]%b edit  %b[b]%b back  %b[1-3]%b views\n' \
        "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}" \
        "${C_BOLD_CYAN}" "${C_RESET}" "${C_BOLD_CYAN}" "${C_RESET}"
      ;;
  esac
}

# ── Edit Prompt ──────────────────────────────────────────────────────────────

# Show an input prompt at the bottom of the screen, read user input.
# Returns the new value via stdout, or empty string if cancelled.
_edit_prompt() {
  local prompt_label="$1" hint="${2:-}"
  local input=""

  # Move to bottom, show prompt
  printf '\n  %b%s%b %s ' "${C_BOLD_CYAN}" "$prompt_label" "${C_RESET}" "$hint"

  # Read full line (not single char)
  read -r input 2>/dev/null || true
  printf '%s' "$input"
}

# ── Key Reading (arrow key aware, bash 3.2 compatible) ───────────────────────

_read_key() {
  local _key="" _rest=""
  # read -s -n 1: returns empty string for Enter key, sets exit code >0 on timeout
  if ! read -s -n 1 -t 1 _key 2>/dev/null; then
    # Timeout — no key pressed
    printf ''
    return
  fi
  # Enter key produces empty string
  if [ -z "$_key" ]; then
    printf 'ENTER'
    return
  fi
  # Backspace (0x7f or 0x08)
  if [ "$_key" = $'\177' ] || [ "$_key" = $'\010' ]; then
    printf 'BACKSPACE'
    return
  fi
  # Check for escape sequence (arrow keys)
  if [ "$_key" = $'\033' ]; then
    read -s -n 2 -t 1 _rest 2>/dev/null || true
    case "$_rest" in
      '[A') printf 'UP'; return ;;
      '[B') printf 'DOWN'; return ;;
      '[C') printf 'RIGHT'; return ;;
      '[D') printf 'LEFT'; return ;;
      *)    printf 'ESC'; return ;;
    esac
  fi
  printf '%s' "$_key"
}

# ── Main Handle Key ─────────────────────────────────────────────────────────

_handle_key() {
  local _key="$1"
  local _view_file="${RUNTIME_DIR}/status/settings_view"

  case "$_key" in
    # View switching
    1) echo "settings" > "$_view_file"; _CURSOR_POS=0; _write_cursor "settings" 0 ;;
    2) echo "teams" > "$_view_file"; _read_cursor "teams" ;;
    3) echo "agents" > "$_view_file"; _read_cursor "agents" ;;

    # Cursor movement
    UP|k)
      _cursor_move "up" "$_CURRENT_VIEW"
      ;;
    DOWN|j)
      _cursor_move "down" "$_CURRENT_VIEW"
      ;;

    # Reload
    r)
      _STATUS_MSG="Reloading..."
      _STATUS_EXPIRE=$(($(date +%s) + 3))
      # Run doey reload in background
      bash -c 'doey reload' >/dev/null 2>&1 &
      sleep 1
      _STATUS_MSG="✓ Applied"
      _STATUS_EXPIRE=$(($(date +%s) + 2))
      ;;

    # Enter — context-dependent action
    ENTER)
      case "$_CURRENT_VIEW" in
        settings)
          local _var
          _var=$(_settings_var_at "$_CURSOR_POS") || return
          local _hint
          _hint=$(_validation_hint "$_var")
          local _new_val
          _new_val=$(_edit_prompt "New value for ${_var}:" "$_hint")
          if [ -n "$_new_val" ]; then
            local _err=""
            if _err=$(_validate_setting "$_var" "$_new_val"); then
              _write_config_setting "$_var" "$_new_val"
              _STATUS_MSG="✓ Set ${_var}=${_new_val}"
              _STATUS_EXPIRE=$(($(date +%s) + 3))
            else
              _STATUS_MSG="✗ ${_err}"
              _STATUS_EXPIRE=$(($(date +%s) + 3))
            fi
          fi
          ;;
        teams)
          local _item
          _item=$(_team_item_at "$_CURSOR_POS") || return
          case "$_item" in
            startup:*)
              _STATUS_MSG="Use [d] to remove startup teams"
              _STATUS_EXPIRE=$(($(date +%s) + 2))
              ;;
            running:*)
              _STATUS_MSG="Team already running"
              _STATUS_EXPIRE=$(($(date +%s) + 2))
              ;;
          esac
          ;;
        agents)
          local _aname
          _aname=$(_agent_name_at "$_CURSOR_POS") || return
          echo "agents:${_aname}" > "$_view_file"
          _CURSOR_POS=0
          _write_cursor "agent_detail" 0
          ;;
        agent_detail)
          local _prop
          _prop=$(_agent_detail_prop_at "$_CURSOR_POS") || return
          local _hint=""
          case "$_prop" in
            model) _hint="(opus/sonnet/haiku)" ;;
            color) _hint="(e.g. red, green, blue, cyan, yellow)" ;;
            memory) _hint="(e.g. user, project, none)" ;;
            description) _hint="" ;;
          esac
          local _new_val
          _new_val=$(_edit_prompt "New ${_prop}:" "$_hint")
          if [ -n "$_new_val" ]; then
            # Validate model if applicable
            if [ "$_prop" = "model" ]; then
              case "$_new_val" in
                opus|sonnet|haiku) ;;
                *)
                  _STATUS_MSG="✗ Model must be: opus, sonnet, or haiku"
                  _STATUS_EXPIRE=$(($(date +%s) + 3))
                  return
                  ;;
              esac
            fi
            # Wrap description in quotes if it contains spaces
            local _write_val="$_new_val"
            case "$_new_val" in
              *" "*) _write_val="\"${_new_val}\"" ;;
            esac
            _write_agent_frontmatter "$_AGENT_DETAIL_FILE" "$_prop" "$_write_val"
            _STATUS_MSG="✓ Updated ${_prop} → ${_new_val}"
            _STATUS_EXPIRE=$(($(date +%s) + 3))
          fi
          ;;
      esac
      ;;

    # Delete team
    d)
      if [ "$_CURRENT_VIEW" = "teams" ]; then
        local _item
        _item=$(_team_item_at "$_CURSOR_POS") || return
        case "$_item" in
          startup:*)
            local _tidx
            _tidx=$(echo "$_item" | cut -d: -f2)
            _remove_startup_team "$_tidx"
            _STATUS_MSG="✓ Removed team ${_tidx}"
            _STATUS_EXPIRE=$(($(date +%s) + 3))
            ;;
          *)
            _STATUS_MSG="Can only remove startup teams"
            _STATUS_EXPIRE=$(($(date +%s) + 2))
            ;;
        esac
      fi
      ;;

    # Back from agent detail
    b|BACKSPACE)
      if [ "$_CURRENT_VIEW" = "agent_detail" ]; then
        echo "agents" > "$_view_file"
        _read_cursor "agents"
      fi
      ;;
  esac
}

# ── Main Loop ────────────────────────────────────────────────────────────────

while true; do
  _doey_load_config
  DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"

  if [ "${DOEY_SETTINGS_LIVE:-0}" = "1" ]; then
    _refresh_interval=2
  else
    _refresh_interval="$DOEY_INFO_PANEL_REFRESH"
  fi

  DOEY_INITIAL_WORKER_COLS="${DOEY_INITIAL_WORKER_COLS:-2}"
  DOEY_INITIAL_TEAMS="${DOEY_INITIAL_TEAMS:-2}"
  DOEY_INITIAL_WORKTREE_TEAMS="${DOEY_INITIAL_WORKTREE_TEAMS:-0}"
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
  DOEY_WORKER_MODEL="${DOEY_WORKER_MODEL:-opus}"
  DOEY_WATCHDOG_MODEL="${DOEY_WATCHDOG_MODEL:-sonnet}"
  DOEY_SESSION_MANAGER_MODEL="${DOEY_SESSION_MANAGER_MODEL:-opus}"

  _view_file="${RUNTIME_DIR}/status/settings_view"
  _CURRENT_VIEW="settings"
  _AGENT_DETAIL=""
  if [ -f "$_view_file" ]; then
    _CURRENT_VIEW=$(cat "$_view_file" 2>/dev/null)
    case "$_CURRENT_VIEW" in
      agents:*) _AGENT_DETAIL="${_CURRENT_VIEW#agents:}"; _CURRENT_VIEW="agent_detail" ;;
      settings|teams|agents) ;;
      *) _CURRENT_VIEW="settings" ;;
    esac
  fi

  # Restore cursor for current view
  _read_cursor "$_CURRENT_VIEW"

  printf '\033[2J\033[H'

  TERM_W=$(tput cols 2>/dev/null || echo 80)
  HR=$(repeat_char "=" "$TERM_W")

  printf '\n'
  printf '  %b⚙  DOEY SETTINGS%b\n' "${C_BOLD_CYAN}" "${C_RESET}"
  [ "${DOEY_SETTINGS_LIVE:-0}" = "1" ] && printf '  %b⚡ Live refresh (2s)%b\n' "${C_GREEN}" "${C_RESET}"
  printf '  %b%s%b\n\n' "${C_DIM}" "$HR" "${C_RESET}"

  case "$_CURRENT_VIEW" in agent_detail) _render_nav_bar "agents" ;; *) _render_nav_bar "$_CURRENT_VIEW" ;; esac

  case "$_CURRENT_VIEW" in
    teams)        _render_team_blueprint ;;
    agents)       _render_available_agents ;;
    agent_detail) _render_agent_detail "$_AGENT_DETAIL" ;;
    *)            _render_settings_view ;;
  esac
  printf '\n'

  # Clamp cursor to bounds after render (which sets _CURSOR_MAX)
  if [ "$_CURSOR_MAX" -gt 0 ] && [ "$_CURSOR_POS" -ge "$_CURSOR_MAX" ]; then
    _CURSOR_POS=$((_CURSOR_MAX - 1))
    _write_cursor "$_CURRENT_VIEW" "$_CURSOR_POS"
  fi

  _render_footer "$_CURRENT_VIEW"

  # Wait for trigger or keypress (poll with 1s reads up to refresh interval)
  _trigger="${RUNTIME_DIR}/status/settings_refresh_trigger"
  _waited=0
  _max_wait="${_refresh_interval}"
  # Live mode: shorter cycle
  [ "${DOEY_SETTINGS_LIVE:-0}" = "1" ] && _max_wait=5
  while [ "$_waited" -lt "$_max_wait" ]; do
    if [ -f "$_trigger" ]; then rm -f "$_trigger" 2>/dev/null; break; fi
    _key=$(_read_key)
    if [ -n "$_key" ]; then
      _handle_key "$_key"
      break
    fi
    _waited=$((_waited + 1))
  done
done
