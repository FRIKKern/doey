#!/usr/bin/env bash
# Doey Info Panel — dashboard for window 0, refreshes every 5 minutes.
set -uo pipefail

# Source role definitions
_ROLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=doey-roles.sh
source "${_ROLES_DIR}/doey-roles.sh" 2>/dev/null || true

RUNTIME_DIR="${1:-${DOEY_RUNTIME:-}}"
if [ -z "$RUNTIME_DIR" ]; then
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
fi
if [ -z "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ]; then
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 8 --italic "  Waiting for runtime directory..."
  else
    printf "Doey Info Panel: waiting for runtime directory...\n"
  fi
  while true; do
    sleep 5
    RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
    [ -n "$RUNTIME_DIR" ] && [ -d "$RUNTIME_DIR" ] && break
  done
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"

# Load config: global, then project overlay
_load_config() {
  local _cfg="${HOME}/.config/doey/config.sh" _proj_dir=""
  # shellcheck source=/dev/null
  [ -f "$_cfg" ] && source "$_cfg"
  if [ -f "${RUNTIME_DIR}/session.env" ]; then
    _proj_dir=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    [ -n "$_proj_dir" ] && [ -f "${_proj_dir}/.doey/config.sh" ] && source "${_proj_dir}/.doey/config.sh"
  fi
}
_load_config
DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"

C_RESET='\033[0m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_MAGENTA='\033[35m'
C_BOLD_CYAN='\033[1;36m'
C_BOLD_WHITE='\033[1;97m'
C_BOLD_GREEN='\033[1;32m'
C_BOLD_YELLOW='\033[1;33m'
C_BOLD_RED='\033[1;31m'
C_BOLD_MAGENTA='\033[1;35m'

# Charmbracelet gum detection (output styling only — no interactive commands)
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

# Render a section header with gum styling or ANSI fallback
# Usage: gum_header "TITLE" [gum_fg_color] [ansi_escape]
gum_header() {
  local text="$1" gum_fg="${2:-6}" ansi="${3:-${C_BOLD_CYAN}}"
  if [ "$HAS_GUM" = true ]; then
    gum style --bold --foreground "$gum_fg" "  $text"
  else
    printf '%b  %s%b' "$ansi" "$text" "${C_RESET}"
  fi
}

# Render a divider with gum styling or ANSI fallback
gum_divider() {
  local line="$1"
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 8 "$line"
  else
    printf '%b%s%b\n' "${C_DIM}" "$line" "${C_RESET}"
  fi
}

# Sets _ENV_<KEY> for each requested key from an env file (single-pass, 0 forks).
read_env_file() {
  local _ref_file="$1"; shift
  # Clear output vars
  for _ref_k in "$@"; do printf -v "_ENV_${_ref_k}" '%s' ""; done
  [ -f "$_ref_file" ] || return 0
  while IFS='=' read -r _ref_key _ref_val; do
    _ref_val="${_ref_val%\"}" && _ref_val="${_ref_val#\"}"
    for _ref_k in "$@"; do
      if [ "$_ref_key" = "$_ref_k" ]; then
        printf -v "_ENV_${_ref_k}" '%s' "$_ref_val"
        break
      fi
    done
  done < "$_ref_file"
  return 0
}

format_uptime() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%dm' "$(( secs / 60 ))"
  elif [ "$secs" -lt 86400 ]; then
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    printf '%dh%dm' "$h" "$m"
  else
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    printf '%dd%dh' "$d" "$h"
  fi
}

repeat_char() {
  local ch="$1" len="$2" out="" i=0
  while [ "$i" -lt "$len" ]; do out="${out}${ch}"; i=$((i + 1)); done
  printf '%s' "$out"
}

read_pane_status() {
  local file="$1" status="?"
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      case "$line" in STATUS:*) status="${line#STATUS: }"; break ;; esac
    done < "$file"
  fi
  printf '%s' "$status"
}

# Count workers in a given state for a team. Uses _CACHED_SESSION_NAME from outer scope.
count_team_workers() {
  local window="$1" worker_panes="$2" state="$3"
  local count=0 pane_status
  for p in $(echo "$worker_panes" | tr ',' ' '); do
    pane_status=$(read_pane_status "${RUNTIME_DIR}/status/${_CACHED_SESSION_NAME}_${window}_${p}.status")
    case "$state" in
      idle)     case "$pane_status" in READY|FINISHED|"?") count=$((count + 1)) ;; esac ;;
      busy)     case "$pane_status" in BUSY|WORKING) count=$((count + 1)) ;; esac ;;
      reserved) case "$pane_status" in RESERVED) count=$((count + 1)) ;; esac ;;
    esac
  done
  printf '%d' "$count"
}

