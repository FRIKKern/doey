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
#   claude-team update       # Pull latest + reinstall (alias: reinstall)
#   claude-team doctor       # Check installation health & prerequisites
#   claude-team remove NAME  # Unregister a project from the registry
#   claude-team uninstall    # Remove all Claude Team files
#   claude-team version      # Show version and install info
#   claude-team 4x3          # Launch/reattach with specific grid
#   claude-team --help       # Show usage
#
# Shorthand: "ct" is installed automatically as a symlink to this script.
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
    "claude --dangerously-skip-permissions --model haiku --agent tmux-watchdog" Enter
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

# ── Update / Reinstall ───────────────────────────────────────────────
update_system() {
  local repo_path_file="$HOME/.claude/claude-team/repo-path"
  local repo_dir

  if [[ ! -f "$repo_path_file" ]]; then
    printf "  ${ERROR}Could not find the claude-code-tmux-team repo.${RESET}\n"
    printf "  Run ${BOLD}./install.sh${RESET} from the repo to register its location.\n"
    exit 1
  fi

  repo_dir="$(cat "$repo_path_file")"
  if [[ ! -d "$repo_dir" ]]; then
    printf "  ${ERROR}Could not find the claude-code-tmux-team repo.${RESET}\n"
    printf "  Run ${BOLD}./install.sh${RESET} from the repo to register its location.\n"
    exit 1
  fi

  printf "  ${BRAND}Updating claude-code-tmux-team...${RESET}\n"
  printf '\n'

  local old_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)

  # Warn about local changes
  if [[ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]; then
    printf "  ${WARN}⚠ Repo has local changes — git pull may fail or require merge${RESET}\n"
  fi

  printf "  ${DIM}Pulling latest changes...${RESET}\n"
  if ! git -C "$repo_dir" pull; then
    printf "  ${WARN}git pull failed — continuing with reinstall${RESET}\n"
  fi

  local new_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
  if [[ "$old_hash" == "$new_hash" ]]; then
    printf "  ${SUCCESS}Already up to date${RESET} ${DIM}($old_hash)${RESET}\n"
  else
    printf "  ${SUCCESS}Updated${RESET} ${DIM}$old_hash → $new_hash${RESET}\n"
  fi
  printf '\n'

  printf "  ${DIM}Running install.sh...${RESET}\n"
  if ! bash "$repo_dir/install.sh"; then
    printf "\n  ${ERROR}✗ Install failed during update.${RESET}\n"
    printf "  ${DIM}Repo is at $new_hash. Run install.sh manually to retry.${RESET}\n"
    exit 1
  fi
  printf '\n'

  rm -f "$HOME/.claude/claude-team/last-update-check.available"

  printf "  ${SUCCESS}Update complete.${RESET}\n"
  printf "  Running sessions need a restart: ${BOLD}claude-team stop && claude-team${RESET}\n"
}

# ── Uninstall ──────────────────────────────────────────────────────
uninstall_system() {
  printf '\n'
  printf "  ${BRAND}Claude Team — Uninstall${RESET}\n"
  printf '\n'

  printf "  This will remove:\n"
  printf "    ${DIM}• ~/.local/bin/claude-team${RESET}\n"
  printf "    ${DIM}• ~/.local/bin/ct${RESET}\n"
  printf "    ${DIM}• ~/.claude/agents/tmux-*.md${RESET}\n"
  printf "    ${DIM}• ~/.claude/commands/tmux-*.md${RESET}\n"
  printf "    ${DIM}• ~/.claude/claude-team/ (config & state)${RESET}\n"
  printf '\n'
  printf "  ${DIM}Will NOT remove: git repo, /tmp/claude-team, or agent-memory${RESET}\n"
  printf '\n'

  read -rp "  Continue? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    printf "  ${DIM}Cancelled.${RESET}\n\n"
    return 0
  fi

  rm -f ~/.local/bin/claude-team
  rm -f ~/.local/bin/ct
  rm -f ~/.claude/agents/tmux-*.md
  rm -f ~/.claude/commands/tmux-*.md
  rm -rf ~/.claude/claude-team

  printf '\n'
  printf "  ${SUCCESS}✓ Uninstalled successfully.${RESET}\n"
  printf "  ${DIM}To reinstall: cd <repo> && ./install.sh${RESET}\n"
  printf '\n'
}

