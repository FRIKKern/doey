#!/usr/bin/env bash
# doey-menu.sh — Interactive menu and project selection UI for Doey.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_menu_sourced:-}" = "1" ] && return 0
__doey_menu_sourced=1

# ── Dependencies ────────────────────────────────────────────────────
# shellcheck source=doey-helpers.sh
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [ "${__doey_helpers_sourced:-}" != "1" ]; then
  source "${SCRIPT_DIR}/doey-helpers.sh"
fi
if [ "${__doey_ui_sourced:-}" != "1" ]; then
  source "${SCRIPT_DIR}/doey-ui.sh"
fi

# ── Caller must provide ────────────────────────────────────────────
# These functions/variables are expected from doey.sh:
#   PROJECTS_FILE        — path to projects registry file
#   register_project()   — register cwd as a project
#   attach_or_switch()   — attach to existing tmux session
#   launch_with_grid()   — launch a new doey session
#   _kill_doey_session() — kill a doey tmux session + cleanup

# ── List Projects ───────────────────────────────────────────────────
# Display all registered projects with running status
list_projects() {
  doey_header "Doey — Projects"
  printf '\n'
  local has_projects=false
  while IFS=: read -r name path; do
    [[ -z "$name" ]] && continue
    has_projects=true
    local short_path="${path/#$HOME/\~}"
    if session_exists "doey-${name}"; then
      printf "  ${SUCCESS}●${RESET} ${BOLD}%-20s${RESET} %s\n" "$name" "$short_path"
    else
      printf "  ${DIM}○${RESET} %-20s ${DIM}%s${RESET}\n" "$name" "$short_path"
    fi
  done < "$PROJECTS_FILE"
  if [[ "$has_projects" == false ]]; then
    doey_info "(no projects registered)"
  fi
  printf '\n'
  printf "  ${SUCCESS}●${RESET} running  ${DIM}○${RESET} stopped\n"
  printf '\n'
}

# ── Interactive Project Picker ──────────────────────────────────────
# Show interactive project picker — Go TUI (huh) primary, shell fallback.
show_menu() {
  local grid="$1"

  # Primary: Go TUI picker (Charmbracelet huh — proper terminal handling)
  if command -v doey-tui >/dev/null 2>&1; then
    local _menu_out _menu_tmpfile
    _menu_tmpfile=$(mktemp "${TMPDIR:-/tmp}/doey-menu.XXXXXX")
    if doey-tui menu --projects-file "$PROJECTS_FILE" --cwd "$(pwd)" --grid "$grid" \
         > "$_menu_tmpfile" </dev/tty 2>/dev/tty; then
      _menu_out=$(cat "$_menu_tmpfile")
      rm -f "$_menu_tmpfile"
      [ -z "$_menu_out" ] && return 0

      local _action _name _path
      if command -v jq >/dev/null 2>&1; then
        _action=$(printf '%s' "$_menu_out" | jq -r '.action // empty') || _action=""
        _name=$(printf '%s' "$_menu_out" | jq -r '.name // empty') || _name=""
        _path=$(printf '%s' "$_menu_out" | jq -r '.path // empty') || _path=""
      else
        _action=$(printf '%s' "$_menu_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('action',''))" 2>/dev/null) || _action=""
        _name=$(printf '%s' "$_menu_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null) || _name=""
        _path=$(printf '%s' "$_menu_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('path',''))" 2>/dev/null) || _path=""
      fi

      case "$_action" in
        open)
          local _session="doey-${_name}"
          if session_exists "$_session"; then
            attach_or_switch "$_session"
          else
            launch_with_grid "$_name" "$_path" "$grid"
          fi
          ;;
        restart)
          local _session="doey-${_name}"
          session_exists "$_session" && _kill_doey_session "$_session"
          launch_with_grid "$_name" "$_path" "$grid"
          ;;
        kill)
          local _session="doey-${_name}"
          session_exists "$_session" && _kill_doey_session "$_session"
          # Re-show menu after kill
          show_menu "$grid"
          ;;
        init)
          register_project "$(pwd)"
          local init_name
          init_name="$(find_project "$(pwd)")"
          [[ -n "$init_name" ]] && launch_with_grid "$init_name" "$(pwd)" "$grid"
          ;;
        quit) return 0 ;;
      esac
      return 0
    fi
    rm -f "$_menu_tmpfile"
    # Fall through to shell picker on TUI failure
  fi

  _show_menu_shell "$grid"
}

