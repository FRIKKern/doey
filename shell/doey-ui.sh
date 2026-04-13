#!/usr/bin/env bash
# doey-ui.sh — Display/output functions shared across Doey scripts.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_ui_sourced:-}" = "1" ] && return 0
__doey_ui_sourced=1

# ── Color palette ─────────────────────────────────────────────────────
BRAND='\033[1;36m'    # Bold cyan
SUCCESS='\033[0;32m'  # Green
DIM='\033[0;90m'      # Gray
WARN='\033[0;33m'     # Yellow
ERROR='\033[0;31m'    # Red
BOLD='\033[1m'        # Bold
RESET='\033[0m'       # Reset

# Charmbracelet gum (optional — luxury CLI experience)
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

# ── Charmbracelet wrappers (gum with plain-text fallback) ────────────

doey_style() {
  # Usage: doey_style "text" [--foreground N] [--bold] [--border rounded] etc.
  if [ "$HAS_GUM" = true ]; then
    gum style "$@"
  else
    local text=""
    local arg
    for arg in "$@"; do
      case "$arg" in --*) ;; *) text="$arg"; break ;; esac
    done
    printf '%s\n' "$text"
  fi
}

doey_header() {
  # Styled section header — e.g., "Doey — System Check"
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 6 --bold --padding "0 1" --margin "1 0 0 0" "◆ $1"
  else
    printf "\n  ${BRAND}${BOLD}%s${RESET}\n" "$1"
  fi
}

doey_confirm() {
  # Usage: doey_confirm "Delete session?" — returns 0=yes, 1=no
  if [ "$HAS_GUM" = true ]; then
    gum confirm "$1"
  else
    printf "  %s [y/N] " "$1"
    read -r reply
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi
}

doey_confirm_default_yes() {
  # Same but default is Yes
  if [ "$HAS_GUM" = true ]; then
    gum confirm --default=yes "$1"
  else
    printf "  %s [Y/n] " "$1"
    read -r reply
    case "$reply" in [Nn]*) return 1 ;; *) return 0 ;; esac
  fi
}

doey_choose() {
  # Usage: selected=$(doey_choose "option1" "option2" "option3")
  if [ "$HAS_GUM" = true ]; then
    gum choose "$@"
  else
    local i=1
    local item
    for item in "$@"; do printf "  %d) %s\n" "$i" "$item"; i=$((i + 1)); done
    printf "  Choice: "
    read -r choice
    local j=1
    for item in "$@"; do
      if [ "$j" = "$choice" ]; then echo "$item"; return 0; fi
      j=$((j + 1))
    done
    return 1
  fi
}

doey_input() {
  # Usage: value=$(doey_input "Prompt text" "placeholder" "default")
  if [ "$HAS_GUM" = true ]; then
    gum input --prompt "$1: " --placeholder "${2:-}" --value "${3:-}"
  else
    printf "  %s" "$1: "
    if [ -n "${3:-}" ]; then printf "[%s] " "$3"; fi
    local value
    read -r value
    if [ -z "$value" ] && [ -n "${3:-}" ]; then value="$3"; fi
    echo "$value"
  fi
}

doey_spin() {
  # Usage: doey_spin "Installing..." command arg1 arg2
  local title="$1"; shift
  if [ "$HAS_GUM" = true ]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    printf "  %s" "$title"
    "$@" >/dev/null 2>&1
    printf " done\n"
  fi
}

doey_success() {
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 2 "✓ $1"
  else
    printf "  ${SUCCESS}✓ %s${RESET}\n" "$1"
  fi
}

doey_warn() {
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 3 "⚠ $1"
  else
    printf "  ${WARN}⚠ %s${RESET}\n" "$1"
  fi
}

doey_error() {
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 1 --bold "✗ $1"
  else
    printf "  ${ERROR}✗ %s${RESET}\n" "$1"
  fi
}

doey_info() {
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 8 "$1"
  else
    printf "  ${DIM}%s${RESET}\n" "$1"
  fi
}

doey_banner() {
  # Render the doey banner with luxury styling
  if [ "$HAS_GUM" = true ]; then
    cat << 'DOEY_ART' | gum style --foreground 6 --bold --border rounded --border-foreground 6 --padding "1 3" --margin "1 0"

            .
           ...      :-=++++==--:
               .-***=-:.   ..:=+#%*:
    .     :=----=.               .=%*=:
    ..   -=-                     .::. :#*:
      .+=    := .-+**+:        :#@%%@%- :*%=
      *+.    @.*@**@@@@#.      %@=  *@@= :*=
    :*:     .@=@=  *@@@@%      #@%+#@%#@  :-+
   .%++      #*@@#%@@#%@@      :@@@@@*+@  :%#
    %#       ==%@@@@@=+@+       :*%@@@#: :=*
   .@--     -+=.+%@@@@*:            :.:--:-.
   .@%#    ##*  ...:.:                 +=
    .-@- .#*.   . ..                   :%
      :+++%.:       .=.                 #+
          =**        .*=                :@.
       .   .@:+.       +#:               =%
            :*:+:--.   =+%*.              *+
                .- :-=:-+:+%=              #:
                           .*%-            .%.
                             :%#:        ...-#
                               =%*.   =#@%@@@@*
                                 =%+.-@@#=%@@@@-
                                   -#*@@@@@@@@@.
                                     .=#@@@@%+.

   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝

   Let me Doey for you
DOEY_ART
  else
    _print_full_banner
  fi
}

