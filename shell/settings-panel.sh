#!/usr/bin/env bash
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
C_RED='\033[31m'
C_RED_DIM='\033[2;31m'
C_CYAN_DIM='\033[2;36m'
C_YELLOW='\033[33m'

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


_render_team_blueprint() {
  local _proj_dir _agents_dir _team_count _i _type _workers _wm _mm _role _name _desc
  local _cw _def
  _proj_dir=$(_get_proj_dir)
  _agents_dir="${_proj_dir}/agents"

  _cw=$(( TERM_W - 6 ))
  [ "$_cw" -lt 40 ] && _cw=40

  _team_count="${DOEY_TEAM_COUNT:-}"

  # --- Section 1: Current Startup Teams ---
  printf '\n  %b─── Current Startup Teams %b%s%b\n' \
    "${C_BOLD_WHITE}" "${C_DIM}" "$(repeat_char '─' $(( _cw - 27 )))" "${C_RESET}"

  if [ -n "$_team_count" ] && [ "$_team_count" -gt 0 ] 2>/dev/null; then
    # Detailed per-team view when DOEY_TEAM_COUNT is set
    local _total_workers=0 _active_defs=""
    _i=1
    while [ "$_i" -le "$_team_count" ]; do
      eval "_type=\${DOEY_TEAM_${_i}_TYPE:-local}"
      eval "_workers=\${DOEY_TEAM_${_i}_WORKERS:-}"
      eval "_def=\${DOEY_TEAM_${_i}_DEF:-}"
      eval "_name=\${DOEY_TEAM_${_i}_NAME:-}"

      [ -z "$_workers" ] && _workers=$(( ${DOEY_INITIAL_WORKER_COLS:-2} * 2 ))
      _total_workers=$(( _total_workers + _workers ))

      local _line_detail=""
      case "$_type" in
        premade)
          # Track active defs for section 2
          [ -n "$_def" ] && _active_defs="${_active_defs} ${_def}"
          # Read description from the .team.md file
          local _def_desc=""
          local _def_file=""
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
        *)
          _line_detail=$(printf '%b%-10s%b %b%s workers%b  %b(default)%b' \
            "${C_CYAN}" "$_type" "${C_RESET}" \
            "${C_BOLD_GREEN}" "$_workers" "${C_RESET}" \
            "${C_DIM}" "${C_RESET}")
          ;;
      esac

      printf '  %b%2d.%b %b\n' "${C_BOLD_WHITE}" "$_i" "${C_RESET}" "$_line_detail"
      _i=$(( _i + 1 ))
    done

    printf '\n  %b%s teams · %s workers%b\n' \
      "${C_DIM}" "$_team_count" "$_total_workers" "${C_RESET}"
  else
    # Fallback: simple count display when DOEY_TEAM_COUNT is not set
    local _active_defs=""
    local _lt="${DOEY_INITIAL_TEAMS:-2}"
    local _wt="${DOEY_INITIAL_WORKTREE_TEAMS:-0}"
    local _wc=$(( ${DOEY_INITIAL_WORKER_COLS:-2} * 2 ))
    _team_count=$(( _lt + _wt ))

    printf '  %bLocal teams:%b    %b%s%b (%s workers each)\n' \
      "${C_BOLD_WHITE}" "${C_RESET}" "${C_BOLD_GREEN}" "$_lt" "${C_RESET}" "$_wc"
    if [ "$_wt" -gt 0 ]; then
      printf '  %bWorktree teams:%b %b%s%b\n' \
        "${C_BOLD_WHITE}" "${C_RESET}" "${C_BOLD_GREEN}" "$_wt" "${C_RESET}"
    fi
  fi

  # --- Section 2: Available Premade Teams ---
  printf '\n  %b─── Available Premade Teams %b%s%b\n' \
    "${C_BOLD_WHITE}" "${C_DIM}" "$(repeat_char '─' $(( _cw - 28 )))" "${C_RESET}"

  local _found_any=false
  local _tdir _tf _tname _tdesc _marker _marker_label
  for _tdir in "${HOME}/.local/share/doey/teams" "${_proj_dir}/teams" "${_proj_dir}/.doey/teams"; do
    [ -d "$_tdir" ] || continue
    for _tf in "$_tdir"/*.team.md; do
      [ -f "$_tf" ] || continue
      _tname=$(grep '^name:' "$_tf" | head -1 | sed 's/name:[[:space:]]*//;s/"//g')
      _tdesc=$(grep '^description:' "$_tf" | head -1 | sed 's/description:[[:space:]]*//;s/"//g')
      [ -z "$_tname" ] && _tname=$(basename "$_tf" .team.md)
      [ -z "$_tdesc" ] && _tdesc="(no description)"

      # Check if active — name appears in _active_defs
      _marker="${C_DIM}○${C_RESET}"
      _marker_label=""
      case " ${_active_defs:-} " in
        *" ${_tname} "*)
          _marker="${C_BOLD_GREEN}●${C_RESET}"
          _marker_label="  ${C_GREEN}(active)${C_RESET}"
          ;;
      esac

      printf '  %b %b%-12s%b %b%s%b%b\n' \
        "$_marker" \
        "${C_BOLD_CYAN}" "$_tname" "${C_RESET}" \
        "${C_DIM}" "$(_truncate "$_tdesc" $(( _cw - 22 )))" "${C_RESET}" \
        "$_marker_label"
      _found_any=true
    done
  done

  if [ "$_found_any" = false ]; then
    printf '  %b(none found — add .team.md files to ~/.local/share/doey/teams/)%b\n' "${C_DIM}" "${C_RESET}"
  fi

  printf '\n  %bAdd:%b DOEY_TEAM_<N>_TYPE=premade DOEY_TEAM_<N>_DEF=<name>\n' "${C_DIM}" "${C_RESET}"
}