# Shell fallback picker (used when doey-tui is not available)
_show_menu_shell() {
  local grid="$1"

  doey_header "Doey"
  doey_warn "No project registered for $(pwd)"
  printf '\n'

  # Read projects into arrays
  local names paths statuses status_plain; names=() paths=() statuses=() status_plain=()
  while IFS=: read -r name path; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    paths+=("$path")
    if session_exists "doey-${name}"; then
      statuses+=("${SUCCESS}● running${RESET}")
      status_plain+=("running")
    else
      statuses+=("${DIM}○ stopped${RESET}")
      status_plain+=("stopped")
    fi
  done < "$PROJECTS_FILE"

  # Count running sessions for the kill-all option
  local running_count=0
  for i in "${!names[@]}"; do
    session_exists "doey-${names[$i]}" && running_count=$((running_count + 1))
  done

  if [[ ${#names[@]} -gt 0 ]]; then
    # ── Interactive picker (works with or without gum) ──
    local _cursor=0
    local _total=${#names[@]}
    local _msg=""
    local _old_tty_settings

    # Refresh status arrays (after kill/restart)
    _picker_refresh() {
      statuses=(); status_plain=()
      running_count=0
      for i in "${!names[@]}"; do
        if session_exists "doey-${names[$i]}"; then
          statuses+=("running")
          status_plain+=("running")
          running_count=$((running_count + 1))
        else
          statuses+=("stopped")
          status_plain+=("stopped")
        fi
      done
    }

    # Render the picker list
    _picker_render() {
      # Restore cursor to saved position, then clear below
      printf '\033[u'   # restore saved cursor position
      printf '\033[J'   # clear from cursor to end

      local i
      for i in "${!names[@]}"; do
        local _sp="${paths[$i]/#$HOME/\~}"
        local _icon="○"
        [ "${status_plain[$i]}" = "running" ] && _icon="●"

        if [ "$i" -eq "$_cursor" ]; then
          # Focused: bold cyan with cursor
          printf '  \033[1;36m▸ %s %-18s\033[0;90m %s\033[0m\n' "$_icon" "${names[$i]}" "$_sp"
        else
          # Unfocused: dim
          printf '    \033[0;90m%s %-18s %s\033[0m\n' "$_icon" "${names[$i]}" "$_sp"
        fi
      done

      printf '\n'
      printf '  \033[0;90menter\033[0m open  \033[0;90m·\033[0m  \033[0;90mr\033[0m restart  \033[0;90m·\033[0m  \033[0;90mx\033[0m kill  \033[0;90m·\033[0m  \033[0;90mi\033[0m init  \033[0;90m·\033[0m  \033[0;90mq\033[0m quit\n'

      # Status message line (or blank)
      if [ -n "$_msg" ]; then
        printf '  %b\n' "$_msg"
      else
        printf '\n'
      fi
    }

    # Save cursor position, then do initial render
    printf '\033[s'   # save cursor position (anchor for all re-renders)
    _picker_render

    # Save terminal state, disable canonical mode so keys are read immediately
    # -icanon: no line buffering (keys available instantly)
    # -echo: don't echo typed characters
    # min 1 time 0: read returns after 1 byte, no timeout
    _old_tty_settings=$(stty -g 2>/dev/null || true)
    stty -icanon -echo min 1 time 0 2>/dev/null || true
    tput civis 2>/dev/null || true

    _picker_cleanup() {
      tput cnorm 2>/dev/null || true
      [ -n "$_old_tty_settings" ] && stty "$_old_tty_settings" 2>/dev/null || true
    }
    trap '_picker_cleanup' INT TERM EXIT

    # ── Input loop ──
    local _done=false
    while [ "$_done" = false ]; do
      _msg=""
      local _key
      IFS= read -rsn1 _key 2>/dev/null || true

      case "$_key" in
        # Enter key
        "")
          _picker_cleanup
          trap - INT TERM EXIT
          local _sel_name="${names[$_cursor]}"
          local _sel_path="${paths[$_cursor]}"
          local _sel_session="doey-${_sel_name}"
          if session_exists "$_sel_session"; then
            attach_or_switch "$_sel_session"
          else
            launch_with_grid "$_sel_name" "$_sel_path" "$grid"
          fi
          return 0
          ;;
        # Escape sequence (arrow keys)
        $'\033')
          local _seq
          IFS= read -rsn2 -t 0.1 _seq 2>/dev/null || true
          case "$_seq" in
            '[A') [ "$_cursor" -gt 0 ] && _cursor=$((_cursor - 1)) ;;   # Up
            '[B') [ "$_cursor" -lt $((_total - 1)) ] && _cursor=$((_cursor + 1)) ;; # Down
          esac
          ;;
        j|J) [ "$_cursor" -lt $((_total - 1)) ] && _cursor=$((_cursor + 1)) ;;
        k|K) [ "$_cursor" -gt 0 ] && _cursor=$((_cursor - 1)) ;;
        r|R)
          local _rname="${names[$_cursor]}"
          local _rpath="${paths[$_cursor]}"
          local _rsess="doey-${_rname}"
          if session_exists "$_rsess"; then
            _msg="${WARN}Restarting ${_rname}...${RESET}"
            _picker_render
            _kill_doey_session "$_rsess"
          fi
          _picker_cleanup
          trap - INT TERM EXIT
          launch_with_grid "$_rname" "$_rpath" "$grid"
          return 0
          ;;
        x|X|d|D)
          local _xname="${names[$_cursor]}"
          local _xsess="doey-${_xname}"
          if session_exists "$_xsess"; then
            _msg="${WARN}Killing ${_xname}...${RESET}"
            _picker_render
            _kill_doey_session "$_xsess"
            _picker_refresh
            _msg="${SUCCESS}Killed ${_xname}${RESET}"
          else
            _msg="${DIM}${_xname} is not running${RESET}"
          fi
          ;;
        i|I)
          _picker_cleanup
          trap - INT TERM EXIT
          register_project "$(pwd)"
          local init_name
          init_name="$(find_project "$(pwd)")"
          if [[ -n "$init_name" ]]; then
            launch_with_grid "$init_name" "$(pwd)" "$grid"
          fi
          return 0
          ;;
        q|Q)
          _done=true
          ;;
      esac

      [ "$_done" = false ] && _picker_render
    done

    _picker_cleanup
    trap - INT TERM EXIT
    return 0
  fi

  # ── Fallback (no projects registered) ──
  printf "  ${DIM}No projects registered.${RESET}\n\n"
  printf "  ${BOLD}i${RESET})  Init current directory as new project\n"
  printf "  ${BOLD}q${RESET})  Quit\n"
  printf '\n'

  read -rp "  > " choice
  case "$choice" in
    i|I|init)
      register_project "$(pwd)"
      local init_name
      init_name="$(find_project "$(pwd)")"
      if [[ -n "$init_name" ]]; then
        launch_with_grid "$init_name" "$(pwd)" "$grid"
      fi
      ;;
    q|Q) return 0 ;;
    *) doey_error "Invalid option"; return 1 ;;
  esac
}