doey_splash() {
  _DOEY_SPLASH_START="$(date +%s)"
  printf '\033[2J\033[H'  # Clear screen, cursor top
  printf '\033[36m'       # Cyan
  cat << 'SPLASH'
   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
SPLASH
  printf '\033[0m'
  printf '\n   \033[2mStarting...\033[0m\n\n'
}

# Ensure the splash screen stays visible for at least 6 seconds
_splash_wait_minimum() {
  local min_seconds="${1:-6}"
  if [ -n "${_DOEY_SPLASH_START:-}" ]; then
    local now elapsed remaining
    now="$(date +%s)"
    elapsed=$(( now - _DOEY_SPLASH_START ))
    remaining=$(( min_seconds - elapsed ))
    if [ "$remaining" -gt 0 ]; then
      sleep "$remaining"
    fi
  fi
}

# ── Progress-file startup display ────────────────────────────────────
# Foreground: show startup progress from a file written by the background setup.
# Prefers doey-tui startup (rich TUI); falls back to simple terminal output.
_show_startup_progress() {
  local progress_file="$1"
  local timeout_sec="${2:-60}"
  if command -v doey-tui >/dev/null 2>&1; then
    # Probe /dev/tty before using it — containers and some SSH contexts
    # have the node but can't open it (ENXIO / "No such device or address")
    if (exec 3</dev/tty) 2>/dev/null && (exec 4>/dev/tty) 2>/dev/null; then
      if doey-tui startup --progress-file "$progress_file" --timeout "$timeout_sec" </dev/tty >/dev/tty 2>/dev/null; then
        return 0
      fi
    fi
  fi
  _startup_progress_fallback "$progress_file" "$timeout_sec"
}

_startup_progress_fallback() {
  local progress_file="$1"
  local timeout_sec="${2:-60}"
  local start_time last_step=""
  start_time="$(date +%s)"
  printf '\033[2J\033[H'
  printf '\033[36m'
  cat << 'SPLASH'
   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
SPLASH
  printf '\033[0m\n'
  while true; do
    if [ -f "$progress_file" ]; then
      local current
      current="$(tail -1 "$progress_file" 2>/dev/null)" || true
      if [ -n "$current" ] && [ "$current" != "$last_step" ]; then
        local msg="${current#STEP: }"
        if [ "$msg" = "Ready" ]; then
          printf "   \033[32m%s\033[0m\n" "$msg"
          return 0
        fi
        case "$msg" in
          ERROR*)
            printf "   \033[31m✗ %s\033[0m\n" "$msg"
            return 1
            ;;
        esac
        printf "   \033[2m%s\033[0m\n" "$msg"
        last_step="$current"
      fi
    fi
    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - start_time ))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      return 0
    fi
    sleep 0.3
  done
}

doey_divider() {
  local width="${1:-50}"
  local line; line="$(printf '%*s' "$width" '' | tr ' ' '─')"
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 240 --margin "0 1" "$line"
  else
    printf "  ${DIM}%s${RESET}\n" "$line"
  fi
}

doey_ok() {
  # Green text, no icon — for action results like "Registered", "Stopped"
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 2 "$1"
  else
    printf "  ${SUCCESS}%s${RESET}\n" "$1"
  fi
}

doey_step() {
  # Numbered step: doey_step "1/6" "Creating sandbox..."
  if [ "$HAS_GUM" = true ]; then
    printf "  %s %s\n" "$(gum style --foreground 8 "[$1]")" "$2"
  else
    printf "  ${DIM}[%s]${RESET} %s\n" "$1" "$2"
  fi
}

# ── Banner helpers ───────────────────────────────────────────────────

_print_doey_banner() {
  printf "${BRAND}"
  cat << 'BANNER'
   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
BANNER
  printf "${RESET}"
}

_print_full_banner() {
  local tagline="${1:-Let me Doey for you}"
  printf '\n'
  printf "${BRAND}"
  cat << 'DOG'
            .
           ...      :-=++++==--:
               .-***=-:.   ..:=+#%*:
    .     :=----=.               .=%*=:
    ..   -=-                     .::. :#*:
      .+=    := .-+**+:        :#@%%@%- :*%=
      *+.    @.*@**@@@@#.      %@=  *@@= :*=
    :*:     .@=@=  *@@@@%      #@%+#@%#@  :-+
   .%++      #*@@#%@@#%@@      :@@@@@*+@  :%#
    %#       ==%@@@@@=+@+       :*%@@@#: :=*
   .@--     -+=.+%@@@@*:            :.:--:-.
   .@%#    ##*  ...:.:                 +=
    .-@- .#*.   . ..                   :%
      :+++%.:       .=.                 #+
          =**        .*=                :@.
       .   .@:+.       +#:               =%
            :*:+:--.   =+%*.              *+
                .- :-=:-+:+%=              #:
                           .*%-            .%.
                             :%#:        ...-#
                               =%*.   =#@%@@@@*
                                 =%+.-@@#=%@@@@-
                                   -#*@@@@@@@@@.
                                     .=#@@@@%+.
DOG
  printf '\n'
  _print_doey_banner
  printf "   ${DIM}${tagline}${RESET}\n"
  printf '\n'
}