# ── Doctor — check installation health ────────────────────────────────
check_doctor() {
  printf '\n'
  printf "  ${BRAND}Claude Team — System Check${RESET}\n"
  printf '\n'

  # tmux
  if command -v tmux &>/dev/null; then
    printf "  ${SUCCESS}✓${RESET} tmux installed  ${DIM}$(tmux -V)${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} tmux not installed\n"
  fi

  # claude CLI
  if command -v claude &>/dev/null; then
    printf "  ${SUCCESS}✓${RESET} claude CLI installed  ${DIM}$(claude --version 2>/dev/null || echo 'unknown version')${RESET}\n"
  else
    printf "  ${WARN}⚠${RESET} claude CLI not found in PATH\n"
  fi

  # ~/.local/bin in PATH
  if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
    printf "  ${SUCCESS}✓${RESET} ~/.local/bin is in PATH\n"
  else
    printf "  ${WARN}⚠${RESET} ~/.local/bin is not in PATH\n"
  fi

  # Agents installed
  if [[ -f "$HOME/.claude/agents/tmux-manager.md" ]]; then
    printf "  ${SUCCESS}✓${RESET} Agents installed  ${DIM}~/.claude/agents/tmux-manager.md${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} Agents not installed  ${DIM}~/.claude/agents/tmux-manager.md missing${RESET}\n"
  fi

  # Commands installed
  if [[ -f "$HOME/.claude/commands/tmux-dispatch.md" ]]; then
    printf "  ${SUCCESS}✓${RESET} Commands installed  ${DIM}~/.claude/commands/tmux-dispatch.md${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} Commands not installed  ${DIM}~/.claude/commands/tmux-dispatch.md missing${RESET}\n"
  fi

  # CLI installed
  if [[ -f "$HOME/.local/bin/claude-team" ]]; then
    printf "  ${SUCCESS}✓${RESET} CLI installed  ${DIM}~/.local/bin/claude-team${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} CLI not installed  ${DIM}~/.local/bin/claude-team missing${RESET}\n"
  fi

  # Repo path
  local repo_path_file="$HOME/.claude/claude-team/repo-path"
  if [[ -f "$repo_path_file" ]]; then
    local repo_dir
    repo_dir="$(cat "$repo_path_file")"
    if [[ -d "$repo_dir" ]]; then
      printf "  ${SUCCESS}✓${RESET} Repo registered  ${DIM}${repo_dir}${RESET}\n"
    else
      printf "  ${ERROR}✗${RESET} Repo path registered but directory missing  ${DIM}${repo_dir}${RESET}\n"
    fi
  else
    printf "  ${ERROR}✗${RESET} Repo path not registered  ${DIM}~/.claude/claude-team/repo-path missing${RESET}\n"
  fi

  # Version tracking
  local version_file="$HOME/.claude/claude-team/version"
  if [[ -f "$version_file" ]]; then
    local ver vdate
    ver="$(grep "^version=" "$version_file" | cut -d= -f2)"
    vdate="$(grep "^date=" "$version_file" | cut -d= -f2)"
    printf "  ${SUCCESS}✓${RESET} Version tracked  ${DIM}${ver} (${vdate})${RESET}\n"
  else
    printf "  ${WARN}⚠${RESET} No version file  ${DIM}Run 'ct update' to generate${RESET}\n"
  fi

  printf '\n'
}

# ── Remove — unregister a project ────────────────────────────────────
remove_project() {
  local name="${1:-}"

  # If no argument, try current directory
  if [[ -z "$name" ]]; then
    name="$(find_project "$(pwd)")"
  fi

  # Still no name — error with hint
  if [[ -z "$name" ]]; then
    printf "  ${ERROR}No project specified and no project registered for $(pwd)${RESET}\n"
    printf '\n'
    printf "  ${DIM}Registered projects:${RESET}\n"
    while IFS=: read -r pname ppath; do
      [[ -z "$pname" ]] && continue
      printf "    ${BOLD}${pname}${RESET}  ${DIM}${ppath}${RESET}\n"
    done < "$PROJECTS_FILE"
    printf '\n'
    printf "  Usage: ${BOLD}claude-team remove <name>${RESET}\n"
    return 1
  fi

  # Check if project exists in registry
  if ! grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null; then
    printf "  ${ERROR}No project named '${name}' in registry${RESET}\n"
    return 1
  fi

  # Remove matching line
  sed -i '' "/^${name}:/d" "$PROJECTS_FILE"
  printf "  ${SUCCESS}Removed '${name}' from project registry${RESET}\n"

  # Hint about running session
  if session_exists "ct-${name}"; then
    printf "  ${WARN}Session ct-${name} is still running. Use 'claude-team stop' in that directory to stop it.${RESET}\n"
  fi
}