_render_available_agents() {
  local _proj_dir _agents_dir _f _name _model _desc _color _memory _idx
  _proj_dir=$(_get_proj_dir)
  _agents_dir="${_proj_dir}/agents"

  printf '\n  %bAvailable Agents%b  %b(press a-z to inspect)%b\n' "${C_BOLD_WHITE}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  printf '  %b────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"

  if [ ! -d "$_agents_dir" ]; then
    printf '    %b(no agents directory)%b\n' "${C_DIM}" "${C_RESET}"
    return
  fi

  _idx=0
  local _letter
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
    _letter=$(printf "\\$(printf '%03o' $((97 + _idx)))")
    printf '    %b%s)%b %b%-20s%b %b%-8s%b %b%s%b\n' \
      "${C_BOLD_CYAN}" "$_letter" "${C_RESET}" \
      "${C_CYAN}" "$_name" "${C_RESET}" \
      "${C_GREEN}" "$_model" "${C_RESET}" \
      "${C_DIM}" "$(_truncate "$_desc" $((TERM_W - 40)))" "${C_RESET}"
    [ -n "$_color" ] && printf '      %bcolor: %s%b' "${C_DIM}" "$_color" "${C_RESET}"
    [ -n "$_memory" ] && printf '  %bmemory: %s%b' "${C_DIM}" "$_memory" "${C_RESET}"
    if [ -n "$_color" ] || [ -n "$_memory" ]; then printf '\n'; fi
    _idx=$((_idx + 1))
  done
  [ "$_idx" -eq 0 ] && printf '    %b(no agent files found)%b\n' "${C_DIM}" "${C_RESET}"
}

