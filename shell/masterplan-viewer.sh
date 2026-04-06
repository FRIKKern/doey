#!/usr/bin/env bash
# Masterplan Viewer — live markdown plan renderer for tmux panes.
# Usage: masterplan-viewer.sh /path/to/plan.md
set -euo pipefail

# --- ANSI Colors ---
C_RESET='\033[0m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_BOLD_CYAN='\033[1;36m'
C_BOLD_WHITE='\033[1;97m'
C_BOLD_GREEN='\033[1;32m'
C_BOLD_YELLOW='\033[1;33m'

# --- Arguments ---
PLAN_FILE="${1:-}"
if [ -z "$PLAN_FILE" ]; then
  printf '%bUsage:%b masterplan-viewer.sh /path/to/plan.md\n' "$C_BOLD_WHITE" "$C_RESET"
  exit 1
fi

# --- Renderer detection ---
RENDERER="cat"
if command -v glow >/dev/null 2>&1; then
  RENDERER="glow"
elif command -v bat >/dev/null 2>&1; then
  RENDERER="bat"
fi

# --- Helpers ---

# Get file mtime portably (macOS stat vs Linux stat)
get_mtime() {
  local f="$1"
  if stat -f '%m' "$f" >/dev/null 2>&1; then
    stat -f '%m' "$f"
  else
    stat -c '%Y' "$f" 2>/dev/null || echo "0"
  fi
}

# Extract first heading from markdown file
extract_title() {
  local f="$1" line=""
  while IFS= read -r line; do
    case "$line" in
      '#'*) line="${line#\#}"; line="${line#\#}"; line="${line#\#}"
            line="${line# }"; printf '%s' "$line"; return ;;
    esac
  done < "$f"
  printf 'Untitled Plan'
}

# Format epoch to human-readable time
format_time() {
  date -d "@$1" '+%H:%M:%S' 2>/dev/null || date -r "$1" '+%H:%M:%S' 2>/dev/null || echo "unknown"
}

# Render plan content using best available tool
render_content() {
  local f="$1" tw="$2"
  case "$RENDERER" in
    glow)
      glow -w "$tw" "$f" 2>/dev/null || cat "$f"
      ;;
    bat)
      bat --style=plain --color=always --language=md --terminal-width="$tw" "$f" 2>/dev/null || cat "$f"
      ;;
    cat)
      # Simple ANSI coloring for headers
      while IFS= read -r line; do
        case "$line" in
          '###'*) printf '%b%s%b\n' "$C_CYAN" "$line" "$C_RESET" ;;
          '##'*)  printf '%b%s%b\n' "$C_BOLD_CYAN" "$line" "$C_RESET" ;;
          '#'*)   printf '%b%s%b\n' "$C_BOLD_WHITE" "$line" "$C_RESET" ;;
          '---')  printf '%b%s%b\n' "$C_DIM" "$line" "$C_RESET" ;;
          *)      printf '%s\n' "$line" ;;
        esac
      done < "$f"
      ;;
  esac
}

# Spinner characters (Bash 3.2 safe — no arrays needed)
SPINNER_CHARS='|/-\'

# --- State ---
LAST_MTIME="0"
LAST_RENDER_TIME=0
SPINNER_IDX=0

# --- Main loop ---
while true; do
  TERM_W=$(tput cols 2>/dev/null || echo 80)
  TERM_H=$(tput lines 2>/dev/null || echo 24)

  if [ ! -f "$PLAN_FILE" ]; then
    # File doesn't exist yet — show waiting spinner
    printf '\033[2J\033[H'
    SPINNER_IDX=$(( (SPINNER_IDX + 1) % 4 ))
    SC=$(printf '%s' "$SPINNER_CHARS" | cut -c$((SPINNER_IDX + 1)))
    printf '\n'
    printf '  %b%s  Waiting for plan...%b\n' "$C_DIM" "$SC" "$C_RESET"
    printf '  %b%s%b\n' "$C_DIM" "$PLAN_FILE" "$C_RESET"
    sleep 1
    continue
  fi

  # Check mtime for changes
  CUR_MTIME=$(get_mtime "$PLAN_FILE")
  NOW=$(date +%s)

  if [ "$CUR_MTIME" != "$LAST_MTIME" ]; then
    # Debounce: skip if less than 0.5s since last render (use integer check)
    ELAPSED=$((NOW - LAST_RENDER_TIME))
    if [ "$ELAPSED" -lt 1 ] && [ "$LAST_RENDER_TIME" -gt 0 ]; then
      sleep 1
      continue
    fi

    # Clear screen and render
    printf '\033[2J\033[H'

    # --- Header bar ---
    TITLE=$(extract_title "$PLAN_FILE")
    UPDATED=$(format_time "$CUR_MTIME")
    HEADER_LINE=" $TITLE"
    TIME_STR="Updated: $UPDATED "
    PAD_LEN=$((TERM_W - ${#HEADER_LINE} - ${#TIME_STR}))
    PAD=""
    if [ "$PAD_LEN" -gt 0 ]; then
      PAD=$(printf '%*s' "$PAD_LEN" '')
    fi

    printf '%b%s%s%b%s%b\n' \
      "$C_BOLD_WHITE" "$HEADER_LINE" "$PAD" \
      "$C_DIM" "$TIME_STR" "$C_RESET"

    # Divider
    DIV=""
    i=0
    while [ "$i" -lt "$TERM_W" ]; do
      DIV="${DIV}─"
      i=$((i + 1))
    done
    printf '%b%s%b\n' "$C_DIM" "$DIV" "$C_RESET"

    # --- Plan content ---
    CONTENT_W=$((TERM_W - 2))
    if [ "$CONTENT_W" -lt 40 ]; then
      CONTENT_W=40
    fi
    render_content "$PLAN_FILE" "$CONTENT_W"

    LAST_MTIME="$CUR_MTIME"
    LAST_RENDER_TIME="$NOW"
  fi

  sleep 2
done