visible_len() { local s; s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'); printf '%d' "${#s}"; }

add_left() {
  printf -v "L_${LC}" '%s' "$1"
  LC=$((LC + 1))
}

# add_cmd <color> <name> <description> — shorthand for colored dotted_leader entry
add_cmd() {
  add_left "  $(dotted_leader "$(printf '%b%s%b' "$1" "$2" "${C_RESET}")" "$3" "$CMD_W")"
}

# add_cmd_pair — two commands side by side (second is optional)
add_cmd_pair() {
  local c1="$1" n1="$2" d1="$3" c2="${4:-}" n2="${5:-}" d2="${6:-}"
  local left right
  left="$(dotted_leader "$(printf '%b%s%b' "$c1" "$n1" "${C_RESET}")" "$d1" "$COL_W")"
  if [ -n "$n2" ]; then
    right="$(dotted_leader "$(printf '%b%s%b' "$c2" "$n2" "${C_RESET}")" "$d2" "$COL_W")"
    add_left "  ${left}  ${right}"
  else
    add_left "  ${left}"
  fi
}

dotted_leader() {
  local name="$1" desc="$2" max_w="$3"
  local name_vis desc_vis dots_needed
  name_vis=$(visible_len "$name")
  desc_vis=$(visible_len "$desc")
  dots_needed=$((max_w - name_vis - desc_vis - 2))
  [ "$dots_needed" -lt 2 ] && dots_needed=2
  printf '%s %b%s%b %s' "$name" "${C_DIM}" "$(repeat_char '.' "$dots_needed")" "${C_RESET}" "$desc"
}

_CACHED_SESSION_NAME=""
_CACHED_PROJECT_NAME=""
_CACHED_PROJECT_DIR=""

# Block-letter font: each char is 6 rows. Sets CHAR_R0..CHAR_R5.
get_block_char() {
  case "$1" in
    A) CHAR_R0=' █████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='███████║'; CHAR_R3='██╔══██║'; CHAR_R4='██║  ██║'; CHAR_R5='╚═╝  ╚═╝' ;;
    B) CHAR_R0='██████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='██████╔╝'; CHAR_R3='██╔══██╗'; CHAR_R4='██████╔╝'; CHAR_R5='╚═════╝ ' ;;
    C) CHAR_R0=' ██████╗'; CHAR_R1='██╔════╝'; CHAR_R2='██║     '; CHAR_R3='██║     '; CHAR_R4='╚██████╗'; CHAR_R5=' ╚═════╝' ;;
    D) CHAR_R0='██████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='██║  ██║'; CHAR_R3='██║  ██║'; CHAR_R4='██████╔╝'; CHAR_R5='╚═════╝ ' ;;
    E) CHAR_R0='███████╗'; CHAR_R1='██╔════╝'; CHAR_R2='█████╗  '; CHAR_R3='██╔══╝  '; CHAR_R4='███████╗'; CHAR_R5='╚══════╝' ;;
    F) CHAR_R0='███████╗'; CHAR_R1='██╔════╝'; CHAR_R2='█████╗  '; CHAR_R3='██╔══╝  '; CHAR_R4='██║     '; CHAR_R5='╚═╝     ' ;;
    G) CHAR_R0=' ██████╗ '; CHAR_R1='██╔════╝ '; CHAR_R2='██║  ███╗'; CHAR_R3='██║   ██║'; CHAR_R4='╚██████╔╝'; CHAR_R5=' ╚═════╝ ' ;;
    H) CHAR_R0='██╗  ██╗'; CHAR_R1='██║  ██║'; CHAR_R2='███████║'; CHAR_R3='██╔══██║'; CHAR_R4='██║  ██║'; CHAR_R5='╚═╝  ╚═╝' ;;
    I) CHAR_R0='██╗'; CHAR_R1='██║'; CHAR_R2='██║'; CHAR_R3='██║'; CHAR_R4='██║'; CHAR_R5='╚═╝' ;;
    J) CHAR_R0='     ██╗'; CHAR_R1='     ██║'; CHAR_R2='     ██║'; CHAR_R3='██   ██║'; CHAR_R4='╚█████╔╝'; CHAR_R5=' ╚════╝ ' ;;
    K) CHAR_R0='██╗  ██╗'; CHAR_R1='██║ ██╔╝'; CHAR_R2='█████╔╝ '; CHAR_R3='██╔═██╗ '; CHAR_R4='██║  ██╗'; CHAR_R5='╚═╝  ╚═╝' ;;
    L) CHAR_R0='██╗     '; CHAR_R1='██║     '; CHAR_R2='██║     '; CHAR_R3='██║     '; CHAR_R4='███████╗'; CHAR_R5='╚══════╝' ;;
    M) CHAR_R0='███╗   ███╗'; CHAR_R1='████╗ ████║'; CHAR_R2='██╔████╔██║'; CHAR_R3='██║╚██╔╝██║'; CHAR_R4='██║ ╚═╝ ██║'; CHAR_R5='╚═╝     ╚═╝' ;;
    N) CHAR_R0='███╗   ██╗'; CHAR_R1='████╗  ██║'; CHAR_R2='██╔██╗ ██║'; CHAR_R3='██║╚██╗██║'; CHAR_R4='██║ ╚████║'; CHAR_R5='╚═╝  ╚═══╝' ;;
    O) CHAR_R0=' ██████╗ '; CHAR_R1='██╔═══██╗'; CHAR_R2='██║   ██║'; CHAR_R3='██║   ██║'; CHAR_R4='╚██████╔╝'; CHAR_R5=' ╚═════╝ ' ;;
    P) CHAR_R0='██████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='██████╔╝'; CHAR_R3='██╔═══╝ '; CHAR_R4='██║     '; CHAR_R5='╚═╝     ' ;;
    Q) CHAR_R0=' ██████╗  '; CHAR_R1='██╔═══██╗ '; CHAR_R2='██║   ██║ '; CHAR_R3='██║▄▄ ██║ '; CHAR_R4='╚██████╔╝ '; CHAR_R5=' ╚══▀▀═╝  ' ;;
    R) CHAR_R0='██████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='██████╔╝'; CHAR_R3='██╔══██╗'; CHAR_R4='██║  ██║'; CHAR_R5='╚═╝  ╚═╝' ;;
    S) CHAR_R0='███████╗'; CHAR_R1='██╔════╝'; CHAR_R2='███████╗'; CHAR_R3='╚════██║'; CHAR_R4='███████║'; CHAR_R5='╚══════╝' ;;
    T) CHAR_R0='████████╗'; CHAR_R1='╚══██╔══╝'; CHAR_R2='   ██║   '; CHAR_R3='   ██║   '; CHAR_R4='   ██║   '; CHAR_R5='   ╚═╝   ' ;;
    U) CHAR_R0='██╗   ██╗'; CHAR_R1='██║   ██║'; CHAR_R2='██║   ██║'; CHAR_R3='██║   ██║'; CHAR_R4='╚██████╔╝'; CHAR_R5=' ╚═════╝ ' ;;
    V) CHAR_R0='██╗   ██╗'; CHAR_R1='██║   ██║'; CHAR_R2='██║   ██║'; CHAR_R3='╚██╗ ██╔╝'; CHAR_R4=' ╚████╔╝ '; CHAR_R5='  ╚═══╝  ' ;;
    W) CHAR_R0='██╗    ██╗'; CHAR_R1='██║    ██║'; CHAR_R2='██║ █╗ ██║'; CHAR_R3='██║███╗██║'; CHAR_R4='╚███╔███╔╝'; CHAR_R5=' ╚══╝╚══╝ ' ;;
    X) CHAR_R0='██╗  ██╗'; CHAR_R1='╚██╗██╔╝'; CHAR_R2=' ╚███╔╝ '; CHAR_R3=' ██╔██╗ '; CHAR_R4='██╔╝ ██╗'; CHAR_R5='╚═╝  ╚═╝' ;;
    Y) CHAR_R0='██╗   ██╗'; CHAR_R1='╚██╗ ██╔╝'; CHAR_R2=' ╚████╔╝ '; CHAR_R3='  ╚██╔╝  '; CHAR_R4='   ██║   '; CHAR_R5='   ╚═╝   ' ;;
    Z) CHAR_R0='███████╗'; CHAR_R1='╚════██║'; CHAR_R2='  ███╔╝ '; CHAR_R3=' ███╔╝  '; CHAR_R4='███████╗'; CHAR_R5='╚══════╝' ;;
    0) CHAR_R0=' ██████╗ '; CHAR_R1='██╔═══██╗'; CHAR_R2='██║   ██║'; CHAR_R3='██║   ██║'; CHAR_R4='╚██████╔╝'; CHAR_R5=' ╚═════╝ ' ;;
    1) CHAR_R0=' ██╗'; CHAR_R1='███║'; CHAR_R2='╚██║'; CHAR_R3=' ██║'; CHAR_R4=' ██║'; CHAR_R5=' ╚═╝' ;;
    2) CHAR_R0='██████╗ '; CHAR_R1='╚════██╗'; CHAR_R2=' █████╔╝'; CHAR_R3='██╔═══╝ '; CHAR_R4='███████╗'; CHAR_R5='╚══════╝' ;;
    3) CHAR_R0='██████╗ '; CHAR_R1='╚════██╗'; CHAR_R2=' █████╔╝'; CHAR_R3=' ╚═══██╗'; CHAR_R4='██████╔╝'; CHAR_R5='╚═════╝ ' ;;
    4) CHAR_R0='██╗  ██╗'; CHAR_R1='██║  ██║'; CHAR_R2='███████║'; CHAR_R3='╚════██║'; CHAR_R4='     ██║'; CHAR_R5='     ╚═╝' ;;
    5) CHAR_R0='███████╗'; CHAR_R1='██╔════╝'; CHAR_R2='███████╗'; CHAR_R3='╚════██║'; CHAR_R4='███████║'; CHAR_R5='╚══════╝' ;;
    6) CHAR_R0=' ██████╗ '; CHAR_R1='██╔════╝ '; CHAR_R2='███████╗ '; CHAR_R3='██╔═══██╗'; CHAR_R4='╚██████╔╝'; CHAR_R5=' ╚═════╝ ' ;;
    7) CHAR_R0='███████╗'; CHAR_R1='╚════██║'; CHAR_R2='    ██╔╝'; CHAR_R3='   ██╔╝ '; CHAR_R4='   ██║  '; CHAR_R5='   ╚═╝  ' ;;
    8) CHAR_R0=' █████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='╚█████╔╝'; CHAR_R3='██╔══██╗'; CHAR_R4='╚█████╔╝'; CHAR_R5=' ╚════╝ ' ;;
    9) CHAR_R0=' █████╗ '; CHAR_R1='██╔══██╗'; CHAR_R2='╚██████║'; CHAR_R3=' ╚═══██║'; CHAR_R4=' █████╔╝'; CHAR_R5=' ╚════╝ ' ;;
    -) CHAR_R0='        '; CHAR_R1='        '; CHAR_R2='███████╗'; CHAR_R3='╚══════╝'; CHAR_R4='        '; CHAR_R5='        ' ;;
    .) CHAR_R0='   '; CHAR_R1='   '; CHAR_R2='   '; CHAR_R3='   '; CHAR_R4='██╗'; CHAR_R5='╚═╝' ;;
    _) CHAR_R0='        '; CHAR_R1='        '; CHAR_R2='        '; CHAR_R3='        '; CHAR_R4='███████╗'; CHAR_R5='╚══════╝' ;;
    ' ') CHAR_R0='   '; CHAR_R1='   '; CHAR_R2='   '; CHAR_R3='   '; CHAR_R4='   '; CHAR_R5='   ' ;;
    *) CHAR_R0='  '; CHAR_R1='  '; CHAR_R2='  '; CHAR_R3='  '; CHAR_R4='  '; CHAR_R5='  ' ;;
  esac
}