# ── Version — show installation info ─────────────────────────────────
show_version() {
  printf '\n'
  printf "  ${BRAND}Claude Code TMUX Team${RESET}\n"
  printf '\n'

  local version_file="$HOME/.claude/claude-team/version"
  if [[ -f "$version_file" ]]; then
    local ver installed_date repo_dir
    ver="$(grep "^version=" "$version_file" | cut -d= -f2)"
    installed_date="$(grep "^date=" "$version_file" | cut -d= -f2)"
    repo_dir="$(grep "^repo=" "$version_file" | cut -d= -f2)"
    printf "  ${DIM}Version${RESET}    ${BOLD}${ver}${RESET}  ${DIM}(installed ${installed_date})${RESET}\n"
    if [[ -n "$repo_dir" ]] && [[ -d "$repo_dir" ]]; then
      local latest
      latest="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo '')"
      if [[ -n "$latest" ]] && [[ "$latest" != "$ver" ]]; then
        printf "  ${DIM}Update${RESET}     ${WARN}${latest} available${RESET}  ${DIM}(run 'ct update')${RESET}\n"
      fi
    fi
  else
    # Fallback to git if no version file (pre-version-tracking install)
    local repo_path_file="$HOME/.claude/claude-team/repo-path"
    if [[ -f "$repo_path_file" ]]; then
      local repo_dir
      repo_dir="$(cat "$repo_path_file")"
      if [[ -d "$repo_dir" ]]; then
        local version_info
        version_info="$(git -C "$repo_dir" log -1 --format="%h (%ci)" 2>/dev/null || echo 'unknown')"
        printf "  ${DIM}Version${RESET}    ${BOLD}${version_info}${RESET}  ${DIM}(no version file — reinstall to track)${RESET}\n"
      fi
    fi
  fi

  printf "  ${DIM}Agents${RESET}     ${BOLD}~/.claude/agents/${RESET}\n"
  printf "  ${DIM}Commands${RESET}   ${BOLD}~/.claude/commands/${RESET}\n"
  printf "  ${DIM}CLI${RESET}        ${BOLD}~/.local/bin/claude-team${RESET}\n"

  local project_count=0
  if [[ -f "$PROJECTS_FILE" ]]; then
    project_count="$(grep -c '.' "$PROJECTS_FILE" 2>/dev/null || echo 0)"
  fi
  printf "  ${DIM}Projects${RESET}   ${BOLD}${project_count} registered${RESET}\n"

  printf '\n'
}

# ── Auto-update check ─────────────────────────────────────────────
check_for_updates() {
  local state_dir="$HOME/.claude/claude-team"
  local last_check_file="$state_dir/last-update-check"
  local cache_file="$state_dir/last-update-check.available"
  local repo_path_file="$state_dir/repo-path"
  local check_interval=86400  # 24 hours

  # Skip if no repo registered
  [[ ! -f "$repo_path_file" ]] && return 0
  local repo_dir
  repo_dir="$(cat "$repo_path_file")"
  [[ ! -d "$repo_dir/.git" ]] && return 0

  local now
  now=$(date +%s)

  # Show cached result if available
  if [[ -f "$cache_file" ]]; then
    local behind
    behind=$(cat "$cache_file")
    if [[ "$behind" -gt 0 ]] 2>/dev/null; then
      printf "  ${WARN}⚠ Update available${RESET} ${DIM}(%s commit(s) behind — run: ct update)${RESET}\n" "$behind"
    fi
  fi

  # Should we fetch?
  local should_fetch=true
  if [[ -f "$last_check_file" ]]; then
    local last_ts
    last_ts=$(cat "$last_check_file")
    if (( now - last_ts < check_interval )); then
      should_fetch=false
    fi
  fi

  if [[ "$should_fetch" == true ]]; then
    # Background fetch + cache result (non-blocking)
    (
      echo "$now" > "$last_check_file"
      if git -C "$repo_dir" fetch origin main --quiet 2>/dev/null; then
        local behind_count
        behind_count=$(git -C "$repo_dir" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
        echo "$behind_count" > "$cache_file"
      fi
    ) &
    disown 2>/dev/null
  fi
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
    update     Pull latest changes and reinstall (alias: reinstall)
    doctor     Check installation health and prerequisites
    remove     Unregister a project (by name, or current dir)
    uninstall  Remove all Claude Team files (keeps git repo and agent-memory)
    version    Show version and installation info
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
    claude-team update       # pull latest + reinstall
    claude-team doctor       # check system health
    claude-team remove myapp # unregister a project
    claude-team uninstall    # remove all installed files
    claude-team version      # show install info
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
  update|reinstall)
    update_system
    exit 0
    ;;
  doctor)
    check_doctor
    exit 0
    ;;
  remove)
    remove_project "${2:-}"
    exit 0
    ;;
  uninstall)
    uninstall_system
    exit 0
    ;;
  version|--version|-v)
    show_version
    exit 0
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

check_for_updates

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
