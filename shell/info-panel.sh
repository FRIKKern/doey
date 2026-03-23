#!/bin/bash
# Doey Info Panel — dashboard for window 0, refreshes every 5 minutes.
set -uo pipefail

RUNTIME_DIR="${1:-${DOEY_RUNTIME:-}}"
if [ -z "$RUNTIME_DIR" ]; then
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
fi
if [ -z "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ]; then
  printf "Doey Info Panel: waiting for runtime directory...\n"
  while true; do
    sleep 5
    RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
    [ -n "$RUNTIME_DIR" ] && [ -d "$RUNTIME_DIR" ] && break
  done
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"

# Load config for customizable values
_cfg="${HOME}/.config/doey/config.sh"
# shellcheck source=/dev/null
[ -f "$_cfg" ] && source "$_cfg"
# Project config overlay
if [ -n "$RUNTIME_DIR" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
  _proj_dir=$(grep '^PROJECT_DIR=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
  [ -n "$_proj_dir" ] && [ -f "${_proj_dir}/.doey/config.sh" ] && source "${_proj_dir}/.doey/config.sh"
fi
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
    printf 'Doey Info Panel: waiting for session.env...\n'
    sleep 5
    continue
  fi

  TERM_W=$(tput cols 2>/dev/null || echo 120)
  [ "$TERM_W" -lt 80 ] && TERM_W=80
  LEFT_W=$((TERM_W * 55 / 100))

  if [ -z "$_CACHED_SESSION_NAME" ]; then
    read_env_file "$SESSION_ENV" SESSION_NAME PROJECT_NAME PROJECT_DIR TEAM_WINDOWS
    _CACHED_SESSION_NAME="$_ENV_SESSION_NAME"
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

  [ -z "$TEAM_WINDOWS" ] && TEAM_WINDOWS="0"

  for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
    TEAM_COUNT=$((TEAM_COUNT + 1))

    if [ "$W" = "0" ] && [ ! -f "${RUNTIME_DIR}/team_0.env" ]; then
      TEAM_FILE="$SESSION_ENV"
    else
      TEAM_FILE="${RUNTIME_DIR}/team_${W}.env"
    fi

    read_env_file "$TEAM_FILE" WORKER_PANES WORKER_COUNT WORKTREE_DIR WORKTREE_BRANCH
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
    TEAM_LINE_COUNT=$((TEAM_LINE_COUNT + 1))
  done

  LC=0
  add_left ""
  add_left "$(printf '%b  HOW TO USE DOEY%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_left ""
  add_left "$(printf '%b  1.%b Talk to the %bSession Manager%b (right pane' "${C_BOLD_WHITE}" "${C_RESET}" "${C_CYAN}" "${C_RESET}")"
  add_left "$(printf '     in this window) %b—%b describe your task and' "${C_DIM}" "${C_RESET}")"
  add_left "     it routes work to the right team."
  add_left ""
  add_left "$(printf '%b  2.%b Switch to a team window (%bCtrl-b 1%b) and' "${C_BOLD_WHITE}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}")"
  add_left "     talk to the Window Manager directly."
  add_left ""
  add_left "$(printf '%b  3.%b Click any worker pane and run %b/doey-reserve%b' "${C_BOLD_WHITE}" "${C_RESET}" "${C_GREEN}" "${C_RESET}")"
  add_left "     to claim it for yourself."
  add_left ""
  add_left ""
  add_left "$(printf '%b  SLASH COMMANDS%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_left ""

  CMD_W=$((LEFT_W - 4))
  COL_W=$((CMD_W / 2 - 1))

  add_left "$(printf '  %b Tasks%b' "${C_BOLD_GREEN}" "${C_RESET}")"
  add_cmd_pair "${C_GREEN}" "/doey-dispatch" "Send tasks" "${C_GREEN}" "/doey-delegate" "Delegate task"
  add_cmd_pair "${C_GREEN}" "/doey-broadcast" "Broadcast" "${C_GREEN}" "/doey-research" "Research task"
  add_cmd_pair "${C_GREEN}" "/doey-reserve" "Reserve pane"
  add_left ""
  add_left "$(printf '  %b Monitoring%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_cmd_pair "${C_CYAN}" "/doey-status" "Pane status" "${C_CYAN}" "/doey-monitor" "Monitor workers"
  add_cmd_pair "${C_CYAN}" "/doey-list-windows" "List teams"
  add_left ""
  add_left "$(printf '  %b Team Management%b' "${C_BOLD_YELLOW}" "${C_RESET}")"
  add_cmd_pair "${C_YELLOW}" "/doey-add-window" "Add team" "${C_YELLOW}" "/doey-kill-window" "Kill team"
  add_cmd_pair "${C_YELLOW}" "/doey-worktree" "Git worktree" "${C_YELLOW}" "/doey-clear" "Relaunch"
  add_cmd_pair "${C_YELLOW}" "/doey-reload" "Hot-reload"
  add_left ""
  add_left "$(printf '  %b Maintenance%b' "${C_BOLD_MAGENTA}" "${C_RESET}")"
  add_cmd_pair "${C_MAGENTA}" "/doey-stop" "Stop worker" "${C_MAGENTA}" "/doey-purge" "Audit/fix"
  add_cmd_pair "${C_MAGENTA}" "/doey-simplify-everything" "Simplify" "${C_MAGENTA}" "/doey-repair" "Fix Dashboard"
  add_cmd_pair "${C_MAGENTA}" "/doey-watchdog-compact" "Compact" "${C_MAGENTA}" "/doey-reinstall" "Reinstall"
  add_cmd_pair "${C_MAGENTA}" "/doey-kill-session" "Kill session" "${C_MAGENTA}" "/doey-kill-all-sessions" "Kill all"
  add_left ""
  add_left "$(printf '%b  CLI COMMANDS%b' "${C_BOLD_CYAN}" "${C_RESET}")"
  add_left ""
  add_cmd "${C_YELLOW}" "doey"         "Launch (dynamic grid)"
  add_cmd "${C_YELLOW}" "doey add"     "Add worker column"
  add_cmd "${C_YELLOW}" "doey stop"    "Stop session"
  add_cmd "${C_YELLOW}" "doey reload"  "Hot-reload (--workers)"
  add_cmd "${C_YELLOW}" "doey list"    "List all projects"
  add_cmd "${C_YELLOW}" "doey doctor"  "Check installation"
  add_cmd "${C_YELLOW}" "doey test"    "Run E2E tests"
  add_cmd "${C_YELLOW}" "doey version" "Show version info"

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
    0) TITLE_COLOR="${C_BOLD_CYAN}" ;;
    1) TITLE_COLOR="${C_BOLD_GREEN}" ;;
    2) TITLE_COLOR="${C_BOLD_YELLOW}" ;;
    3) TITLE_COLOR="${C_BOLD_MAGENTA}" ;;
    4) TITLE_COLOR="${C_BOLD_RED}" ;;
    5) TITLE_COLOR="${C_BOLD_WHITE}" ;;
  esac

  printf '\n%b' "$TITLE_COLOR"
  for _tr in "$TITLE_R0" "$TITLE_R1" "$TITLE_R2" "$TITLE_R3" "$TITLE_R4" "$TITLE_R5"; do
    printf '    %s\n' "$_tr"
  done
  printf '%b\n' "${C_RESET}"

  printf '%b%s%b\n' "${C_DIM}" "$HR_THICK" "${C_RESET}"
  stat_project="$(printf '%b PROJECT %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$PROJECT_NAME")"
  stat_session="$(printf '%b SESSION %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$SESSION_NAME")"
  stat_uptime="$(printf '%b UPTIME %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$UPTIME_STR")"
  stat_teams="$(printf '%b TEAMS %b %s' "${C_BOLD_WHITE}" "${C_RESET}" "$TEAM_COUNT")"

  printf '  %b  %b·%b  %b  %b·%b  %b  %b·%b  %b\n' \
    "$stat_project" "${C_DIM}" "${C_RESET}" \
    "$stat_session" "${C_DIM}" "${C_RESET}" \
    "$stat_uptime" "${C_DIM}" "${C_RESET}" \
    "$stat_teams"

  printf '%b%s%b\n' "${C_DIM}" "$HR_THICK" "${C_RESET}"
  printf '\n'

  if [ "$TEAM_LINE_COUNT" -gt 0 ]; then
    printf '  %b TEAM STATUS%b\n\n' "${C_BOLD_CYAN}" "${C_RESET}"
    _ti=0
    while [ "$_ti" -lt "$TEAM_LINE_COUNT" ]; do
      _ref="TEAM_WIN_${_ti}"; _tw="${!_ref}"
      _ref="TEAM_WCNT_${_ti}"; _twc="${!_ref}"
      _ref="TEAM_BUSY_${_ti}"; _tb="${!_ref}"
      _ref="TEAM_IDLE_${_ti}"; _tidle="${!_ref}"
      _ref="TEAM_RESV_${_ti}"; _tr="${!_ref}"
      _ref="TEAM_WT_DIR_${_ti}"; _twtd="${!_ref:-}"
      _ref="TEAM_WT_BRANCH_${_ti}"; _twtb="${!_ref:-}"

      if [ -n "$_twtd" ]; then
        _tname="$(printf '  Team %s %b[wt]%b' "$_tw" "${C_BOLD_CYAN}" "${C_RESET}")"
      else
        _tname="$(printf '  Team %s     ' "$_tw")"
      fi

      _tsummary="$(printf '%sW (%b%s busy%b, %b%s idle%b' "$_twc" "${C_YELLOW}" "$_tb" "${C_RESET}" "${C_GREEN}" "$_tidle" "${C_RESET}")"
      if [ "$_tr" -gt 0 ]; then
        _tsummary="${_tsummary}$(printf ', %b%s rsv%b)' "${C_MAGENTA}" "$_tr" "${C_RESET}")"
      else
        _tsummary="${_tsummary})"
      fi

      if [ -n "$_twtb" ]; then
        printf '%b  %-20s %s  %b%s%b\n' "${C_RESET}" "$_tname" "$_tsummary" "${C_DIM}" "$_twtb" "${C_RESET}"
      else
        printf '%b  %s %s\n' "${C_RESET}" "$_tname" "$_tsummary"
      fi

      _ti=$((_ti + 1))
    done
    printf '\n'
  fi

  row=0
  while [ "$row" -lt "$LC" ]; do
    _ref="L_${row}"; left_line="${!_ref}"
    printf '%b\n' "$left_line"
    row=$((row + 1))
  done

  sleep "$DOEY_INFO_PANEL_REFRESH"
done
