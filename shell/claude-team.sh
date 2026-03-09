#!/usr/bin/env bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────
# claude-team — Project-aware TMUX Claude Team launcher
#
# Usage:
#   claude-team              # Smart launch (auto-attach or project picker)
#   claude-team init         # Register current directory as a project
#   claude-team list         # Show all registered projects + status
#   claude-team stop         # Stop session for current project
#   claude-team 4x3          # Launch/reattach with specific grid
#   claude-team --help       # Show usage
#
# Alias suggestion:
#   alias ct="claude-team"
# ──────────────────────────────────────────────────────────────────────

# ── Color palette ─────────────────────────────────────────────────────
BRAND='\033[1;36m'    # Bold cyan
SUCCESS='\033[0;32m'  # Green
INFO='\033[0;34m'     # Blue
DIM='\033[0;90m'      # Gray
WARN='\033[0;33m'     # Yellow
ERROR='\033[0;31m'    # Red
BOLD='\033[1m'        # Bold
RESET='\033[0m'       # Reset

# ── Project registry ─────────────────────────────────────────────────
PROJECTS_FILE="$HOME/.claude/claude-team/projects"
mkdir -p "$(dirname "$PROJECTS_FILE")"
touch "$PROJECTS_FILE"

# ── Helpers ───────────────────────────────────────────────────────────