while true; do
  printf '\033[2J\033[H'

  if [ ! -f "$SESSION_ENV" ]; then
    if [ "$HAS_GUM" = true ]; then
      gum style --foreground 8 --italic "  Waiting for session.env..."
    else
      printf 'Doey Info Panel: waiting for session.env...\n'
    fi
    sleep 5
    continue
  fi

  TERM_W=$(tput cols 2>/dev/null || echo 120)
  [ "$TERM_W" -lt 80 ] && TERM_W=80
  LEFT_W=$((TERM_W * 55 / 100))

  if [ -z "$_CACHED_SESSION_NAME" ]; then
    read_env_file "$SESSION_ENV" SESSION_NAME PROJECT_NAME PROJECT_DIR TEAM_WINDOWS
    _CACHED_SESSION_NAME="${_ENV_SESSION_NAME//[-:.]/_}"
    _CACHED_PROJECT_NAME="$_ENV_PROJECT_NAME"
    _CACHED_PROJECT_DIR="$_ENV_PROJECT_DIR"
    TEAM_WINDOWS="$_ENV_TEAM_WINDOWS"
  else
    read_env_file "$SESSION_ENV" TEAM_WINDOWS
    TEAM_WINDOWS="$_ENV_TEAM_WINDOWS"
  fi
  PROJECT_NAME="$_CACHED_PROJECT_NAME"
  SESSION_NAME="$_CACHED_SESSION_NAME"

  NOW=$(date +%s)
  if stat -f '%m' "$SESSION_ENV" >/dev/null 2>&1; then
    START_TIME=$(stat -f '%m' "$SESSION_ENV")
  else
    START_TIME=$(stat -c '%Y' "$SESSION_ENV" 2>/dev/null || echo "$NOW")
  fi
  UPTIME_SECS=$((NOW - START_TIME))
  UPTIME_STR=$(format_uptime "$UPTIME_SECS")

  TOTAL_WORKERS=0; TOTAL_IDLE=0; TOTAL_BUSY=0; TOTAL_RESERVED=0
  TEAM_COUNT=0; TEAM_LINE_COUNT=0

  for W in $(echo "${TEAM_WINDOWS:-}" | tr ',' ' '); do
    [ -z "$W" ] && continue

    if [ "$W" = "0" ] && [ ! -f "${RUNTIME_DIR}/team_0.env" ]; then
      TEAM_FILE="$SESSION_ENV"
    else
      TEAM_FILE="${RUNTIME_DIR}/team_${W}.env"
      # Skip despawned teams whose env file was already removed
      [ -f "$TEAM_FILE" ] || continue
    fi
    TEAM_COUNT=$((TEAM_COUNT + 1))

    read_env_file "$TEAM_FILE" WORKER_PANES WORKER_COUNT WORKTREE_DIR WORKTREE_BRANCH TEAM_TYPE TEAM_NAME
    WORKER_PANES="$_ENV_WORKER_PANES"
    WORKER_COUNT="${_ENV_WORKER_COUNT:-0}"
    TOTAL_WORKERS=$((TOTAL_WORKERS + WORKER_COUNT))

    IDLE_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "idle")
    BUSY_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "busy")
    RESV_COUNT=$(count_team_workers "$W" "$WORKER_PANES" "reserved")
    TOTAL_IDLE=$((TOTAL_IDLE + IDLE_COUNT))
    TOTAL_BUSY=$((TOTAL_BUSY + BUSY_COUNT))
    TOTAL_RESERVED=$((TOTAL_RESERVED + RESV_COUNT))

    printf -v "TEAM_WIN_${TEAM_LINE_COUNT}" '%s' "$W"
    printf -v "TEAM_IDLE_${TEAM_LINE_COUNT}" '%s' "$IDLE_COUNT"
    printf -v "TEAM_BUSY_${TEAM_LINE_COUNT}" '%s' "$BUSY_COUNT"
    printf -v "TEAM_RESV_${TEAM_LINE_COUNT}" '%s' "$RESV_COUNT"
    printf -v "TEAM_WCNT_${TEAM_LINE_COUNT}" '%s' "$WORKER_COUNT"
    printf -v "TEAM_WT_DIR_${TEAM_LINE_COUNT}" '%s' "$_ENV_WORKTREE_DIR"
    printf -v "TEAM_WT_BRANCH_${TEAM_LINE_COUNT}" '%s' "$_ENV_WORKTREE_BRANCH"
    printf -v "TEAM_TYPE_${TEAM_LINE_COUNT}" '%s' "$_ENV_TEAM_TYPE"
    printf -v "TEAM_NAME_V_${TEAM_LINE_COUNT}" '%s' "$_ENV_TEAM_NAME"
    TEAM_LINE_COUNT=$((TEAM_LINE_COUNT + 1))
  done

  # Tunnel status (multi-port aware — TUNNEL_PORTS_LIST + TUNNEL_HOSTNAME
  # are written by doey-port-watcher.sh and the tailscale provider)
  read_env_file "${RUNTIME_DIR}/tunnel.env" TUNNEL_URL TUNNEL_PROVIDER TUNNEL_ERROR TUNNEL_PORTS_LIST TUNNEL_HOSTNAME
  _tunnel_url="$_ENV_TUNNEL_URL"
  _tunnel_provider="$_ENV_TUNNEL_PROVIDER"
  _tunnel_error="$_ENV_TUNNEL_ERROR"
  _tunnel_ports_list="$_ENV_TUNNEL_PORTS_LIST"
  _tunnel_hostname="$_ENV_TUNNEL_HOSTNAME"

  # Remote mode
  _is_remote=$(tmux show-environment DOEY_REMOTE 2>/dev/null | cut -d= -f2-) || _is_remote=""

  LC=0
  add_left ""
  add_left "$(gum_header 'HOW TO USE DOEY')"
  add_left ""
  if [ "$HAS_GUM" = true ]; then
    add_left "  $(gum style --foreground 15 --bold '1.') Talk to the $(gum style --foreground 6 "${DOEY_ROLE_BOSS}") (pane 0.1, right side"
    add_left "     of this window) $(gum style --foreground 8 '—') describe your task and"
    add_left "     it coordinates with the team for you."
    add_left ""
    add_left "  $(gum style --foreground 15 --bold '2.') Switch to a team window ($(gum style --foreground 3 'Ctrl-b 1')) and"
    add_left "     talk to the ${DOEY_ROLE_TEAM_LEAD} directly."
    add_left ""
    add_left "  $(gum style --foreground 15 --bold '3.') Click any worker pane and run $(gum style --foreground 2 '/doey-reserve')"
    add_left "     to claim it for yourself."
  else
    add_left "$(printf '%b  1.%b Talk to the %b%s%b (pane 0.1, right side' "${C_BOLD_WHITE}" "${C_RESET}" "${C_CYAN}" "${DOEY_ROLE_BOSS}" "${C_RESET}")"
    add_left "$(printf '     of this window) %b—%b describe your task and' "${C_DIM}" "${C_RESET}")"
    add_left "     it coordinates with the team for you."
    add_left ""
    add_left "$(printf '%b  2.%b Switch to a team window (%bCtrl-b 1%b) and' "${C_BOLD_WHITE}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}")"
    add_left "     talk to the ${DOEY_ROLE_TEAM_LEAD} directly."
    add_left ""
    add_left "$(printf '%b  3.%b Click any worker pane and run %b/doey-reserve%b' "${C_BOLD_WHITE}" "${C_RESET}" "${C_GREEN}" "${C_RESET}")"
    add_left "     to claim it for yourself."
  fi
  add_left ""
  add_left ""
  add_left "$(gum_header 'SLASH COMMANDS')"
  add_left ""

  CMD_W=$((LEFT_W - 4))
  COL_W=$((CMD_W / 2 - 1))

  add_left "$(gum_header ' Tasks' 2 "${C_BOLD_GREEN}")"
  add_cmd_pair "${C_GREEN}" "/doey-dispatch" "Send tasks" "${C_GREEN}" "/doey-research" "Research task"
  add_cmd_pair "${C_GREEN}" "/doey-task" "Manage tasks" "${C_GREEN}" "/doey-reserve" "Reserve pane"
  add_left ""
  add_left "$(gum_header ' Monitoring' 6 "${C_BOLD_CYAN}")"
  add_cmd_pair "${C_CYAN}" "/doey-status" "Pane status" "${C_CYAN}" "/doey-monitor" "Monitor workers"
  add_cmd_pair "${C_CYAN}" "/doey-list-windows" "List teams"
  add_left ""
  add_left "$(gum_header ' Team Management' 3 "${C_BOLD_YELLOW}")"
  add_cmd_pair "${C_YELLOW}" "/doey-add-window" "Add team" "${C_YELLOW}" "/doey-kill-window" "Kill team"
  add_cmd_pair "${C_YELLOW}" "/doey-worktree" "Git worktree" "${C_YELLOW}" "/doey-clear" "Relaunch"
  add_cmd_pair "${C_YELLOW}" "/doey-reload" "Hot-reload"
  add_left ""
  add_left "$(gum_header ' Maintenance' 5 "${C_BOLD_MAGENTA}")"
  add_cmd_pair "${C_MAGENTA}" "/doey-stop" "Stop worker" "${C_MAGENTA}" "/doey-purge" "Audit/fix"
  add_cmd_pair "${C_MAGENTA}" "/doey-simplify-everything" "Simplify" "${C_MAGENTA}" "/doey-repair" "Fix Dashboard"
  add_cmd_pair "${C_MAGENTA}" "/doey-reinstall" "Reinstall"
  add_cmd_pair "${C_MAGENTA}" "/doey-kill-session" "Kill session" "${C_MAGENTA}" "/doey-kill-all-sessions" "Kill all"
  add_left ""
  add_left "$(gum_header 'CLI COMMANDS')"
  add_left ""
  add_cmd "${C_YELLOW}" "doey"          "Launch (dynamic grid)"
  add_cmd "${C_YELLOW}" "doey add"      "Add worker column"
  add_cmd "${C_YELLOW}" "doey stop"     "Stop session"
  add_cmd "${C_YELLOW}" "doey list"     "List all projects"
  add_cmd "${C_YELLOW}" "doey doctor"   "Check installation"
  add_cmd "${C_YELLOW}" "doey test"     "Run E2E tests"
  add_cmd "${C_YELLOW}" "doey version"  "Show version info"

  HR=$(repeat_char "─" "$TERM_W")
  HR_THICK=$(repeat_char "═" "$TERM_W")

  TITLE_NAME=$(printf '%s' "$PROJECT_NAME" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9 ._-' ' ')
  # Cap ASCII art title at 9 chars to fit small panes
  TITLE_NAME="${TITLE_NAME:0:9}"
  for _r in 0 1 2 3 4 5; do printf -v "TITLE_R${_r}" '%s' ""; done
  _ci=0
  while [ "$_ci" -lt "${#TITLE_NAME}" ]; do
    get_block_char "${TITLE_NAME:${_ci}:1}"
    for _r in 0 1 2 3 4 5; do
      _tvar="TITLE_R${_r}"; _cvar="CHAR_R${_r}"
      printf -v "$_tvar" '%s' "${!_tvar}${!_cvar} "
    done
    _ci=$((_ci + 1))
  done

  _color_idx=$((RANDOM % 6))
  case "$_color_idx" in
    0) TITLE_COLOR="${C_BOLD_CYAN}";    _gum_fg="6" ;;
    1) TITLE_COLOR="${C_BOLD_GREEN}";   _gum_fg="2" ;;
    2) TITLE_COLOR="${C_BOLD_YELLOW}";  _gum_fg="3" ;;
    3) TITLE_COLOR="${C_BOLD_MAGENTA}"; _gum_fg="5" ;;
    4) TITLE_COLOR="${C_BOLD_RED}";     _gum_fg="1" ;;
    5) TITLE_COLOR="${C_BOLD_WHITE}";   _gum_fg="15" ;;
  esac

  if [ "$HAS_GUM" = true ]; then
    printf '%s\n' "$TITLE_R0" "$TITLE_R1" "$TITLE_R2" "$TITLE_R3" "$TITLE_R4" "$TITLE_R5" | \
      gum style --border rounded --foreground "$_gum_fg" --bold --padding "1 3"
  else
    printf '\n%b' "$TITLE_COLOR"
    for _tr in "$TITLE_R0" "$TITLE_R1" "$TITLE_R2" "$TITLE_R3" "$TITLE_R4" "$TITLE_R5"; do
      printf '    %s\n' "$_tr"
    done
    printf '%b\n' "${C_RESET}"
  fi

  _stat_item() {
    if [ "$HAS_GUM" = true ]; then printf '%s %s' "$(gum style --foreground 15 --bold "$1")" "$2"
    else printf '%b %s %b %s' "${C_BOLD_WHITE}" "$1" "${C_RESET}" "$2"; fi
  }

  gum_divider "$HR_THICK"
  printf '  %s  %b·%b  %s  %b·%b  %s  %b·%b  %s\n' \
    "$(_stat_item PROJECT "$PROJECT_NAME")" "${C_DIM}" "${C_RESET}" \
    "$(_stat_item SESSION "$SESSION_NAME")" "${C_DIM}" "${C_RESET}" \
    "$(_stat_item UPTIME "$UPTIME_STR")" "${C_DIM}" "${C_RESET}" \
    "$(_stat_item TEAMS "$TEAM_COUNT")"
  gum_divider "$HR_THICK"

  # Tunnels — multi-port aware. Order of preference:
  #   1. TUNNEL_PORTS_LIST present → header + one row per detected dev server
  #   2. TUNNEL_URL present        → legacy single-URL render (cloudflared etc.)
  #   3. TUNNEL_ERROR              → error indicator
  #   4. tunnel.env exists         → empty state ("watcher active, no servers")
  #   5. SSH session w/ no tunnel  → bare [REMOTE] marker
  if [ -n "$_tunnel_ports_list" ]; then
    # Multi-port header
    printf '  %b TUNNELS%b' "${C_BOLD_GREEN}" "${C_RESET}"
    [ -n "$_tunnel_hostname" ] && printf '  %s' "$_tunnel_hostname"
    [ -n "$_tunnel_provider" ] && printf '  %b(%s)%b' "${C_DIM}" "$_tunnel_provider" "${C_RESET}"
    [ "$_is_remote" = "true" ] && printf '  %b[REMOTE]%b' "${C_BOLD_CYAN}" "${C_RESET}"
    printf '\n'
    # One row per "port:proc" pair, comma-separated
    _tp_old_ifs="$IFS"
    IFS=','
    for _tp_entry in $_tunnel_ports_list; do
      _tp_port="${_tp_entry%%:*}"
      _tp_proc="${_tp_entry#*:}"
      [ "$_tp_proc" = "$_tp_entry" ] && _tp_proc="?"
      [ -n "$_tp_port" ] || continue
      if [ -n "$_tunnel_hostname" ]; then
        _tp_url="http://${_tunnel_hostname}:${_tp_port}"
      else
        _tp_url="localhost:${_tp_port}"
      fi
      printf '    %b→%b %s  %b(%s)%b\n' "${C_DIM}" "${C_RESET}" "$_tp_url" "${C_DIM}" "$_tp_proc" "${C_RESET}"
    done
    IFS="$_tp_old_ifs"
  elif [ -n "$_tunnel_url" ]; then
    # Legacy single-URL render — preserved verbatim for non-watcher modes
    printf '  %b TUNNEL%b  %s' "${C_BOLD_GREEN}" "${C_RESET}" "$_tunnel_url"
    [ -n "$_tunnel_provider" ] && printf '  %b(%s)%b' "${C_DIM}" "$_tunnel_provider" "${C_RESET}"
    [ "$_is_remote" = "true" ] && printf '  %b[REMOTE]%b' "${C_BOLD_CYAN}" "${C_RESET}"
    printf '\n'
  elif [ -n "$_tunnel_error" ]; then
    printf '  %b TUNNEL%b  %b%s%b\n' "${C_BOLD_YELLOW}" "${C_RESET}" "${C_DIM}" "$_tunnel_error" "${C_RESET}"
  elif [ -f "${RUNTIME_DIR}/tunnel.env" ]; then
    # Watcher active but no dev servers detected yet — keep section visible
    printf '  %b TUNNELS%b  %b(no dev servers detected)%b' "${C_BOLD_GREEN}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    [ "$_is_remote" = "true" ] && printf '  %b[REMOTE]%b' "${C_BOLD_CYAN}" "${C_RESET}"
    printf '\n'
  elif [ "$_is_remote" = "true" ]; then
    printf '  %b[REMOTE]%b\n' "${C_BOLD_CYAN}" "${C_RESET}"
  fi

  printf '\n'

  # ── Tasks (single-pass: header printed on first visible task) ──
  # Prefer persistent .doey/tasks/ (survives reboots), fall back to runtime
  _tasks_dir="${RUNTIME_DIR}/tasks"
  if [ -n "$_CACHED_PROJECT_DIR" ] && [ -d "${_CACHED_PROJECT_DIR}/.doey/tasks" ]; then
    _tasks_dir="${_CACHED_PROJECT_DIR}/.doey/tasks"
  fi

  # DB-first path: try doey-ctl task list
  _db_tasks_done=false
  if [ -n "$_CACHED_PROJECT_DIR" ] && _db_task_out=$(doey-ctl task list --project-dir "$_CACHED_PROJECT_DIR" 2>/dev/null) && [ -n "$_db_task_out" ]; then
    _has_render=false
    [ -x "${SCRIPT_DIR}/doey-render-task.sh" ] && _has_render=true
    _task_header_printed=false
    while IFS= read -r _dbline; do
      case "$_dbline" in ID*|"") continue ;; esac
      _tid=$(echo "$_dbline" | awk '{print $1}')
      _tstatus=$(echo "$_dbline" | awk '{print $2}')
      _tteam=$(echo "$_dbline" | awk '{print $3}')
      _ttitle=$(echo "$_dbline" | awk '{for(i=4;i<=NF;i++){if(i>4)printf " ";printf "%s",$i}print ""}')
      [ -n "${_tid:-}" ] || continue
      [ "$_tstatus" = "done" ] && continue
      [ "$_tstatus" = "cancelled" ] && continue

      if [ "$_task_header_printed" = false ]; then
        gum_header 'TASKS'; printf '\n\n'
        _task_header_printed=true
      fi
      case "$_tstatus" in
        active|in_progress)        _tcol="${C_YELLOW}"; _ticon="●" ;;
        pending_user_confirmation) _tcol="${C_CYAN}";   _ticon="⬤" ;;
        *)                         _tcol="${C_DIM}";    _ticon="○" ;;
      esac
      _tmeta=""
      [ -n "$_tteam" ] && _tmeta="${_tmeta} [${_tteam}]"
      printf '  %b%s%b %b#%s%b  %s  %b%s%b\n' \
        "$_tcol" "$_ticon" "${C_RESET}" \
        "${C_BOLD_WHITE}" "$_tid" "${C_RESET}" \
        "$_ttitle" \
        "${C_DIM}" "$_tmeta" "${C_RESET}"
      if [ "$_has_render" = true ]; then
        _tjson="${_tasks_dir}/${_tid}.json"
        _tf="${_tasks_dir}/${_tid}.task"
        if [ -f "$_tjson" ]; then
          _trendered=""
          _trendered=$(DOEY_VISUALIZATION_DENSITY=compact DOEY_ASCII_ONLY="${DOEY_ASCII_ONLY:-}" "${SCRIPT_DIR}/doey-render-task.sh" "$_tf" "$_tjson" 2>/dev/null) || _trendered=""
          if [ -n "$_trendered" ]; then
            while IFS= read -r _trline; do
              printf '  %s\n' "$_trline"
            done <<< "$_trendered"
          fi
          _tintent=""
          _tintent=$(python3 -c "import json; d=json.load(open('$_tjson')); print(d.get('intent','')[:60])" 2>/dev/null) || _tintent=""
          [ -n "$_tintent" ] && printf '    %b→%b %s\n' "${C_DIM}" "${C_RESET}" "$_tintent"
        fi
      fi
    done <<< "$_db_task_out"
    [ "$_task_header_printed" = true ] && printf '\n'
    _db_tasks_done=true
  fi

  # File-scan fallback
  if [ "$_db_tasks_done" = false ] && [ -d "$_tasks_dir" ]; then
    _has_render=false
    [ -x "${SCRIPT_DIR}/doey-render-task.sh" ] && _has_render=true
    _task_header_printed=false
    for _tf in "${_tasks_dir}"/*.task; do
      [ -f "$_tf" ] || continue
      [ -s "$_tf" ] || continue  # skip empty files
      _tid=""; _ttitle=""; _tstatus=""; _tcreated=""; _tmerged=""; _tteam=""; _tpri=""; _tsn=""
      while IFS= read -r _tl; do
        case "${_tl%%=*}" in
          TASK_ID)          _tid="${_tl#*=}" ;;
          TASK_TITLE)       _ttitle="${_tl#*=}" ;;
          TASK_STATUS)      _tstatus="${_tl#*=}" ;;
          TASK_CREATED)     _tcreated="${_tl#*=}" ;;
          TASK_MERGED_INTO) _tmerged="${_tl#*=}" ;;
          TASK_TEAM)        _tteam="${_tl#*=}" ;;
          TASK_PRIORITY)    _tpri="${_tl#*=}" ;;
          TASK_SHORTNAME)   _tsn="${_tl#*=}" ;;
        esac
      done < "$_tf" || true
      [ -n "${_tid:-}" ] || continue  # skip files missing TASK_ID
      [ -n "$_tmerged" ] && continue
      [ "$_tstatus" = "done" ] && continue
      [ "$_tstatus" = "cancelled" ] && continue

      if [ "$_task_header_printed" = false ]; then
        gum_header 'TASKS'; printf '\n\n'
        _task_header_printed=true
      fi

      _tage=""
      if [ -n "$_tcreated" ]; then
        _tage=$(format_uptime $((NOW - _tcreated)))
      fi
      case "$_tstatus" in
        active|in_progress)        _tcol="${C_YELLOW}"; _ticon="●" ;;
        pending_user_confirmation) _tcol="${C_CYAN}";   _ticon="⬤" ;;
        *)                         _tcol="${C_DIM}";    _ticon="○" ;;
      esac
      _tmeta=""
      [ -n "$_tpri" ] && _tmeta="${_tmeta} [${_tpri}]"
      [ -n "$_tteam" ] && _tmeta="${_tmeta} [${_tteam}]"
      printf '  %b%s%b %b#%s%b  %s  %b%s%s%b\n' \
        "$_tcol" "$_ticon" "${C_RESET}" \
        "${C_BOLD_WHITE}" "$_tid" "${C_RESET}" \
        "$_ttitle" \
        "${C_DIM}" "${_tage:+${_tage} ago}" "$_tmeta" "${C_RESET}"
      if [ "$_has_render" = true ]; then
        _tjson="${_tf%.task}.json"
        if [ -f "$_tjson" ]; then
          _trendered=""
          _trendered=$(DOEY_VISUALIZATION_DENSITY=compact DOEY_ASCII_ONLY="${DOEY_ASCII_ONLY:-}" "${SCRIPT_DIR}/doey-render-task.sh" "$_tf" "$_tjson" 2>/dev/null) || _trendered=""
          if [ -n "$_trendered" ]; then
            while IFS= read -r _trline; do
              printf '  %s\n' "$_trline"
            done <<< "$_trendered"
          fi
          _tintent=""
          _tintent=$(python3 -c "import json; d=json.load(open('$_tjson')); print(d.get('intent','')[:60])" 2>/dev/null) || _tintent=""
          [ -n "$_tintent" ] && printf '    %b→%b %s\n' "${C_DIM}" "${C_RESET}" "$_tintent"
        fi
      fi
    done
    [ "$_task_header_printed" = true ] && printf '\n'
  fi

  if [ "$TEAM_LINE_COUNT" -gt 0 ]; then
    gum_header 'TEAM STATUS'
    printf '\n\n'
    _ti=0
    while [ "$_ti" -lt "$TEAM_LINE_COUNT" ]; do
      _ref="TEAM_WIN_${_ti}"; _tw="${!_ref}"
      _ref="TEAM_WCNT_${_ti}"; _twc="${!_ref}"
      _ref="TEAM_BUSY_${_ti}"; _tb="${!_ref}"
      _ref="TEAM_IDLE_${_ti}"; _tidle="${!_ref}"
      _ref="TEAM_RESV_${_ti}"; _tr="${!_ref}"
      _ref="TEAM_WT_DIR_${_ti}"; _twtd="${!_ref:-}"
      _ref="TEAM_WT_BRANCH_${_ti}"; _twtb="${!_ref:-}"
      _ref="TEAM_TYPE_${_ti}"; _ttype="${!_ref:-}"
      _ref="TEAM_NAME_V_${_ti}"; _tnm="${!_ref:-}"

      if [ "$_ttype" = "freelancer" ]; then
        _tname="$(printf '  %b%s%b %b[F]%b ' "${C_BOLD_WHITE}" "${_tnm:-Freelancers}" "${C_RESET}" "${C_BOLD_YELLOW}" "${C_RESET}")"
      elif [ -n "$_twtd" ]; then
        _tname="$(printf '  Team %s %b[wt]%b' "$_tw" "${C_BOLD_CYAN}" "${C_RESET}")"
      else
        _tname="$(printf '  Team %s     ' "$_tw")"
      fi

      _tsummary="$(printf '%sW (%b%s busy%b, %b%s idle%b' "$_twc" "${C_YELLOW}" "$_tb" "${C_RESET}" "${C_GREEN}" "$_tidle" "${C_RESET}")"
      [ "$_tr" -gt 0 ] && _tsummary="${_tsummary}$(printf ', %b%s rsv%b)' "${C_MAGENTA}" "$_tr" "${C_RESET}")" || _tsummary="${_tsummary})"

      printf '  %-20s %s' "$_tname" "$_tsummary"
      [ -n "$_twtb" ] && printf '  %b%s%b' "${C_DIM}" "$_twtb" "${C_RESET}"
      printf '\n'

      _ti=$((_ti + 1))
    done
    printf '\n'
  fi

  # ── Recent Activity (from worker JSONL event logs) ──
  if [ -d "${RUNTIME_DIR}/activity" ]; then
    _act_raw=$(awk '{
      ts=$0; sub(/.*"ts" *: */, "", ts); sub(/[^0-9].*/, "", ts)
      pn=$0; sub(/.*"pane" *: *"/, "", pn); sub(/".*/, "", pn)
      ev=$0; sub(/.*"event" *: *"/, "", ev); sub(/".*/, "", ev)
      dt=""
      s=$0; if (sub(/.*"detail" *: *"/, "", s)) { sub(/".*/, "", s); dt=s }
      if (dt == "") { s=$0; if (sub(/.*"status" *: *"/, "", s)) { sub(/".*/, "", s); dt=s } }
      if (length(dt) > 30) dt = substr(dt, 1, 27) "..."
      if (ts+0 > 0) print ts "\t" pn "\t" ev "\t" dt
    }' "${RUNTIME_DIR}"/activity/*.jsonl 2>/dev/null | sort -t$'\t' -k1 -rn | head -12)

    if [ -n "$_act_raw" ]; then
      gum_header 'RECENT ACTIVITY'; printf '\n\n'

      while IFS=$'\t' read -r _ats _apane _aevt _adetail; do
        # Cross-platform timestamp: GNU date -d, then BSD date -r
        _atime=$(date -d "@${_ats}" '+%H:%M:%S' 2>/dev/null) || \
          _atime=$(date -r "${_ats}" '+%H:%M:%S' 2>/dev/null) || \
          _atime="??:??:??"

        case "$_aevt" in
          status_change|busy|working)   _aecol="${C_YELLOW}" ;;
          finished|done|complete*)      _aecol="${C_GREEN}" ;;
          error|crash|fail*)            _aecol="${C_BOLD_RED}" ;;
          dispatch*|task_start)         _aecol="${C_CYAN}" ;;
          *)                            _aecol="${C_DIM}" ;;
        esac

        _adtxt=""
        [ -n "${_adetail:-}" ] && _adtxt="  ${_adetail}"
        printf '    %b%s%b  %b%-7s%b  %b%-18s%b%b%s%b\n' \
          "${C_DIM}" "$_atime" "${C_RESET}" \
          "${C_BOLD_WHITE}" "$_apane" "${C_RESET}" \
          "$_aecol" "$_aevt" "${C_RESET}" \
          "${C_DIM}" "$_adtxt" "${C_RESET}"
      done <<< "$_act_raw"
      printf '\n'
    fi
  fi

  row=0
  while [ "$row" -lt "$LC" ]; do
    _ref="L_${row}"; left_line="${!_ref}"
    printf '%b\n' "$left_line"
    row=$((row + 1))
  done

  sleep "$DOEY_INFO_PANEL_REFRESH"
done
