#!/usr/bin/env bash
# Doey Plan Viewer — live-rendering plan file watcher.
# Usage: plan-viewer.sh <plan-file-path> [refresh-interval-seconds]
set -euo pipefail

# ── Arguments ──
PLAN_FILE="${1:-}"
REFRESH="${2:-1}"

if [ -z "$PLAN_FILE" ]; then
  printf 'Usage: plan-viewer.sh <plan-file-path> [refresh-interval-seconds]\n' >&2
  exit 1
fi

# ── Colors ──
C_RESET='\033[0m'
C_DIM='\033[2m'
C_BOLD='\033[1m'
C_CYAN='\033[36m'
C_BOLD_CYAN='\033[1;36m'
C_YELLOW='\033[33m'
C_GREEN='\033[32m'

# ── Renderer detection ──
RENDERER="cat"
if command -v glow >/dev/null 2>&1; then
  RENDERER="glow"
elif command -v bat >/dev/null 2>&1; then
  RENDERER="bat"
elif command -v mdcat >/dev/null 2>&1; then
  RENDERER="mdcat"
fi

# ── State ──
LAST_MTIME=""
NEEDS_REDRAW=true

# ── Helpers ──

# Get file modification time (macOS stat)
get_mtime() {
  local f="$1"
  if [ -f "$f" ]; then
    stat -f '%m' "$f" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Format a unix timestamp for display
format_time() {
  local ts="$1"
  if [ -n "$ts" ]; then
    date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# Render the plan file with the best available renderer
render_plan() {
  local f="$1"
  case "$RENDERER" in
    glow)
      glow -s dark -w "$(tput cols 2>/dev/null || echo 80)" "$f" 2>/dev/null || cat "$f"
      ;;
    bat)
      bat --style=plain --color=always --language=markdown "$f" 2>/dev/null || cat "$f"
      ;;
    mdcat)
      mdcat "$f" 2>/dev/null || cat "$f"
      ;;
    *)
      # Basic formatting: bold headers, dim horizontal rules
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          '#'*)
            printf '%b%s%b\n' "${C_BOLD_CYAN}" "$line" "${C_RESET}"
            ;;
          '---'*|'***'*|'___'*)
            local w
            w=$(tput cols 2>/dev/null || echo 80)
            local ruler="" i=0
            while [ "$i" -lt "$w" ]; do ruler="${ruler}─"; i=$((i + 1)); done
            printf '%b%s%b\n' "${C_DIM}" "$ruler" "${C_RESET}"
            ;;
          '- [x]'*|'- [X]'*)
            printf '%b✓%b %s\n' "${C_GREEN}" "${C_RESET}" "${line#*] }"
            ;;
          '- [ ]'*)
            printf '%b○%b %s\n' "${C_YELLOW}" "${C_RESET}" "${line#*] }"
            ;;
          *)
            printf '%s\n' "$line"
            ;;
        esac
      done < "$f"
      ;;
  esac
}

# Full screen redraw
redraw() {
  local term_w
  term_w=$(tput cols 2>/dev/null || echo 80)

  # Clear screen, move to top
  printf '\033[2J\033[H'

  # ── Header ──
  printf '%b── Plan Viewer ──%b  %b%s%b\n' \
    "${C_BOLD_CYAN}" "${C_RESET}" \
    "${C_DIM}" "$PLAN_FILE" "${C_RESET}"

  local ruler="" i=0
  while [ "$i" -lt "$term_w" ]; do ruler="${ruler}─"; i=$((i + 1)); done
  printf '%b%s%b\n\n' "${C_DIM}" "$ruler" "${C_RESET}"

  # ── Body ──
  if [ ! -f "$PLAN_FILE" ]; then
    printf '%b  Waiting for plan file...%b\n' "${C_YELLOW}" "${C_RESET}"
    printf '%b  Expected: %s%b\n' "${C_DIM}" "$PLAN_FILE" "${C_RESET}"
  elif [ ! -s "$PLAN_FILE" ]; then
    printf '%b  Plan file is empty.%b\n' "${C_DIM}" "${C_RESET}"
  else
    render_plan "$PLAN_FILE"
  fi

  # ── Status line ──
  local mtime_display="never"
  if [ -n "$LAST_MTIME" ]; then
    mtime_display=$(format_time "$LAST_MTIME")
  fi

  # Move to bottom area with some spacing
  printf '\n'
  printf '%b%s%b\n' "${C_DIM}" "$ruler" "${C_RESET}"
  printf '%b[plan-viewer]%b Watching: %b%s%b | Last update: %b%s%b | Press Ctrl-C to exit\n' \
    "${C_BOLD}" "${C_RESET}" \
    "${C_CYAN}" "$PLAN_FILE" "${C_RESET}" \
    "${C_GREEN}" "$mtime_display" "${C_RESET}"

  NEEDS_REDRAW=false
}

# ── Signal handlers ──

cleanup() {
  printf '\033[?25h'  # Show cursor
  printf '\n%b[plan-viewer] Stopped.%b\n' "${C_DIM}" "${C_RESET}"
  exit 0
}

handle_winch() {
  NEEDS_REDRAW=true
}

trap cleanup SIGTERM SIGINT
trap handle_winch SIGWINCH

# ── Hide cursor during display ──
printf '\033[?25l'

# ── Main loop ──
while true; do
  current_mtime=$(get_mtime "$PLAN_FILE")

  # Redraw if file changed, first run, or terminal resized
  if [ "$NEEDS_REDRAW" = true ] || [ "$current_mtime" != "$LAST_MTIME" ]; then
    LAST_MTIME="$current_mtime"
    redraw
  fi

  sleep "$REFRESH"
done