# Derive a sanitized project name from a directory path
project_name_from_dir() {
  basename "$1" | tr '[:upper:] .' '[:lower:]--' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# Find the project name registered for a given directory (empty if none)
find_project() {
  local dir="$1"
  grep -m1 ":${dir}$" "$PROJECTS_FILE" 2>/dev/null | cut -d: -f1 || true
}

# Check if a tmux session exists
# NOTE: < /dev/null prevents tmux from consuming stdin, which breaks
# when this is called inside a `while read ... done < file` loop.
session_exists() {
  tmux has-session -t "$1" < /dev/null 2>/dev/null
}

# Register a directory as a project
register_project() {
  local dir="$1"
  local name
  name="$(project_name_from_dir "$dir")"

  # Already registered?
  if grep -q ":${dir}$" "$PROJECTS_FILE" 2>/dev/null; then
    printf "  ${SUCCESS}Already registered as '$(find_project "$dir")'${RESET}\n"
    return 0
  fi

  # Handle name collision
  if grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null; then
    local i=2
    while grep -q "^${name}-${i}:" "$PROJECTS_FILE" 2>/dev/null; do ((i++)); done
    name="${name}-${i}"
  fi

  echo "${name}:${dir}" >> "$PROJECTS_FILE"
  printf "  ${SUCCESS}Registered${RESET} ${BOLD}${name}${RESET} ${DIM}→${RESET} ${dir}\n"
}

# List all projects with running status
list_projects() {
  printf '\n'
  printf "  ${BRAND}Claude Code TMUX Team — Projects${RESET}\n"
  printf '\n'
  local has_projects=false
  while IFS=: read -r name path; do
    [[ -z "$name" ]] && continue
    has_projects=true
    local short_path="${path/#$HOME/\~}"
    if session_exists "ct-${name}"; then
      printf "  ${SUCCESS}●${RESET} ${BOLD}%-20s${RESET} %s\n" "$name" "$short_path"
    else
      printf "  ${DIM}○${RESET} %-20s ${DIM}%s${RESET}\n" "$name" "$short_path"
    fi
  done < "$PROJECTS_FILE"
  if [[ "$has_projects" == false ]]; then
    printf "  ${DIM}(no projects registered)${RESET}\n"
  fi
  printf '\n'
  printf "  ${SUCCESS}●${RESET} running  ${DIM}○${RESET} stopped\n"
  printf '\n'
}

# Stop session for current directory's project
stop_project() {
  local name
  name="$(find_project "$(pwd)")"
  if [[ -z "$name" ]]; then
    printf "  ${WARN}No project registered for $(pwd)${RESET}\n"
    return 1
  fi
  if tmux kill-session -t "ct-${name}" < /dev/null 2>/dev/null; then
    printf "  ${SUCCESS}Stopped${RESET} ct-${name}\n"
  else
    printf "  ${DIM}No active session for ${name}${RESET}\n"
  fi
}

# Show interactive project picker menu
show_menu() {
  local grid="${1:-6x2}"

  printf '\n'
  printf "  ${BRAND}Claude Code TMUX Team${RESET}\n"
  printf '\n'
  printf "  ${WARN}No project registered for $(pwd)${RESET}\n"
  printf '\n'

  # Read projects into arrays
  local -a names=() paths=() statuses=()
  while IFS=: read -r name path; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    paths+=("$path")
    if session_exists "ct-${name}"; then
      statuses+=("${SUCCESS}● running${RESET}")
    else
      statuses+=("${DIM}○ stopped${RESET}")
    fi
  done < "$PROJECTS_FILE"

  if [[ ${#names[@]} -gt 0 ]]; then
    printf "  ${BOLD}Known projects:${RESET}\n"
    for i in "${!names[@]}"; do
      local short_path="${paths[$i]/#$HOME/\~}"
      printf "    ${BOLD}%d)${RESET} %-20s ${DIM}%s${RESET}  %b\n" $((i+1)) "${names[$i]}" "${short_path}" "${statuses[$i]}"
    done
    printf '\n'
  fi

  printf "  ${DIM}Options:${RESET}\n"
  printf "    ${BOLD}#${RESET})  Enter number to open a project\n"
  printf "    ${BOLD}i${RESET})  Init current directory as new project\n"
  printf "    ${BOLD}q${RESET})  Quit\n"
  printf '\n'

  read -rp "  > " choice

  case "$choice" in
    [0-9]*)
      local idx=$((choice - 1))
      if [[ $idx -ge 0 && $idx -lt ${#names[@]} ]]; then
        local selected_name="${names[$idx]}"
        local selected_path="${paths[$idx]}"
        local selected_session="ct-${selected_name}"
        if session_exists "$selected_session"; then
          tmux attach -t "$selected_session"
        else
          launch_session "$selected_name" "$selected_path" "$grid"
        fi
      else
        printf "  ${ERROR}Invalid selection${RESET}\n"
        return 1
      fi
      ;;
    i|I|init)
      register_project "$(pwd)"
      printf "  Run ${BOLD}claude-team${RESET} again to launch.\n"
      ;;
    q|Q) return 0 ;;
    *)
      printf "  ${ERROR}Invalid option${RESET}\n"
      return 1
      ;;
  esac
}

# ── Step printer helpers ──────────────────────────────────────────────
STEP_TOTAL=6

step_start() {
  local n="$1"; local label="$2"
  printf "   ${DIM}[${n}/${STEP_TOTAL}]${RESET} %-40s" "$label"
}

step_done() {
  printf "${SUCCESS}done${RESET}\n"
}

step_fail() {
  printf "${ERROR}fail${RESET}\n"
}

# ── Launch Session ────────────────────────────────────────────────────
# The main tmux setup: premium banner, grid splits, theming, pane naming,
# manifest, manager/watchdog/worker launches, auto-briefing, summary box.

launch_session() {
  local name="$1"
  local dir="$2"
  local grid="${3:-6x2}"
  local cols="${grid%x*}"
  local rows="${grid#*x}"
  local total=$(( cols * rows ))
  local worker_count=$(( total - 2 ))
  local watchdog_pane=$cols
  local session="ct-${name}"
  local runtime_dir="/tmp/claude-team/${name}"
  local short_dir="${dir/#$HOME/~}"

  cd "$dir"

  # ── Banner ──────────────────────────────────────────────────────
  printf '\n'
  printf "${BRAND}"
  printf '    ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗\n'
  printf '   ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝\n'
  printf '   ██║     ██║     ███████║██║   ██║██║  ██║█████╗  \n'
  printf '   ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  \n'
  printf '   ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗\n'
  printf '    ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝╚══════╝\n'
  printf "${RESET}"
  printf "${DIM}                    T E A M${RESET}\n"
  printf '\n'
  printf "   ${DIM}Project${RESET} ${BOLD}${name}${RESET}  ${DIM}Grid${RESET} ${BOLD}${grid}${RESET}  ${DIM}Workers${RESET} ${BOLD}${worker_count}${RESET}\n"
  printf "   ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}  ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  # ── Build worker pane list (needed for manifest and briefings) ──
  local worker_panes_csv=""
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    [[ -n "$worker_panes_csv" ]] && worker_panes_csv+=","
    worker_panes_csv+="$i"
  done

  # ── Step 1: Create session ─────────────────────────────────────
  step_start 1 "Creating session for ${name}..."
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}

  # Write session manifest — readable by Manager, Watchdog, and all skills/commands
  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR=$dir
PROJECT_NAME=$name
SESSION_NAME=$session
GRID=$grid
TOTAL_PANES=$total
WORKER_COUNT=$worker_count
WATCHDOG_PANE=$watchdog_pane
WORKER_PANES=$worker_panes_csv
RUNTIME_DIR=${runtime_dir}
MANIFEST

  tmux new-session -d -s "$session" -c "$dir"
  tmux set-environment -t "$session" CLAUDE_TEAM_RUNTIME "${runtime_dir}"
  step_done

  # ── Step 2: Apply theme ────────────────────────────────────────
  step_start 2 "Applying theme..."

  # Pane borders — heavy lines with role-aware titles
  tmux set-option -t "$session" pane-border-status top
  tmux set-option -t "$session" pane-border-format \
    ' #{?pane_active,#[fg=cyan#,bold],#[fg=colour245]}#{pane_title} #[default]'
  tmux set-option -t "$session" pane-border-style 'fg=colour238'
  tmux set-option -t "$session" pane-active-border-style 'fg=cyan'
  tmux set-option -t "$session" pane-border-lines heavy

  # Status bar — dark bg, branded left segment
  tmux set-option -t "$session" status-position top
  tmux set-option -t "$session" status-style 'bg=colour233,fg=colour248'
  tmux set-option -t "$session" status-left-length 50
  tmux set-option -t "$session" status-right-length 70
  tmux set-option -t "$session" status-left \
    "#[fg=colour233,bg=cyan,bold]  CLAUDE TEAM: ${name} #[fg=cyan,bg=colour236,nobold] #S #[fg=colour236,bg=colour233] "
  tmux set-option -t "$session" status-right \
    "#[fg=colour245] #{pane_title} #[fg=colour233,bg=colour240]  %H:%M #[fg=colour233,bg=colour245,bold] ${worker_count} workers "
  tmux set-option -t "$session" status-interval 5

  # Window status styling
  tmux set-option -t "$session" window-status-format '#[fg=colour245] #I #W '
  tmux set-option -t "$session" window-status-current-format '#[fg=cyan,bold] #I #W '
  tmux set-option -t "$session" message-style 'bg=colour233,fg=cyan'

  # Terminal tab/window title — shows project name in macOS Terminal tabs
  tmux set-option -t "$session" set-titles on
  tmux set-option -t "$session" set-titles-string "🤖 #{session_name} — #{pane_title}"

  # Enable mouse for pane selection, scrolling, resizing
  tmux set-option -t "$session" -g mouse on

  step_done

  # ── Step 3: Build grid ─────────────────────────────────────────
  step_start 3 "Building ${cols}x${rows} grid (${total} panes)..."

  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "$session:0.0" -c "$dir"
  done
  tmux select-layout -t "$session" even-vertical

  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "$session:0.$((r * cols))" -c "$dir"
    done
  done

  sleep 2
  step_done

  # ── Step 4: Name panes ─────────────────────────────────────────
  step_start 4 "Naming panes..."

  tmux select-pane -t "$session:0.0" -T "MGR Manager"
  tmux select-pane -t "$session:0.$watchdog_pane" -T "WDG Watchdog"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    (( wnum++ ))
    tmux select-pane -t "$session:0.$i" -T "W${wnum} Worker ${wnum}"
  done

  step_done

  # ── Step 5: Launch Manager & Watchdog ──────────────────────────
  step_start 5 "Launching Manager & Watchdog..."

  # Launch Manager (pane 0.0)
  tmux send-keys -t "$session:0.0" \
    "claude --dangerously-skip-permissions --agent tmux-manager" Enter
  sleep 0.5

  # Auto-send initial briefing once Manager is ready
  (
    sleep 10
    worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.0" \
      "Team is online (project: ${name}, dir: $dir). You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (auto-accepts prompts). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Launch Watchdog (pane 0.$watchdog_pane)
  tmux send-keys -t "$session:0.$watchdog_pane" \
    "claude --dangerously-skip-permissions --agent tmux-watchdog" Enter
  sleep 0.5

  # Auto-start the watchdog loop
  (
    sleep 12
    watch_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$watch_panes" ]] && watch_panes+=", "
      watch_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.$watchdog_pane" \
      "Start monitoring session $session. Total panes: $total. Skip pane 0.0 (Manager) and 0.$watchdog_pane (yourself). Monitor panes ${watch_panes}." Enter
  ) &

  step_done

  # ── Step 6: Boot workers ───────────────────────────────────────
  step_start 6 "Booting ${worker_count} workers..."
  printf '\n'

  local booted=0
  local bar_width=30
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    (( booted++ ))

    # Progress bar
    local filled=$(( booted * bar_width / worker_count ))
    local empty=$(( bar_width - filled ))
    local bar=""
    for (( b=0; b<filled; b++ )); do bar+="█"; done
    for (( b=0; b<empty; b++ )); do bar+="░"; done
    printf "\r   ${DIM}[6/${STEP_TOTAL}]${RESET} Booting workers  ${BRAND}${bar}${RESET}  ${BOLD}${booted}${RESET}${DIM}/${worker_count}${RESET}  "

    tmux send-keys -t "$session:0.$i" \
      "claude --dangerously-skip-permissions --model opus" Enter
    sleep 0.3
  done
  printf "${SUCCESS}done${RESET}\n"

  # ── Final summary ──────────────────────────────────────────────
  printf '\n'
  printf "   ${DIM}┌─────────────────────────────────────────────────┐${RESET}\n"
  printf "   ${DIM}│${RESET}  ${SUCCESS}Claude Team is ready${RESET}                           ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Manager${RESET}    ${DIM}0.0${RESET}   Online                      ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Watchdog${RESET}   ${DIM}0.%-3s${RESET} Online                      ${DIM}│${RESET}\n" "$watchdog_pane"
  printf "   ${DIM}│${RESET}  ${BOLD}Workers${RESET}    ${DIM}%-4s${RESET}  Booting...                   ${DIM}│${RESET}\n" "$worker_count"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Project${RESET}   ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "$name"
  printf "   ${DIM}│${RESET}  ${DIM}Grid${RESET}      ${BOLD}%-5s${RESET}  ${DIM}Directory${RESET}  ${BOLD}%-18s${RESET} ${DIM}│${RESET}\n" "$grid" "$short_dir"
  printf "   ${DIM}│${RESET}  ${DIM}Session${RESET}   ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "$session"
  printf "   ${DIM}│${RESET}  ${DIM}Manifest${RESET}  ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "${runtime_dir}/session.env"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Tip: Workers will be ready in ~15s${RESET}              ${DIM}│${RESET}\n"
  printf "   ${DIM}└─────────────────────────────────────────────────┘${RESET}\n"
  printf '\n'

  # ── Focus on Manager pane, attach ──────────────────────────────
  tmux select-pane -t "$session:0.0"
  tmux attach -t "$session"
}

# ── Main Dispatch ─────────────────────────────────────────────────────

grid=""

case "${1:-}" in
  --help|-h)
    printf '\n'
    printf "  ${BRAND}Claude Code TMUX Team${RESET}\n"
    printf '\n'
    cat << 'HELP'
  Usage: claude-team [command] [grid]

  Commands:
    (none)     Smart launch — auto-attach or show project picker
    init       Register current directory as a project
    list       Show all registered projects and their status
    stop       Stop the session for the current project
    --help     Show this help

  Grid:
    NxM        Grid layout (e.g., 6x2, 4x3, 3x2)
               Only used when launching a new session

  Examples:
    claude-team              # smart launch
    claude-team init         # register current dir
    claude-team 4x3          # launch with 4x3 grid
    claude-team list         # show all projects
    claude-team stop         # stop current project session
HELP
    printf '\n'
    exit 0
    ;;
  init)
    register_project "$(pwd)"
    exit 0
    ;;
  list)
    list_projects
    exit 0
    ;;
  stop)
    stop_project
    exit $?
    ;;
  [0-9]*x[0-9]*)
    grid="$1"
    ;;
  "")
    # No args — fall through to smart launch
    ;;
  *)
    printf "  ${ERROR}Unknown command: $1${RESET}\n"
    printf "  Run ${BOLD}claude-team --help${RESET} for usage\n"
    exit 1
    ;;
esac

# ── Smart Launch ──────────────────────────────────────────────────────

dir="$(pwd)"
name="$(find_project "$dir")"

if [[ -n "$name" ]]; then
  # Known project
  session="ct-${name}"
  if session_exists "$session"; then
    # Already running — just attach
    printf "  ${SUCCESS}Attaching to${RESET} ${BOLD}${session}${RESET}...\n"
    tmux attach -t "$session"
  else
    # Known but not running — launch with premium UI
    launch_session "$name" "$dir" "${grid:-6x2}"
  fi
else
  # Unknown directory — show interactive menu
  show_menu "${grid:-6x2}"
fi