_render_agent_detail() {
  local _agent_name="$1"
  local _proj_dir _agents_dir _f="" _found=""
  _proj_dir=$(_get_proj_dir)
  _agents_dir="${_proj_dir}/agents"

  # Find the agent file by name or filename
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
    printf '  %bPress 3 to return to agent list%b\n' "${C_DIM}" "${C_RESET}"
    return
  fi

  # Read frontmatter fields
  local _name _model _desc _color _memory
  _name=$(_parse_agent_frontmatter "$_found" "name")
  _model=$(_parse_agent_frontmatter "$_found" "model")
  _desc=$(_parse_agent_frontmatter "$_found" "description")
  _color=$(_parse_agent_frontmatter "$_found" "color")
  _memory=$(_parse_agent_frontmatter "$_found" "memory")
  [ -z "$_name" ] && _name=$(basename "$_found" .md)

  printf '\n  %b● %s%b\n' "${C_BOLD_CYAN}" "$_name" "${C_RESET}"
  printf '  %b──────────────────────────────────────────%b\n' "${C_DIM}" "${C_RESET}"
  printf '  %bModel:%b      %s\n' "${C_BOLD_WHITE}" "${C_RESET}" "${_model:-?}"
  printf '  %bColor:%b      %s\n' "${C_BOLD_WHITE}" "${C_RESET}" "${_color:---}"
  printf '  %bMemory:%b     %s\n' "${C_BOLD_WHITE}" "${C_RESET}" "${_memory:---}"
  printf '  %bFile:%b       %s\n' "${C_BOLD_WHITE}" "${C_RESET}" "$_found"
  printf '  %bDescription:%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  printf '    %s\n\n' "${_desc:-(no description)}"

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
      # Render markdown-ish: headers bold, rest normal
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

  printf '\n  %bPress 3 to return to agent list%b\n' "${C_DIM}" "${C_RESET}"
}

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

  printf '  %b Grid & Teams%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_INITIAL_WORKER_COLS"    "2"   "$DOEY_INITIAL_WORKER_COLS"
  _settings_row "DOEY_INITIAL_TEAMS"          "2"   "$DOEY_INITIAL_TEAMS"
  _settings_row "DOEY_INITIAL_WORKTREE_TEAMS" "0"   "$DOEY_INITIAL_WORKTREE_TEAMS"
  _settings_row "DOEY_MAX_WORKERS"            "20"  "$DOEY_MAX_WORKERS"
  _settings_row "DOEY_MAX_WATCHDOG_SLOTS"     "6"   "$DOEY_MAX_WATCHDOG_SLOTS"
  printf '\n'

  printf '  %b Models%b\n' "${C_BOLD_WHITE}" "${C_RESET}"
  _settings_row "DOEY_MANAGER_MODEL"          "opus"    "$DOEY_MANAGER_MODEL"
  _settings_row "DOEY_WORKER_MODEL"           "opus"    "$DOEY_WORKER_MODEL"
  _settings_row "DOEY_WATCHDOG_MODEL"         "sonnet"  "$DOEY_WATCHDOG_MODEL"
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
}

while true; do
  _doey_load_config
  DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"

  # Fast refresh for live settings window
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
    # Support agents:<name> for drill-down
    case "$_CURRENT_VIEW" in
      agents:*) _AGENT_DETAIL="${_CURRENT_VIEW#agents:}"; _CURRENT_VIEW="agent_detail" ;;
      settings|teams|agents) ;;
      *) _CURRENT_VIEW="settings" ;;
    esac
  fi

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

  printf '  %b%s%b\n' "${C_DIM}" "$HR" "${C_RESET}"
  printf '  %bPress 1-3%b to switch views  %b·%b  %bdoey config%b to edit  %b·%b  %bdoey reload%b to apply\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" "${C_DIM}" "${C_RESET}" \
    "${C_BOLD_WHITE}" "${C_RESET}" "${C_DIM}" "${C_RESET}" \
    "${C_BOLD_WHITE}" "${C_RESET}"

  # Handle a keypress: view switching (1-3) and agent selection (a-z)
  _handle_key() {
    local _key="$1"
    case "$_key" in
      1) echo "settings" > "$_view_file" ;;
      2) echo "teams" > "$_view_file" ;;
      3) echo "agents" > "$_view_file" ;;
      [a-z])
        if [ "$_CURRENT_VIEW" = "agents" ] || [ "$_CURRENT_VIEW" = "agent_detail" ]; then
          local _ai _ac=0 _proj_dir _af _an
          _ai=$(printf '%d' "'$_key" 2>/dev/null)
          _ai=$((_ai - 97))
          _proj_dir=$(_get_proj_dir)
          for _af in "$_proj_dir/agents"/*.md; do
            [ -f "$_af" ] || continue
            if [ "$_ac" -eq "$_ai" ]; then
              _an=$(_parse_agent_frontmatter "$_af" "name")
              [ -z "$_an" ] && _an=$(basename "$_af" .md)
              echo "agents:$_an" > "$_view_file"
              break
            fi
            _ac=$((_ac + 1))
          done
        fi
        ;;
    esac
  }

  # Wait for trigger or timeout
  _trigger="${RUNTIME_DIR}/status/settings_refresh_trigger"
  if [ "${DOEY_SETTINGS_LIVE:-0}" = "1" ]; then
    _waited=0
    while [ "$_waited" -lt 5 ]; do
      if [ -f "$_trigger" ]; then rm -f "$_trigger" 2>/dev/null; break; fi
      _key=""
      read -t 1 -n1 _key 2>/dev/null || true
      if [ -n "$_key" ]; then _handle_key "$_key"; break; fi
      _waited=$((_waited + 1))
    done
  else
    _key=""
    read -t "$_refresh_interval" -n1 _key 2>/dev/null || true
    [ -n "$_key" ] && _handle_key "$_key"
  fi
done
