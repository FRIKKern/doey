#!/usr/bin/env bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────
# doey — Project-aware TMUX Doey launcher
#
# Usage:
#   doey              # Smart launch (auto-attach or project picker)
#   doey init         # Register current directory as a project
#   doey list         # Show all registered projects + status
#   doey stop         # Stop session for current project
#   doey update       # Pull latest + reinstall (alias: reinstall)
#   doey doctor       # Check installation health & prerequisites
#   doey remove NAME  # Unregister a project from the registry
#   doey uninstall    # Remove all Doey files
#   doey test         # Run E2E integration test
#   doey version      # Show version and install info
#   doey 4x3          # Launch/reattach with specific grid
#   doey dynamic      # Launch with dynamic grid (add workers on demand)
#   doey add          # Add a worker column (2 workers) to dynamic session
#   doey remove 2     # Remove worker column 2 from dynamic session
#   doey --help       # Show usage
#
# CLI command: "doey" is installed to ~/.local/bin/doey.
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

# ── Script directory ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Project registry ─────────────────────────────────────────────────
PROJECTS_FILE="$HOME/.claude/doey/projects"
mkdir -p "$(dirname "$PROJECTS_FILE")"
touch "$PROJECTS_FILE"

# ── Helpers ───────────────────────────────────────────────────────────

# Resolve the doey repo directory
resolve_repo_dir() {
  if [ -f "$HOME/.claude/doey/repo-path" ]; then
    cat "$HOME/.claude/doey/repo-path"
  else
    (cd "$SCRIPT_DIR/.." && pwd)
  fi
}

# Install Doey hooks and settings into a target project directory
# Usage: install_doey_hooks <target_dir> [indent]
install_doey_hooks() {
  local target_dir="$1"
  local indent="${2:-   }"
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  if [ "$target_dir" = "$repo_dir" ]; then
    return 0
  fi
  mkdir -p "$target_dir/.claude/hooks"
  cp "${repo_dir}"/.claude/hooks/*.sh "$target_dir/.claude/hooks/" 2>/dev/null && \
    chmod +x "$target_dir"/.claude/hooks/*.sh || true
  if [ ! -f "$target_dir/.claude/settings.local.json" ]; then
    cp "${repo_dir}/.claude/settings.local.json" "$target_dir/.claude/settings.local.json"
  else
    printf "${indent}${WARN}Existing .claude/settings.local.json found — verify hooks are registered${RESET}\n"
  fi
  printf "${indent}${DIM}Installed Doey hooks${RESET}\n"
}

# Write a status file for a pane (used during boot to set initial READY state)
# Usage: write_pane_status <runtime_dir> <session:window.pane> <status> [task]
write_pane_status() {
  local rt_dir="$1" pane_id="$2" status="$3" task="${4:-}"
  local safe="${pane_id//[:.]/_}"
  cat > "${rt_dir}/status/${safe}.status" <<EOF
PANE: ${pane_id}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: ${status}
TASK: ${task}
EOF
}

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
    printf "  ${SUCCESS}Already registered as '%s'${RESET}\n" "$(find_project "$dir")"
    return 0
  fi

  # Handle name collision
  if grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null; then
    local i=2
    while grep -q "^${name}-${i}:" "$PROJECTS_FILE" 2>/dev/null; do i=$((i + 1)); done
    name="${name}-${i}"
  fi

  echo "${name}:${dir}" >> "$PROJECTS_FILE"
  printf "  ${SUCCESS}Registered${RESET} ${BOLD}%s${RESET} ${DIM}→${RESET} %s\n" "$name" "$dir"
}

# List all projects with running status
list_projects() {
  printf '\n'
  printf "  ${BRAND}Doey — Projects${RESET}\n"
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
    printf "  ${DIM}(no projects registered)${RESET}\n"
  fi
  printf '\n'
  printf "  ${SUCCESS}●${RESET} running  ${DIM}○${RESET} stopped\n"
  printf '\n'
}

# Stop session for current directory's project
stop_project() {
  # 1) If inside a doey tmux session, stop it directly
  if [[ -n "${TMUX:-}" ]]; then
    local current_session
    current_session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [[ "$current_session" == doey-* ]]; then
      printf "  Stopping doey session: ${BOLD}%s${RESET}...\n" "$current_session"
      _kill_doey_session "$current_session"
      printf "  ${SUCCESS}Stopped${RESET} %s\n" "$current_session"
      return 0
    fi
  fi

  # 2) If pwd matches a registered project, stop that
  local name
  name="$(find_project "$(pwd)")"
  if [[ -n "$name" ]]; then
    local session="doey-${name}"
    if session_exists "$session"; then
      printf "  Stopping doey session: ${BOLD}%s${RESET}...\n" "$session"
      _kill_doey_session "$session"
      printf "  ${SUCCESS}Stopped${RESET} %s\n" "$session"
    else
      printf "  ${DIM}No active session for %s${RESET}\n" "$name"
    fi
    return 0
  fi

  # 3) Otherwise, find all running doey sessions and show picker
  local -a running_sessions=()
  while IFS= read -r sess; do
    [[ "$sess" == doey-* ]] && running_sessions+=("$sess")
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)

  if [[ ${#running_sessions[@]} -eq 0 ]]; then
    printf "  ${DIM}No running Doey sessions found.${RESET}\n"
    return 0
  fi

  if [[ ${#running_sessions[@]} -eq 1 ]]; then
    printf '\n'
    read -rp "  Stop ${BOLD}${running_sessions[0]}${RESET}? (y/N) " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      _kill_doey_session "${running_sessions[0]}"
      printf "  ${SUCCESS}Stopped${RESET} ${running_sessions[0]}\n"
    else
      printf "  ${DIM}Cancelled${RESET}\n"
    fi
    return 0
  fi

  # Multiple running sessions — numbered picker
  printf '\n'
  printf "  ${BRAND}Running Doey sessions:${RESET}\n"
  for i in "${!running_sessions[@]}"; do
    printf "    ${BOLD}%d)${RESET} %s\n" $((i+1)) "${running_sessions[$i]}"
  done
  printf '\n'
  read -rp "  Stop which session? (number or 'all'): " choice

  case "$choice" in
    all|ALL)
      for sess in "${running_sessions[@]}"; do
        _kill_doey_session "$sess"
        printf "  ${SUCCESS}Stopped${RESET} ${sess}\n"
      done
      ;;
    [0-9]*)
      local idx=$((choice - 1))
      if [[ $idx -ge 0 && $idx -lt ${#running_sessions[@]} ]]; then
        _kill_doey_session "${running_sessions[$idx]}"
        printf "  ${SUCCESS}Stopped${RESET} ${running_sessions[$idx]}\n"
      else
        printf "  ${ERROR}Invalid selection${RESET}\n"
        return 1
      fi
      ;;
    *)
      printf "  ${DIM}Cancelled${RESET}\n"
      ;;
  esac
}

# Kill a doey tmux session gracefully: kill Claude processes first, then session, then cleanup
_kill_doey_session() {
  local session="$1"
  # Kill Claude processes in all panes
  for pane_id in $(tmux list-panes -s -t "$session" -F '#{pane_id}' 2>/dev/null); do
    local pane_pid
    pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null || true)
    if [[ -n "$pane_pid" ]]; then
      pkill -P "$pane_pid" 2>/dev/null || true
      kill -- -"$pane_pid" 2>/dev/null || true
    fi
  done
  sleep 1
  # Kill the tmux session
  tmux kill-session -t "$session" < /dev/null 2>/dev/null || true
  # Clean up runtime directory
  local project_name="${session#doey-}"
  rm -rf "/tmp/doey/${project_name}" 2>/dev/null || true
}

# Show interactive project picker menu
show_menu() {
  local grid="${1:-6x2}"

  printf '\n'
  printf "  ${BRAND}Doey${RESET}\n"
  printf '\n'
  printf "  ${WARN}No project registered for %s${RESET}\n" "$(pwd)"
  printf '\n'

  # Read projects into arrays
  local -a names=() paths=() statuses=()
  while IFS=: read -r name path; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    paths+=("$path")
    if session_exists "doey-${name}"; then
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
        local selected_session="doey-${selected_name}"
        if session_exists "$selected_session"; then
          if [[ -n "${TMUX:-}" ]]; then
            tmux switch-client -t "$selected_session"
          else
            tmux attach -t "$selected_session"
          fi
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
      local init_name
      init_name="$(find_project "$(pwd)")"
      if [[ -n "$init_name" ]]; then
        launch_session "$init_name" "$(pwd)" "$grid"
      fi
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

# ── Column collapse/expand ────────────────────────────────────────────

# Return the column index for a given pane index in a grid with `cols` columns
column_for_pane() {
  local pane_index="$1"
  local cols="$2"
  echo $(( pane_index % cols ))
}

# Collapse a column to minimal width (3 chars)
collapse_column() {
  local session="$1"
  local col_index="$2"
  local runtime_dir="$3"

  if [[ "$col_index" -eq 0 ]]; then
    printf "  ${ERROR}Cannot collapse column 0 (Manager column)${RESET}\n"
    return 1
  fi

  tmux resize-pane -t "${session}:0.${col_index}" -x 3
  touch "${runtime_dir}/status/col_${col_index}.collapsed"
  printf "  ${SUCCESS}Collapsed${RESET} column ${BOLD}${col_index}${RESET}\n"
}

# Expand a column back to fair width
expand_column() {
  local session="$1"
  local col_index="$2"
  local fair_width="$3"
  local runtime_dir="$4"

  tmux resize-pane -t "${session}:0.${col_index}" -x "$fair_width"
  rm -f "${runtime_dir}/status/col_${col_index}.collapsed"
  printf "  ${SUCCESS}Expanded${RESET} column ${BOLD}${col_index}${RESET}\n"
}

# Rebalance all columns: collapsed get 3 chars, expanded share remaining width
rebalance_columns() {
  local session="$1"
  local cols="$2"
  local runtime_dir="$3"

  local window_width
  window_width="$(tmux display-message -t "$session" -p '#{window_width}')"

  local collapsed_count=0
  for (( c=0; c<cols; c++ )); do
    [[ -f "${runtime_dir}/status/col_${c}.collapsed" ]] && (( collapsed_count++ ))
  done

  local expanded_count=$(( cols - collapsed_count ))
  if [[ "$expanded_count" -le 0 ]]; then
    printf "  ${WARN}All columns collapsed — nothing to rebalance${RESET}\n"
    return 0
  fi

  local fair_width=$(( (window_width - collapsed_count * 3 - (cols - 1)) / expanded_count ))

  for (( c=0; c<cols; c++ )); do
    if [[ -f "${runtime_dir}/status/col_${c}.collapsed" ]]; then
      tmux resize-pane -t "${session}:0.${c}" -x 3 2>/dev/null || true
      continue
    fi
    tmux resize-pane -t "${session}:0.${c}" -x "$fair_width" 2>/dev/null || true
  done
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
  local session="doey-${name}"
  local runtime_dir="/tmp/doey/${name}"
  local short_dir="${dir/#$HOME/~}"

  cd "$dir"

  # ── Banner ──────────────────────────────────────────────────────
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
  printf '   ██████╗  ██████╗ ███████╗██╗   ██╗\n'
  printf '   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝\n'
  printf '   ██║  ██║██║   ██║█████╗   ╚████╔╝ \n'
  printf '   ██║  ██║██║   ██║██╔══╝    ╚██╔╝  \n'
  printf '   ██████╔╝╚██████╔╝███████╗   ██║   \n'
  printf '   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝   \n'
  printf "${RESET}"
  printf "   ${DIM}Let me Doey for you${RESET}\n"
  printf '\n'
  printf "   ${DIM}Project${RESET} ${BOLD}${name}${RESET}  ${DIM}Grid${RESET} ${BOLD}${grid}${RESET}  ${DIM}Workers${RESET} ${BOLD}${worker_count}${RESET}\n"
  printf "   ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}  ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  # ── Pre-accept trust for project directory ───────────────────
  # Prevents the "Do you trust this directory?" prompt from appearing
  # in every pane at startup, saving 30+ seconds of manual clicking.
  local claude_settings="$HOME/.claude/settings.json"
  if command -v jq &>/dev/null; then
    if [ -f "$claude_settings" ]; then
      if ! jq --arg dir "$dir" -e '.trustedDirectories // [] | index($dir)' "$claude_settings" > /dev/null 2>&1; then
        jq --arg dir "$dir" '(.trustedDirectories // []) |= . + [$dir]' "$claude_settings" 2>/dev/null > "${claude_settings}.tmp" \
          && mv "${claude_settings}.tmp" "$claude_settings"
        printf "   ${DIM}Trusted project directory added to ~/.claude/settings.json${RESET}\n"
      fi
    else
      mkdir -p "$(dirname "$claude_settings")"
      printf '{"trustedDirectories": ["%s"]}\n' "$dir" > "$claude_settings"
      printf "   ${DIM}Created ~/.claude/settings.json with trusted directory${RESET}\n"
    fi
  else
    printf "   ${WARN}jq not found — skipping auto-trust (you may see trust prompts)${RESET}\n"
  fi

  # ── Install Doey hooks into target project ─────────────────────
  install_doey_hooks "$dir" "   "

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
PROJECT_DIR="$dir"
PROJECT_NAME="$name"
SESSION_NAME="$session"
GRID="$grid"
TOTAL_PANES="$total"
WORKER_COUNT="$worker_count"
WATCHDOG_PANE="$watchdog_pane"
WORKER_PANES="$worker_panes_csv"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="500"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
MANIFEST

  # Generate shared worker system prompt (appended to Claude Code's default prompt)
  cat > "${runtime_dir}/worker-system-prompt.md" << 'WORKER_PROMPT'
# Doey Worker

You are a **Worker** on the Doey team, coordinated by a Manager in pane 0.0. You receive tasks via this chat and execute them independently.

## Rules
1. **Absolute paths only** — Always use absolute file paths. Never use relative paths.
2. **Stay in scope** — Only make changes within the scope of your assigned task. Do not refactor, clean up, or "improve" code outside your task.
3. **Concurrent awareness** — Other workers are editing other files in this codebase simultaneously. Avoid broad sweeping changes (global renames, config modifications, formatter runs) unless your task explicitly requires it.
4. **When done, stop** — Complete your task and stop. Do not ask follow-up questions unless you are genuinely blocked. The Manager will check your output.
5. **If blocked, describe and stop** — If you encounter an unrecoverable error, describe it clearly and stop.
6. **No git commits** — Do not create git commits unless your task explicitly says to. The Manager coordinates commits.
7. **No tmux interaction** — Do not try to communicate with other panes. Just do your work.
WORKER_PROMPT

  cat >> "${runtime_dir}/worker-system-prompt.md" << WORKER_CONTEXT

## Project
- **Name:** ${name}
- **Root:** ${dir}
- **Runtime directory:** ${runtime_dir}
WORKER_CONTEXT

  tmux new-session -d -s "$session" -c "$dir"
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"
  step_done

  # ── Step 2: Apply theme ────────────────────────────────────────
  step_start 2 "Applying theme..."

  # Pane borders — heavy lines with role-aware titles
  tmux set-option -t "$session" pane-border-status top
  tmux set-option -t "$session" pane-border-format \
    " #{?pane_active,#[fg=cyan#,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  tmux set-option -t "$session" pane-border-style 'fg=colour238'
  tmux set-option -t "$session" pane-active-border-style 'fg=cyan'
  tmux set-option -t "$session" pane-border-lines heavy

  # Status bar — dark bg, branded left segment
  tmux set-option -t "$session" status-position top
  tmux set-option -t "$session" status-style 'bg=colour233,fg=colour248'
  tmux set-option -t "$session" status-left-length 50
  tmux set-option -t "$session" status-right-length 70
  tmux set-option -t "$session" status-left \
    "#[fg=colour233,bg=cyan,bold]  DOEY: ${name} #[fg=cyan,bg=colour236,nobold] #S #[fg=colour236,bg=colour233] "
  tmux set-option -t "$session" status-right \
    "#[fg=colour245] #{pane_title} #[fg=colour233,bg=colour240]  %H:%M #[fg=colour233,bg=colour245,bold] #('${SCRIPT_DIR}/tmux-statusbar.sh') "
  tmux set-option -t "$session" status-interval 2

  # Window status styling
  tmux set-option -t "$session" window-status-format '#[fg=colour245] #I #W '
  tmux set-option -t "$session" window-status-current-format '#[fg=cyan,bold] #I #W '
  tmux set-option -t "$session" message-style 'bg=colour233,fg=cyan'

  # Terminal tab/window title — shows project name in macOS Terminal tabs
  tmux set-option -t "$session" set-titles on
  tmux set-option -t "$session" set-titles-string "🤖 #{session_name} — #{pane_title}"

  # Enable mouse for pane selection, scrolling, resizing
  tmux set-option -t "$session" mouse on

  # Suppress terminal bell from worker panes — prevents notification spam
  # Our stop-notify.sh hook handles Manager-only notifications via osascript
  tmux set-option -t "$session" bell-action none
  tmux set-option -t "$session" visual-bell off

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

  # Verify pane count
  local actual
  actual=$(tmux list-panes -t "$session" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$actual" -ne "$total" ]]; then
    printf "\n"
    printf "   ${WARN}⚠ Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total" "$actual"
  fi

  step_done

  # ── Step 4: Name panes ─────────────────────────────────────────
  step_start 4 "Naming panes..."

  tmux select-pane -t "$session:0.0" -T "MGR Manager"
  tmux select-pane -t "$session:0.$watchdog_pane" -T "WDG Watchdog"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    wnum=$((wnum + 1))
    tmux select-pane -t "$session:0.$i" -T "W${wnum} Worker ${wnum}"
  done

  step_done

  # ── Step 5: Launch Manager & Watchdog ──────────────────────────
  step_start 5 "Launching Manager & Watchdog..."

  # Launch Manager (pane 0.0)
  tmux send-keys -t "$session:0.0" \
    "claude --dangerously-skip-permissions --agent doey-manager" Enter
  sleep 0.5

  write_pane_status "$runtime_dir" "${session}:0.0" "READY"

  # Send initial briefing once Manager is ready
  (
    sleep 8
    worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.0" \
      "Team is online (project: ${name}, dir: $dir). You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (monitors workers, delivers messages). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Launch Watchdog (pane 0.$watchdog_pane)
  tmux send-keys -t "$session:0.$watchdog_pane" \
    "claude --dangerously-skip-permissions --model haiku --agent doey-watchdog" Enter
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
    # Schedule periodic compact to keep Watchdog context lean
    sleep 20
    tmux send-keys -t "$session:0.$watchdog_pane" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &

  # Clean up background jobs on early exit
  trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM

  step_done

  # ── Step 6: Boot workers ───────────────────────────────────────
  step_start 6 "Booting ${worker_count} workers..."
  printf '\n'

  local booted=0
  local bar_width=30
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    booted=$((booted + 1))

    # Progress bar
    local filled=$(( booted * bar_width / worker_count ))
    local empty=$(( bar_width - filled ))
    local bar=""
    for (( b=0; b<filled; b++ )); do bar+="█"; done
    for (( b=0; b<empty; b++ )); do bar+="░"; done
    printf "\r   ${DIM}[6/${STEP_TOTAL}]${RESET} Booting workers  ${BRAND}${bar}${RESET}  ${BOLD}${booted}${RESET}${DIM}/${worker_count}${RESET}  "

    # Create per-worker system prompt file (base prompt + worker identity)
    local worker_prompt_file="${runtime_dir}/worker-system-prompt-${booted}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file"
    printf '\n\n## Identity\nYou are Worker %s in pane 0.%s of session %s.\n' "$booted" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus"
    worker_cmd+=" --append-system-prompt-file \"${worker_prompt_file}\""
    tmux send-keys -t "$session:0.$i" "$worker_cmd" Enter
    sleep 0.3

    write_pane_status "$runtime_dir" "${session}:0.${i}" "READY"
  done
  printf "${SUCCESS}done${RESET}\n"

  # ── Final summary ──────────────────────────────────────────────
  printf '\n'
  printf "   ${DIM}┌─────────────────────────────────────────────────┐${RESET}\n"
  printf "   ${DIM}│${RESET}  ${SUCCESS}Doey is ready${RESET}                           ${DIM}│${RESET}\n"
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
  # Clear the trap — background briefing jobs should complete normally after attach
  trap - EXIT INT TERM
  tmux select-pane -t "$session:0.0"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach -t "$session"
  fi
}

# ── Update / Reinstall ───────────────────────────────────────────────
update_system() {
  local repo_path_file="$HOME/.claude/doey/repo-path"
  local repo_dir

  if [[ -f "$repo_path_file" ]]; then
    repo_dir="$(cat "$repo_path_file")"
  fi

  if [[ -n "${repo_dir:-}" ]] && [[ -d "$repo_dir" ]] && [[ -d "$repo_dir/.git" ]]; then
    # Local repo update path
    printf "  ${BRAND}Updating doey...${RESET}\n"
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
  else
    # Web update fallback — no local repo available
    local web_repo_url="https://github.com/frikk-gyldendal/doey.git"
    local clone_dir
    clone_dir=$(mktemp -d "${TMPDIR:-/tmp}/doey-update.XXXXXX")

    printf "  ${BRAND}Updating doey...${RESET}\n"
    printf '\n'
    printf "  ${DIM}No local repo found — updating from remote...${RESET}\n"

    printf "  ${DIM}Cloning latest version...${RESET}\n"
    if ! git clone --depth 1 "$web_repo_url" "$clone_dir"; then
      printf "\n  ${ERROR}✗ Failed to clone repository.${RESET}\n"
      printf "  ${DIM}Make sure git is installed and you have network access.${RESET}\n"
      rm -rf "$clone_dir"
      exit 1
    fi
    printf "  ${SUCCESS}✓ Repository cloned${RESET}\n"
    printf '\n'

    printf "  ${DIM}Running install.sh...${RESET}\n"
    if ! bash "$clone_dir/install.sh"; then
      printf "\n  ${ERROR}✗ Install failed during update.${RESET}\n"
      rm -rf "$clone_dir"
      exit 1
    fi

    rm -rf "$clone_dir"
  fi
  printf '\n'

  rm -f "$HOME/.claude/doey/last-update-check.available"

  printf "${BRAND}"
  cat << 'BANNER'

   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
   Let me Doey for you
BANNER
  printf "${RESET}\n"

  printf "  ${SUCCESS}Update complete.${RESET}\n"
  printf "  Running sessions need a restart: ${BOLD}doey stop && doey${RESET}\n"
}

# ── Uninstall ──────────────────────────────────────────────────────
uninstall_system() {
  printf '\n'
  printf "  ${BRAND}Doey — Uninstall${RESET}\n"
  printf '\n'

  printf "  This will remove:\n"
  printf "    ${DIM}• ~/.local/bin/doey${RESET}\n"
  printf "    ${DIM}• ~/.claude/agents/doey-*.md${RESET}\n"
  printf "    ${DIM}• ~/.claude/commands/doey-*.md${RESET}\n"
  printf "    ${DIM}• ~/.claude/doey/ (config & state)${RESET}\n"
  printf '\n'
  printf "  ${DIM}Will NOT remove: git repo, /tmp/doey, or agent-memory${RESET}\n"
  printf '\n'

  read -rp "  Continue? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    printf "  ${DIM}Cancelled.${RESET}\n\n"
    return 0
  fi

  rm -f ~/.local/bin/doey
  rm -f ~/.claude/agents/doey-*.md
  rm -f ~/.claude/commands/doey-*.md
  rm -rf ~/.claude/doey

  printf '\n'
  printf "  ${SUCCESS}✓ Uninstalled successfully.${RESET}\n"
  printf "  ${DIM}To reinstall: cd <repo> && ./install.sh${RESET}\n"
  printf '\n'
}

# ── Doctor — check installation health ────────────────────────────────
check_doctor() {
  printf '\n'
  printf "  ${BRAND}Doey — System Check${RESET}\n"
  printf '\n'

  # tmux
  if command -v tmux &>/dev/null; then
    printf "  ${SUCCESS}✓${RESET} tmux installed  ${DIM}%s${RESET}\n" "$(tmux -V)"
  else
    printf "  ${ERROR}✗${RESET} tmux not installed\n"
  fi

  # claude CLI
  if command -v claude &>/dev/null; then
    printf "  ${SUCCESS}✓${RESET} claude CLI installed  ${DIM}%s${RESET}\n" "$(claude --version 2>/dev/null || echo 'unknown version')"
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
  if [[ -f "$HOME/.claude/agents/doey-manager.md" ]]; then
    printf "  ${SUCCESS}✓${RESET} Agents installed  ${DIM}~/.claude/agents/doey-manager.md${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} Agents not installed  ${DIM}~/.claude/agents/doey-manager.md missing${RESET}\n"
  fi

  # Commands installed
  if [[ -f "$HOME/.claude/commands/doey-dispatch.md" ]]; then
    printf "  ${SUCCESS}✓${RESET} Commands installed  ${DIM}~/.claude/commands/doey-dispatch.md${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} Commands not installed  ${DIM}~/.claude/commands/doey-dispatch.md missing${RESET}\n"
  fi

  # CLI installed
  if [[ -f "$HOME/.local/bin/doey" ]]; then
    printf "  ${SUCCESS}✓${RESET} CLI installed  ${DIM}~/.local/bin/doey${RESET}\n"
  else
    printf "  ${ERROR}✗${RESET} CLI not installed  ${DIM}~/.local/bin/doey missing${RESET}\n"
  fi

  # Repo path
  local repo_path_file="$HOME/.claude/doey/repo-path"
  if [[ -f "$repo_path_file" ]]; then
    local repo_dir
    repo_dir="$(cat "$repo_path_file")"
    if [[ -d "$repo_dir" ]]; then
      printf "  ${SUCCESS}✓${RESET} Repo registered  ${DIM}%s${RESET}\n" "$repo_dir"
    else
      printf "  ${ERROR}✗${RESET} Repo path registered but directory missing  ${DIM}%s${RESET}\n" "$repo_dir"
    fi
  else
    printf "  ${ERROR}✗${RESET} Repo path not registered  ${DIM}~/.claude/doey/repo-path missing${RESET}\n"
  fi

  # jq (optional — used for auto-trust in launch)
  if command -v jq &>/dev/null; then
    printf "  ${SUCCESS}✓${RESET} jq installed  ${DIM}%s${RESET}\n" "$(jq --version 2>/dev/null || echo 'unknown version')"
  else
    printf "  ${WARN}⚠${RESET} jq not found — auto-trust during launch will be skipped\n"
  fi

  # Version tracking
  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    local ver vdate
    ver="$(grep "^version=" "$version_file" | cut -d= -f2)"
    vdate="$(grep "^date=" "$version_file" | cut -d= -f2)"
    printf "  ${SUCCESS}✓${RESET} Version tracked  ${DIM}%s (%s)${RESET}\n" "$ver" "$vdate"
  else
    printf "  ${WARN}⚠${RESET} No version file  ${DIM}Run 'doey update' to generate${RESET}\n"
  fi

  # Context audit (reuses $repo_dir from repo-path check above)
  if [[ -n "${repo_dir:-}" ]] && [[ -f "$repo_dir/shell/context-audit.sh" ]]; then
    local audit_output
    if audit_output=$(bash "$repo_dir/shell/context-audit.sh" --installed --no-color 2>&1); then
      printf "  ${SUCCESS}✓${RESET} Context audit clean\n"
    else
      printf "  ${WARN}⚠${RESET} Context audit found issues:\n"
      printf '%s\n' "$audit_output"
    fi
  else
    printf "  ${DIM}–${RESET} Context audit skipped  ${DIM}(script not found)${RESET}\n"
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
    printf "  ${ERROR}No project specified and no project registered for %s${RESET}\n" "$(pwd)"
    printf '\n'
    printf "  ${DIM}Registered projects:${RESET}\n"
    while IFS=: read -r pname ppath; do
      [[ -z "$pname" ]] && continue
      printf "    ${BOLD}%s${RESET}  ${DIM}%s${RESET}\n" "$pname" "$ppath"
    done < "$PROJECTS_FILE"
    printf '\n'
    printf "  Usage: ${BOLD}doey remove <name>${RESET}\n"
    return 1
  fi

  # Validate name format (only allow sanitized project names)
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    printf "  ${ERROR}Invalid project name: %s${RESET}\n" "$name"
    return 1
  fi

  # Check if project exists in registry
  if ! grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null; then
    printf "  ${ERROR}No project named '%s' in registry${RESET}\n" "$name"
    return 1
  fi

  # Remove matching line
  grep -v "^${name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
  printf "  ${SUCCESS}Removed '%s' from project registry${RESET}\n" "$name"

  # Hint about running session
  if session_exists "doey-${name}"; then
    printf "  ${WARN}Session doey-%s is still running. Use 'doey stop' in that directory to stop it.${RESET}\n" "$name"
  fi
}

# ── Version — show installation info ─────────────────────────────────
show_version() {
  printf '\n'
  printf "  ${BRAND}Doey${RESET}\n"
  printf '\n'

  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    local ver installed_date repo_dir
    ver="$(grep "^version=" "$version_file" | cut -d= -f2)"
    installed_date="$(grep "^date=" "$version_file" | cut -d= -f2)"
    repo_dir="$(grep "^repo=" "$version_file" | cut -d= -f2)"
    printf "  ${DIM}Version${RESET}    ${BOLD}%s${RESET}  ${DIM}(installed %s)${RESET}\n" "$ver" "$installed_date"
    if [[ -n "$repo_dir" ]] && [[ -d "$repo_dir" ]]; then
      local latest
      latest="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo '')"
      if [[ -n "$latest" ]] && [[ "$latest" != "$ver" ]]; then
        printf "  ${DIM}Update${RESET}     ${WARN}%s available${RESET}  ${DIM}(run 'doey update')${RESET}\n" "$latest"
      fi
    fi
  else
    # Fallback to git if no version file (pre-version-tracking install)
    local repo_path_file="$HOME/.claude/doey/repo-path"
    if [[ -f "$repo_path_file" ]]; then
      local repo_dir
      repo_dir="$(cat "$repo_path_file")"
      if [[ -d "$repo_dir" ]]; then
        local version_info
        version_info="$(git -C "$repo_dir" log -1 --format="%h (%ci)" 2>/dev/null || echo 'unknown')"
        printf "  ${DIM}Version${RESET}    ${BOLD}%s${RESET}  ${DIM}(no version file — reinstall to track)${RESET}\n" "$version_info"
      fi
    fi
  fi

  printf "  ${DIM}Agents${RESET}     ${BOLD}~/.claude/agents/${RESET}\n"
  printf "  ${DIM}Commands${RESET}   ${BOLD}~/.claude/commands/${RESET}\n"
  printf "  ${DIM}CLI${RESET}        ${BOLD}~/.local/bin/doey${RESET}\n"

  local project_count=0
  if [[ -f "$PROJECTS_FILE" ]]; then
    project_count="$(grep -c '.' "$PROJECTS_FILE" 2>/dev/null || echo 0)"
  fi
  printf "  ${DIM}Projects${RESET}   ${BOLD}%s registered${RESET}\n" "$project_count"

  printf '\n'
}

# ── Auto-update check ─────────────────────────────────────────────
check_for_updates() {
  local state_dir="$HOME/.claude/doey"
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
      printf "  ${WARN}⚠ Update available${RESET} ${DIM}(%s commit(s) behind — run: doey update)${RESET}\n" "$behind"
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

# ── Headless Launch (no banner, no attach) ────────────────────────────
# Simplified copy of launch_session() for automated/test use.
# Starts the full team (session, grid, Manager, Watchdog, workers) but
# does not print the ASCII banner, summary box, or attach to tmux.

launch_session_headless() {
  local name="$1"
  local dir="$2"
  local grid="${3:-6x2}"
  local cols="${grid%x*}"
  local rows="${grid#*x}"
  local total=$(( cols * rows ))
  local worker_count=$(( total - 2 ))
  local watchdog_pane=$cols
  local session="doey-${name}"
  local runtime_dir="/tmp/doey/${name}"

  cd "$dir"

  # ── Build worker pane list ──
  local worker_panes_csv=""
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    [[ -n "$worker_panes_csv" ]] && worker_panes_csv+=","
    worker_panes_csv+="$i"
  done

  # ── Install Doey hooks into target project ──
  install_doey_hooks "$dir" "  "

  # ── Create session ──
  printf "  ${DIM}Creating session ${session}...${RESET}\n"
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}

  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR="$dir"
PROJECT_NAME="$name"
SESSION_NAME="$session"
GRID="$grid"
TOTAL_PANES="$total"
WORKER_COUNT="$worker_count"
WATCHDOG_PANE="$watchdog_pane"
WORKER_PANES="$worker_panes_csv"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="500"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
MANIFEST

  cat > "${runtime_dir}/worker-system-prompt.md" << 'WORKER_PROMPT'
# Doey Worker

You are a **Worker** on the Doey team, coordinated by a Manager in pane 0.0. You receive tasks via this chat and execute them independently.

## Rules
1. **Absolute paths only** — Always use absolute file paths. Never use relative paths.
2. **Stay in scope** — Only make changes within the scope of your assigned task. Do not refactor, clean up, or "improve" code outside your task.
3. **Concurrent awareness** — Other workers are editing other files in this codebase simultaneously. Avoid broad sweeping changes (global renames, config modifications, formatter runs) unless your task explicitly requires it.
4. **When done, stop** — Complete your task and stop. Do not ask follow-up questions unless you are genuinely blocked. The Manager will check your output.
5. **If blocked, describe and stop** — If you encounter an unrecoverable error, describe it clearly and stop.
6. **No git commits** — Do not create git commits unless your task explicitly says to. The Manager coordinates commits.
7. **No tmux interaction** — Do not try to communicate with other panes. Just do your work.
WORKER_PROMPT

  cat >> "${runtime_dir}/worker-system-prompt.md" << WORKER_CONTEXT

## Project
- **Name:** ${name}
- **Root:** ${dir}
- **Runtime directory:** ${runtime_dir}
WORKER_CONTEXT

  tmux new-session -d -s "$session" -c "$dir"
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"

  # ── Apply theme ──
  printf "  ${DIM}Applying theme...${RESET}\n"
  tmux set-option -t "$session" pane-border-status top
  tmux set-option -t "$session" pane-border-format \
    " #{?pane_active,#[fg=cyan#,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  tmux set-option -t "$session" pane-border-style 'fg=colour238'
  tmux set-option -t "$session" pane-active-border-style 'fg=cyan'
  tmux set-option -t "$session" pane-border-lines heavy
  tmux set-option -t "$session" status-position top
  tmux set-option -t "$session" status-style 'bg=colour233,fg=colour248'
  tmux set-option -t "$session" status-left-length 50
  tmux set-option -t "$session" status-right-length 70
  tmux set-option -t "$session" status-left \
    "#[fg=colour233,bg=cyan,bold]  DOEY: ${name} #[fg=cyan,bg=colour236,nobold] #S #[fg=colour236,bg=colour233] "
  tmux set-option -t "$session" status-right \
    "#[fg=colour245] #{pane_title} #[fg=colour233,bg=colour240]  %H:%M #[fg=colour233,bg=colour245,bold] #('${SCRIPT_DIR}/tmux-statusbar.sh') "
  tmux set-option -t "$session" status-interval 2
  tmux set-option -t "$session" window-status-format '#[fg=colour245] #I #W '
  tmux set-option -t "$session" window-status-current-format '#[fg=cyan,bold] #I #W '
  tmux set-option -t "$session" message-style 'bg=colour233,fg=cyan'
  tmux set-option -t "$session" set-titles on
  tmux set-option -t "$session" set-titles-string "🤖 #{session_name} — #{pane_title}"
  tmux set-option -t "$session" mouse on
  tmux set-option -t "$session" bell-action none
  tmux set-option -t "$session" visual-bell off

  # ── Build grid ──
  printf "  ${DIM}Building ${cols}x${rows} grid (${total} panes)...${RESET}\n"
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

  # Verify pane count
  local actual
  actual=$(tmux list-panes -t "$session" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$actual" -ne "$total" ]]; then
    printf "  ${WARN}⚠ Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total" "$actual"
  fi

  # ── Name panes ──
  printf "  ${DIM}Naming panes...${RESET}\n"
  tmux select-pane -t "$session:0.0" -T "MGR Manager"
  tmux select-pane -t "$session:0.$watchdog_pane" -T "WDG Watchdog"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    wnum=$((wnum + 1))
    tmux select-pane -t "$session:0.$i" -T "W${wnum} Worker ${wnum}"
  done

  # ── Launch Manager & Watchdog ──
  printf "  ${DIM}Launching Manager & Watchdog...${RESET}\n"
  tmux send-keys -t "$session:0.0" \
    "claude --dangerously-skip-permissions --agent doey-manager" Enter
  sleep 0.5

  write_pane_status "$runtime_dir" "${session}:0.0" "READY"

  (
    sleep 8
    worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.0" \
      "Team is online (project: ${name}, dir: $dir). You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (monitors workers, delivers messages). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  tmux send-keys -t "$session:0.$watchdog_pane" \
    "claude --dangerously-skip-permissions --model haiku --agent doey-watchdog" Enter
  sleep 0.5

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
    # Schedule periodic compact to keep Watchdog context lean
    sleep 20
    tmux send-keys -t "$session:0.$watchdog_pane" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &

  # Clean up background jobs on early exit
  trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM

  # ── Boot workers ──
  printf "  ${DIM}Booting ${worker_count} workers...${RESET}\n"
  local booted=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    booted=$((booted + 1))

    local worker_prompt_file="${runtime_dir}/worker-system-prompt-${booted}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file"
    printf '\n\n## Identity\nYou are Worker %s in pane 0.%s of session %s.\n' "$booted" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus"
    worker_cmd+=" --append-system-prompt-file \"${worker_prompt_file}\""
    tmux send-keys -t "$session:0.$i" "$worker_cmd" Enter
    sleep 0.3

    write_pane_status "$runtime_dir" "${session}:0.${i}" "READY"
  done

  # Clear the trap — background briefing jobs should complete normally
  trap - EXIT INT TERM
  printf "  ${SUCCESS}Team launched${RESET} — session ${BOLD}%s${RESET} with %s workers\n" "$session" "$worker_count"
}

# ── Dynamic Grid — 2-row × N-column mode ─────────────────────────────
# Creates a minimal 2x2 grid (Manager + Watchdog) with worker columns
# added/removed on demand via `doey add` / `doey remove <col>`.

launch_session_dynamic() {
  local name="$1"
  local dir="$2"
  local session="doey-${name}"
  local runtime_dir="/tmp/doey/${name}"
  local short_dir="${dir/#$HOME/~}"
  local max_workers=20

  cd "$dir"

  # ── Banner ──────────────────────────────────────────────────────
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
  printf '   ██████╗  ██████╗ ███████╗██╗   ██╗\n'
  printf '   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝\n'
  printf '   ██║  ██║██║   ██║█████╗   ╚████╔╝ \n'
  printf '   ██║  ██║██║   ██║██╔══╝    ╚██╔╝  \n'
  printf '   ██████╔╝╚██████╔╝███████╗   ██║   \n'
  printf '   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝   \n'
  printf "${RESET}"
  printf "   ${DIM}Let Doey do it for you${RESET}\n"
  printf '\n'
  printf "   ${DIM}Project${RESET} ${BOLD}${name}${RESET}  ${DIM}Grid${RESET} ${BOLD}dynamic${RESET}  ${DIM}Workers${RESET} ${BOLD}0 (add with: doey add)${RESET}\n"
  printf "   ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}  ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  # ── Pre-accept trust for project directory ───────────────────
  local claude_settings="$HOME/.claude/settings.json"
  if command -v jq &>/dev/null; then
    if [ -f "$claude_settings" ]; then
      if ! jq -e ".trustedDirectories // [] | index(\"$dir\")" "$claude_settings" > /dev/null 2>&1; then
        jq "(.trustedDirectories // []) |= . + [\"$dir\"]" "$claude_settings" > "${claude_settings}.tmp" \
          && mv "${claude_settings}.tmp" "$claude_settings"
        printf "   ${DIM}Trusted project directory added to ~/.claude/settings.json${RESET}\n"
      fi
    else
      mkdir -p "$(dirname "$claude_settings")"
      printf '{"trustedDirectories": ["%s"]}\n' "$dir" > "$claude_settings"
      printf "   ${DIM}Created ~/.claude/settings.json with trusted directory${RESET}\n"
    fi
  else
    printf "   ${WARN}jq not found — skipping auto-trust (you may see trust prompts)${RESET}\n"
  fi

  # ── Step 1: Create session ─────────────────────────────────────
  step_start 1 "Creating session for ${name}..."
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}

  # Generate shared worker system prompt
  cat > "${runtime_dir}/worker-system-prompt.md" << 'WORKER_PROMPT'
# Doey Worker

You are a **Worker** on the Doey team, coordinated by a Manager in pane 0.0. You receive tasks via this chat and execute them independently.

## Rules
1. **Absolute paths only** — Always use absolute file paths. Never use relative paths.
2. **Stay in scope** — Only make changes within the scope of your assigned task. Do not refactor, clean up, or "improve" code outside your task.
3. **Concurrent awareness** — Other workers are editing other files in this codebase simultaneously. Avoid broad sweeping changes (global renames, config modifications, formatter runs) unless your task explicitly requires it.
4. **When done, stop** — Complete your task and stop. Do not ask follow-up questions unless you are genuinely blocked. The Manager will check your output.
5. **If blocked, describe and stop** — If you encounter an unrecoverable error, describe it clearly and stop.
6. **No git commits** — Do not create git commits unless your task explicitly says to. The Manager coordinates commits.
7. **No tmux interaction** — Do not try to communicate with other panes. Just do your work.
WORKER_PROMPT

  cat >> "${runtime_dir}/worker-system-prompt.md" << WORKER_CONTEXT

## Project
- **Name:** ${name}
- **Root:** ${dir}
- **Runtime directory:** ${runtime_dir}
WORKER_CONTEXT

  tmux new-session -d -s "$session" -c "$dir"
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"
  step_done

  # ── Step 2: Apply theme ────────────────────────────────────────
  step_start 2 "Applying theme..."

  tmux set-option -t "$session" pane-border-status top
  tmux set-option -t "$session" pane-border-format \
    ' #{?pane_active,#[fg=cyan#,bold],#[fg=colour245]}#{pane_title} #[default]'
  tmux set-option -t "$session" pane-border-style 'fg=colour238'
  tmux set-option -t "$session" pane-active-border-style 'fg=cyan'
  tmux set-option -t "$session" pane-border-lines heavy
  tmux set-option -t "$session" status-position top
  tmux set-option -t "$session" status-style 'bg=colour233,fg=colour248'
  tmux set-option -t "$session" status-left-length 50
  tmux set-option -t "$session" status-right-length 70
  tmux set-option -t "$session" status-left \
    "#[fg=colour233,bg=cyan,bold]  DOEY: ${name} #[fg=cyan,bg=colour236,nobold] #S #[fg=colour236,bg=colour233] "
  tmux set-option -t "$session" status-right \
    "#[fg=colour245] #{pane_title} #[fg=colour233,bg=colour240]  %H:%M #[fg=colour233,bg=colour245,bold] #(${SCRIPT_DIR}/tmux-statusbar.sh) "
  tmux set-option -t "$session" status-interval 5
  tmux set-option -t "$session" window-status-format '#[fg=colour245] #I #W '
  tmux set-option -t "$session" window-status-current-format '#[fg=cyan,bold] #I #W '
  tmux set-option -t "$session" message-style 'bg=colour233,fg=cyan'
  tmux set-option -t "$session" set-titles on
  tmux set-option -t "$session" set-titles-string "🤖 #{session_name} — #{pane_title}"
  tmux set-option -t "$session" -g mouse on
  tmux set-option -t "$session" bell-action none
  tmux set-option -t "$session" visual-bell off

  step_done

  # ── Step 3: Build 2x2 grid ────────────────────────────────────
  step_start 3 "Building dynamic 2x2 grid..."

  # Start: pane 0.0 = Manager top
  # split-window -h → 0.0 (MGR top), 0.1 (WDG top)
  tmux split-window -h -t "$session:0.0" -c "$dir"
  # split-window -v -t 0.0 → MGR top splits into top/bottom
  # After: 0.0 (MGR top), 0.1 (MGR bottom), 0.2 (WDG top)
  tmux split-window -v -t "$session:0.0" -c "$dir"
  # split-window -v on WDG top → 0.2 splits into top/bottom
  # After: 0.0 (MGR top), 0.1 (MGR bottom), 0.2 (WDG top), 0.3 (WDG bottom)
  tmux split-window -v -t "$session:0.2" -c "$dir"

  sleep 1

  # Read actual pane indices to be safe
  local mgr_pane=0
  local mgr_bottom_pane=1
  local watchdog_pane=2
  local wdg_bottom_pane=3

  step_done

  # ── Step 4: Name panes ─────────────────────────────────────────
  step_start 4 "Naming panes..."

  tmux select-pane -t "$session:0.${mgr_pane}" -T "MGR Manager"
  tmux select-pane -t "$session:0.${mgr_bottom_pane}" -T "MGR-B Status"
  tmux select-pane -t "$session:0.${watchdog_pane}" -T "WDG Watchdog"
  tmux select-pane -t "$session:0.${wdg_bottom_pane}" -T "WDG-B Status"

  step_done

  # ── Step 5: Write session.env ──────────────────────────────────
  step_start 5 "Writing session manifest..."

  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR=$dir
PROJECT_NAME=$name
SESSION_NAME=$session
GRID=dynamic
ROWS=2
MAX_WORKERS=$max_workers
WORKER_PANES=
WORKER_COUNT=0
WATCHDOG_PANE=$watchdog_pane
CURRENT_COLS=2
MGR_BOTTOM_PANE=$mgr_bottom_pane
WDG_BOTTOM_PANE=$wdg_bottom_pane
RUNTIME_DIR=${runtime_dir}
PASTE_SETTLE_MS=500
IDLE_COLLAPSE_AFTER=60
IDLE_REMOVE_AFTER=300
MANIFEST

  step_done

  # ── Step 6: Launch Manager & Watchdog ──────────────────────────
  step_start 6 "Launching Manager & Watchdog..."

  # Status messages in bottom panes
  tmux send-keys -t "$session:0.${mgr_bottom_pane}" \
    "echo 'Doey — Manager status pane'" Enter
  tmux send-keys -t "$session:0.${wdg_bottom_pane}" \
    "echo 'Doey — Watchdog status pane'" Enter

  # Launch Manager (pane 0.0)
  tmux send-keys -t "$session:0.0" \
    "claude --dangerously-skip-permissions --agent doey-manager" Enter
  sleep 0.5

  # Send initial briefing once Manager is ready
  (
    sleep 8
    tmux send-keys -t "$session:0.0" \
      "Team is online (project: ${name}, dir: $dir). Dynamic grid mode — no workers yet. Use 'doey add' from CLI to add worker columns (2 workers per column). Pane 0.$watchdog_pane is the Watchdog. Session: $session. Awaiting tasks — workers will be added on demand." Enter
  ) &

  # Launch Watchdog (pane 0.$watchdog_pane)
  tmux send-keys -t "$session:0.$watchdog_pane" \
    "claude --dangerously-skip-permissions --model haiku --agent doey-watchdog" Enter
  sleep 0.5

  # Auto-start watchdog loop (no workers to monitor yet)
  (
    sleep 12
    tmux send-keys -t "$session:0.$watchdog_pane" \
      "Start monitoring session $session. Dynamic grid mode — no workers yet. Skip pane 0.0 (Manager) and 0.$watchdog_pane (yourself). I'll notify you when workers are added." Enter
  ) &

  step_done

  # ── Final summary ──────────────────────────────────────────────
  printf '\n'
  printf "   ${DIM}┌─────────────────────────────────────────────────┐${RESET}\n"
  printf "   ${DIM}│${RESET}  ${SUCCESS}Doey is ready${RESET}  ${DIM}(dynamic grid)${RESET}                ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Manager${RESET}    ${DIM}0.0${RESET}   Online                      ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Watchdog${RESET}   ${DIM}0.%-3s${RESET} Online                      ${DIM}│${RESET}\n" "$watchdog_pane"
  printf "   ${DIM}│${RESET}  ${BOLD}Workers${RESET}    ${DIM}0${RESET}     ${DIM}Add with: doey add${RESET}            ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Project${RESET}   ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "$name"
  printf "   ${DIM}│${RESET}  ${DIM}Grid${RESET}      ${BOLD}dynamic${RESET}  ${DIM}Max workers${RESET}  ${BOLD}%-13s${RESET} ${DIM}│${RESET}\n" "$max_workers"
  printf "   ${DIM}│${RESET}  ${DIM}Session${RESET}   ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "$session"
  printf "   ${DIM}│${RESET}  ${DIM}Manifest${RESET}  ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "${runtime_dir}/session.env"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Tip: doey add — adds 2 workers (1 column)${RESET}      ${DIM}│${RESET}\n"
  printf "   ${DIM}└─────────────────────────────────────────────────┘${RESET}\n"
  printf '\n'

  # ── Focus on Manager pane, attach ──────────────────────────────
  tmux select-pane -t "$session:0.0"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach -t "$session"
  fi
}

# ── Add a worker column to a dynamic grid session ────────────────────
# Rebuild pane state from tmux pane titles
# Sets: _wdg_pane, _mgr_bottom, _wdg_bottom, _worker_panes
rebuild_pane_state() {
  local session="$1"
  _wdg_pane=""
  _mgr_bottom=""
  _wdg_bottom=""
  _worker_panes=""

  local pidx ptitle
  while IFS=' ' read -r pidx ptitle; do
    case "$ptitle" in
      "WDG Watchdog") _wdg_pane="$pidx" ;;
      "WDG-B"*) _wdg_bottom="$pidx" ;;
      "MGR-B"*) _mgr_bottom="$pidx" ;;
      W[0-9]*)
        [[ -n "$_worker_panes" ]] && _worker_panes+=","
        _worker_panes+="$pidx"
        ;;
    esac
  done < <(tmux list-panes -t "$session" -F '#{pane_index} #{pane_title}')
}

doey_add_column() {
  local session="$1"
  local runtime_dir="$2"
  local dir="$3"

  # Source current state
  # shellcheck disable=SC1090
  source "${runtime_dir}/session.env"

  if [[ "${GRID:-}" != "dynamic" ]]; then
    printf "  ${ERROR}Session is not using dynamic grid mode${RESET}\n"
    return 1
  fi

  local worker_count="${WORKER_COUNT:-0}"
  local max_workers="${MAX_WORKERS:-20}"
  local watchdog_pane="${WATCHDOG_PANE}"
  local current_cols="${CURRENT_COLS:-2}"
  local name="${PROJECT_NAME}"

  if (( worker_count >= max_workers )); then
    printf "  ${ERROR}Max workers reached (${max_workers})${RESET}\n"
    return 1
  fi

  printf "  ${DIM}Adding worker column...${RESET}\n"

  # Strategy: split the watchdog top pane horizontally with -b (insert before)
  # This creates a new pane to the LEFT of the watchdog, pushing it right
  tmux split-window -h -b -t "$session:0.${watchdog_pane}" -c "$dir"
  sleep 0.5

  # The new pane took the watchdog's old index; watchdog shifted right
  # Now split the new pane vertically for the bottom worker
  local new_top_pane="$watchdog_pane"
  tmux split-window -v -t "$session:0.${new_top_pane}" -c "$dir"
  sleep 0.5

  # Re-read pane list to get actual indices
  local pane_list
  pane_list="$(tmux list-panes -t "$session" -F '#{pane_index} #{pane_title}')"

  # Find the watchdog by title (it shifted)
  local new_watchdog_pane
  new_watchdog_pane="$(echo "$pane_list" | grep "WDG Watchdog" | awk '{print $1}')"
  if [[ -z "$new_watchdog_pane" ]]; then
    # Fallback: watchdog is now at a higher index after our splits
    # After split -h -b: old watchdog_pane becomes new worker, watchdog goes +1
    # After split -v: another pane inserted, watchdog goes +1 again
    new_watchdog_pane=$(( watchdog_pane + 2 ))
    printf "  ${WARN}Could not find watchdog by title, using index ${new_watchdog_pane}${RESET}\n"
  fi

  # Find the WDG bottom pane by title
  local new_wdg_bottom
  new_wdg_bottom="$(echo "$pane_list" | grep "WDG-B" | awk '{print $1}')"
  if [[ -z "$new_wdg_bottom" ]]; then
    new_wdg_bottom=$(( new_watchdog_pane + 1 ))
  fi

  # Find MGR bottom pane by title
  local new_mgr_bottom
  new_mgr_bottom="$(echo "$pane_list" | grep "MGR-B" | awk '{print $1}')"
  if [[ -z "$new_mgr_bottom" ]]; then
    new_mgr_bottom="${MGR_BOTTOM_PANE}"
  fi

  # Determine new worker numbers and pane indices
  local w1_num=$(( worker_count + 1 ))
  local w2_num=$(( worker_count + 2 ))

  # The new panes are the ones without known titles
  # After split -h -b on watchdog: new pane is at old watchdog index
  # After split -v on that: the top stays, bottom is inserted after
  # Find unnamed panes (those without MGR/WDG/Worker titles)
  local new_pane_top=""
  local new_pane_bottom=""
  while IFS=' ' read -r pidx ptitle; do
    case "$ptitle" in
      MGR*|WDG*|W[0-9]*) continue ;;
      *)
        if [[ -z "$new_pane_top" ]]; then
          new_pane_top="$pidx"
        else
          new_pane_bottom="$pidx"
        fi
        ;;
    esac
  done <<< "$pane_list"

  # If we couldn't find by title exclusion, use positional logic
  if [[ -z "$new_pane_top" ]]; then
    new_pane_top="$watchdog_pane"
    new_pane_bottom=$(( watchdog_pane + 1 ))
  fi
  if [[ -z "$new_pane_bottom" ]]; then
    new_pane_bottom=$(( new_pane_top + 1 ))
  fi

  # Name the new worker panes
  tmux select-pane -t "$session:0.${new_pane_top}" -T "W${w1_num} Worker ${w1_num}"
  tmux select-pane -t "$session:0.${new_pane_bottom}" -T "W${w2_num} Worker ${w2_num}"

  # Rebuild ALL pane indices from titles (indices shift after splits)
  rebuild_pane_state "$session"
  local new_worker_panes="$_worker_panes"
  new_watchdog_pane="$_wdg_pane"
  new_mgr_bottom="$_mgr_bottom"
  new_wdg_bottom="$_wdg_bottom"

  local new_worker_count=$(( worker_count + 2 ))
  local new_cols=$(( current_cols + 1 ))

  # Rewrite session.env BEFORE launching Claude (hooks read it during boot)
  cat > "${runtime_dir}/session.env.tmp" << MANIFEST
PROJECT_DIR=$dir
PROJECT_NAME=$name
SESSION_NAME=$session
GRID=dynamic
ROWS=2
MAX_WORKERS=$max_workers
WORKER_PANES=$new_worker_panes
WORKER_COUNT=$new_worker_count
WATCHDOG_PANE=${new_watchdog_pane:-$watchdog_pane}
CURRENT_COLS=$new_cols
MGR_BOTTOM_PANE=${new_mgr_bottom:-$MGR_BOTTOM_PANE}
WDG_BOTTOM_PANE=${new_wdg_bottom:-$WDG_BOTTOM_PANE}
RUNTIME_DIR=${runtime_dir}
PASTE_SETTLE_MS=500
IDLE_COLLAPSE_AFTER=60
IDLE_REMOVE_AFTER=300
MANIFEST
  mv "${runtime_dir}/session.env.tmp" "${runtime_dir}/session.env"

  # Launch Claude in both new panes
  local worker_prompt_file_1="${runtime_dir}/worker-system-prompt-${w1_num}.md"
  cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file_1"
  printf '\n\n## Identity\nYou are Worker %s in pane 0.%s of session %s.\n' \
    "$w1_num" "$new_pane_top" "$session" >> "$worker_prompt_file_1"

  local worker_cmd="claude --dangerously-skip-permissions --model opus"
  worker_cmd+=" --append-system-prompt-file ${worker_prompt_file_1}"
  tmux send-keys -t "$session:0.${new_pane_top}" "$worker_cmd" Enter
  sleep 0.3

  local worker_prompt_file_2="${runtime_dir}/worker-system-prompt-${w2_num}.md"
  cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file_2"
  printf '\n\n## Identity\nYou are Worker %s in pane 0.%s of session %s.\n' \
    "$w2_num" "$new_pane_bottom" "$session" >> "$worker_prompt_file_2"

  local worker_cmd2="claude --dangerously-skip-permissions --model opus"
  worker_cmd2+=" --append-system-prompt-file ${worker_prompt_file_2}"
  tmux send-keys -t "$session:0.${new_pane_bottom}" "$worker_cmd2" Enter

  # Rebalance layout
  tmux select-layout -t "$session:0" even-horizontal 2>/dev/null || true

  printf "  ${SUCCESS}Added${RESET} workers ${BOLD}W${w1_num}${RESET} (0.${new_pane_top}) and ${BOLD}W${w2_num}${RESET} (0.${new_pane_bottom})\n"
  printf "  ${DIM}Total workers: ${new_worker_count} in ${new_cols} columns${RESET}\n"
}

# ── Remove a worker column from a dynamic grid session ───────────────
doey_remove_column() {
  local session="$1"
  local runtime_dir="$2"
  local col_index="${3:-}"

  # Source current state
  # shellcheck disable=SC1090
  source "${runtime_dir}/session.env"

  if [[ "${GRID:-}" != "dynamic" ]]; then
    printf "  ${ERROR}Session is not using dynamic grid mode${RESET}\n"
    return 1
  fi

  local worker_count="${WORKER_COUNT:-0}"
  local current_cols="${CURRENT_COLS:-2}"
  local name="${PROJECT_NAME}"
  local dir="${PROJECT_DIR}"

  if (( worker_count == 0 )); then
    printf "  ${ERROR}No worker columns to remove${RESET}\n"
    return 1
  fi

  # If no column specified, remove the last worker column
  # Worker columns are between col 0 (MGR) and the last col (WDG)
  # The last worker column contains the two highest-indexed worker panes
  if [[ -z "$col_index" ]]; then
    col_index="last"
  fi

  # Find worker panes to remove
  # Workers are listed in WORKER_PANES as comma-separated indices
  # Each column has 2 workers (top + bottom), added as consecutive pairs
  local -a wp_array
  IFS=',' read -ra wp_array <<< "${WORKER_PANES}"

  if [[ ${#wp_array[@]} -lt 2 ]]; then
    printf "  ${ERROR}Not enough worker panes to remove a column${RESET}\n"
    return 1
  fi

  # Determine which 2 panes to remove
  local remove_top remove_bottom
  if [[ "$col_index" == "last" ]]; then
    # Remove the last two entries (last column added)
    remove_top="${wp_array[$(( ${#wp_array[@]} - 2 ))]}"
    remove_bottom="${wp_array[$(( ${#wp_array[@]} - 1 ))]}"
  else
    # Remove specific column by position (1-indexed among worker columns)
    local ci=$(( col_index ))
    if (( ci < 1 || ci > worker_count / 2 )); then
      printf "  ${ERROR}Invalid worker column: ${col_index} (valid: 1-$(( worker_count / 2 )))${RESET}\n"
      return 1
    fi
    local pair_start=$(( (ci - 1) * 2 ))
    remove_top="${wp_array[$pair_start]}"
    remove_bottom="${wp_array[$(( pair_start + 1 ))]}"
  fi

  printf "  ${DIM}Removing worker panes 0.${remove_top} and 0.${remove_bottom}...${RESET}\n"

  # Kill Claude processes in the target panes
  for pane_idx in "$remove_top" "$remove_bottom"; do
    local pane_pid
    pane_pid=$(tmux display-message -t "$session:0.${pane_idx}" -p '#{pane_pid}' 2>/dev/null || true)
    [[ -n "$pane_pid" ]] && pkill -P "$pane_pid" 2>/dev/null || true
  done
  sleep 1

  # Kill the panes (kill higher index first to avoid index shift issues)
  local first_kill second_kill
  if (( remove_top > remove_bottom )); then
    first_kill="$remove_top"
    second_kill="$remove_bottom"
  else
    first_kill="$remove_bottom"
    second_kill="$remove_top"
  fi
  tmux kill-pane -t "$session:0.${first_kill}" 2>/dev/null || true
  tmux kill-pane -t "$session:0.${second_kill}" 2>/dev/null || true
  sleep 0.5

  # After killing panes, ALL indices shift — must re-read everything
  rebuild_pane_state "$session"
  local new_watchdog_pane="$_wdg_pane"
  local new_mgr_bottom="$_mgr_bottom"
  local new_wdg_bottom="$_wdg_bottom"
  local new_worker_panes="$_worker_panes"

  local new_worker_count=$(( worker_count - 2 ))
  local new_cols=$(( current_cols - 1 ))

  # Rewrite session.env (atomic via tmp+mv)
  cat > "${runtime_dir}/session.env.tmp" << MANIFEST
PROJECT_DIR=$dir
PROJECT_NAME=$name
SESSION_NAME=$session
GRID=dynamic
ROWS=2
MAX_WORKERS=${MAX_WORKERS:-20}
WORKER_PANES=$new_worker_panes
WORKER_COUNT=$new_worker_count
WATCHDOG_PANE=${new_watchdog_pane:-$WATCHDOG_PANE}
CURRENT_COLS=$new_cols
MGR_BOTTOM_PANE=${new_mgr_bottom:-$MGR_BOTTOM_PANE}
WDG_BOTTOM_PANE=${new_wdg_bottom:-$WDG_BOTTOM_PANE}
RUNTIME_DIR=${runtime_dir}
PASTE_SETTLE_MS=500
IDLE_COLLAPSE_AFTER=60
IDLE_REMOVE_AFTER=300
MANIFEST
  mv "${runtime_dir}/session.env.tmp" "${runtime_dir}/session.env"

  # Rebalance layout
  tmux select-layout -t "$session:0" even-horizontal 2>/dev/null || true

  printf "  ${SUCCESS}Removed${RESET} worker column — ${BOLD}${new_worker_count}${RESET} workers remaining\n"
}

# ── E2E Test Runner ───────────────────────────────────────────────────

run_test() {
  local keep=false
  local open=false
  local grid="3x2"

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) keep=true; shift ;;
      --open) open=true; shift ;;
      --grid) grid="$2"; shift 2 ;;
      [0-9]*x[0-9]*) grid="$1"; shift ;;
      *)
        printf "  ${ERROR}Unknown test flag: %s${RESET}\n" "$1"
        return 1
        ;;
    esac
  done

  local test_id="e2e-test-$(date +%s)"
  local test_root="/tmp/doey-test/${test_id}"
  local project_dir="${test_root}/project"
  local report_file="${test_root}/report.md"

  printf '\n'
  printf "  ${BRAND}Doey — E2E Test${RESET}\n"
  printf '\n'
  printf "  ${DIM}Test ID${RESET}    ${BOLD}${test_id}${RESET}\n"
  printf "  ${DIM}Grid${RESET}       ${BOLD}${grid}${RESET}\n"
  printf "  ${DIM}Sandbox${RESET}    ${BOLD}${project_dir}${RESET}\n"
  printf "  ${DIM}Report${RESET}     ${BOLD}${report_file}${RESET}\n"
  printf '\n'

  # ── Step 1: Create sandbox project ──
  printf "  ${DIM}[1/6]${RESET} Creating sandbox project...\n"
  mkdir -p "${project_dir}/.claude/hooks"
  cd "$project_dir"
  git init -q
  printf '# E2E Test Sandbox\n\nThis project was created by `doey test` for automated testing.\n' > README.md
  printf 'E2E Test Sandbox - build whatever is requested\n' > CLAUDE.md

  # Copy hooks and settings from the repo
  install_doey_hooks "$project_dir" "  "

  git add -A
  git commit -q -m "Initial sandbox commit"
  printf "  ${SUCCESS}Sandbox created${RESET}\n"

  # ── Step 2: Register sandbox ──
  printf "  ${DIM}[2/6]${RESET} Registering sandbox...\n"
  local last8="${test_id: -8}"
  local test_project_name="e2e-test-${last8}"
  echo "${test_project_name}:${project_dir}" >> "$PROJECTS_FILE"
  local session="doey-${test_project_name}"
  printf "  ${SUCCESS}Registered${RESET} ${BOLD}${test_project_name}${RESET}\n"

  # ── Step 3: Launch team ──
  printf "  ${DIM}[3/6]${RESET} Launching team...\n"
  launch_session_headless "$test_project_name" "$project_dir" "$grid"

  # ── Step 4: Wait for boot ──
  printf "  ${DIM}[4/6]${RESET} Waiting for boot (30s)...\n"
  sleep 30
  printf "  ${SUCCESS}Boot complete${RESET}\n"

  # ── Step 5: Launch test driver ──
  printf "  ${DIM}[5/6]${RESET} Launching test driver...\n"
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  local journey_file="${repo_dir}/tests/e2e/journey.md"
  if [[ ! -f "$journey_file" ]]; then
    printf "  ${ERROR}Journey file not found: %s${RESET}\n" "$journey_file"
    return 1
  fi
  mkdir -p "${test_root}/observations"

  printf "  ${DIM}Watch live:${RESET} tmux attach -t ${session}\n"
  printf '\n'

  claude --dangerously-skip-permissions --agent test-driver --model opus \
    "Run the E2E test. Session: ${session}. Project name: ${test_project_name}. Project dir: ${project_dir}. Runtime dir: /tmp/doey/${test_project_name}. Journey file: ${journey_file}. Observations dir: ${test_root}/observations. Report file: ${report_file}. Test ID: ${test_id}"

  # ── Step 6: Display results ──
  printf '\n'
  printf "  ${DIM}[6/6]${RESET} Results\n"
  if [[ -f "$report_file" ]]; then
    if grep -q "Result: PASS" "$report_file" 2>/dev/null; then
      printf '\n'
      printf "  ${SUCCESS}╔═══════════════════════════════════╗${RESET}\n"
      printf "  ${SUCCESS}║            TEST PASSED            ║${RESET}\n"
      printf "  ${SUCCESS}╚═══════════════════════════════════╝${RESET}\n"
      printf '\n'
    else
      printf '\n'
      printf "  ${ERROR}╔═══════════════════════════════════╗${RESET}\n"
      printf "  ${ERROR}║            TEST FAILED            ║${RESET}\n"
      printf "  ${ERROR}╚═══════════════════════════════════╝${RESET}\n"
      printf '\n'
    fi
    printf "  ${DIM}Report:${RESET} ${BOLD}${report_file}${RESET}\n"
  else
    printf "  ${WARN}No report generated${RESET}\n"
  fi

  # ── Open if requested ──
  if [[ "$open" == true ]]; then
    open "${project_dir}/index.html" 2>/dev/null || true
  fi

  # ── Cleanup or keep ──
  if [[ "$keep" == false ]]; then
    printf "  ${DIM}Cleaning up...${RESET}\n"
    tmux kill-session -t "$session" 2>/dev/null || true
    grep -v "^${test_project_name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
    rm -rf "$test_root"
    printf "  ${SUCCESS}Cleaned up${RESET}\n"
  else
    printf '\n'
    printf "  ${BOLD}Kept for inspection:${RESET}\n"
    printf "    ${DIM}Session${RESET}   tmux attach -t ${session}\n"
    printf "    ${DIM}Sandbox${RESET}   ${project_dir}\n"
    printf "    ${DIM}Runtime${RESET}   /tmp/doey/${test_project_name}\n"
    printf "    ${DIM}Report${RESET}    ${report_file}\n"
    printf '\n'
  fi
}

# ── Resolve current project's running session, or exit with error ─────
# Sets: dir, name, session, runtime_dir
require_running_session() {
  dir="$(pwd)"
  name="$(find_project "$dir")"
  [[ -z "$name" ]] && { printf "  ${ERROR}No project registered for $(pwd)${RESET}\n"; exit 1; }
  session="doey-${name}"
  session_exists "$session" || { printf "  ${ERROR}Session ${session} not running${RESET}\n"; exit 1; }
  runtime_dir="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
}

# ── Main Dispatch ─────────────────────────────────────────────────────

grid=""

case "${1:-}" in
  --help|-h)
    printf '\n'
    printf "  ${BRAND}Doey${RESET}\n"
    printf '\n'
    cat << 'HELP'
  Usage: doey [command] [grid]

  Commands:
    (none)     Smart launch — auto-attach or show project picker
    init       Register current directory as a project
    list       Show all registered projects and their status
    stop       Stop the session for the current project
    update     Pull latest changes and reinstall (alias: reinstall)
    doctor     Check installation health and prerequisites
    remove     Unregister a project (by name) or worker column (by number)
    uninstall  Remove all Doey files (keeps git repo and agent-memory)
    test       Run E2E integration test (--keep, --open, --grid NxM)
    collapse   Collapse a column to minimal width (e.g., doey collapse 2)
    expand     Expand a collapsed column back to fair width
    dynamic    Launch with dynamic grid (add workers on demand)
    add        Add a worker column (2 workers) to a dynamic grid session
    version    Show version and installation info
    --help     Show this help

  Grid:
    NxM        Grid layout (e.g., 6x2, 4x3, 3x2)
    dynamic|d  Dynamic grid — start minimal, add workers with 'doey add'
               Only used when launching a new session

  Examples:
    doey              # smart launch
    doey init         # register current dir
    doey 4x3          # launch with 4x3 grid
    doey dynamic      # launch with dynamic grid
    doey add          # add 2 workers to dynamic session
    doey remove 2     # remove worker column 2 from dynamic session
    doey list         # show all projects
    doey stop         # stop current project session
    doey update       # pull latest + reinstall
    doey doctor       # check system health
    doey remove myapp # unregister a project
    doey uninstall    # remove all installed files
    doey version      # show install info
HELP
    printf '\n'
    exit 0
    ;;
  init)
    register_project "$(pwd)"
    dir="$(pwd)"
    name="$(find_project "$dir")"
    if [[ -n "$name" ]]; then
      if [[ "${grid}" == "dynamic" || "${grid}" == "d" ]]; then
        launch_session_dynamic "$name" "$dir"
      else
        launch_session "$name" "$dir" "${grid:-6x2}"
      fi
    fi
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
  uninstall)
    uninstall_system
    exit 0
    ;;
  test)
    shift
    run_test "$@"
    exit $?
    ;;
  version|--version|-v)
    show_version
    exit 0
    ;;
  dynamic|d)
    # Launch with dynamic grid mode
    register_project "$(pwd)"
    dir="$(pwd)"
    name="$(find_project "$dir")"
    if [[ -n "$name" ]]; then
      session="doey-${name}"
      if session_exists "$session"; then
        printf "  ${SUCCESS}Attaching to${RESET} ${BOLD}${session}${RESET}...\n"
        if [[ -n "${TMUX:-}" ]]; then
          tmux switch-client -t "$session"
        else
          tmux attach -t "$session"
        fi
      else
        launch_session_dynamic "$name" "$dir"
      fi
    fi
    exit 0
    ;;
  add)
    require_running_session
    doey_add_column "$session" "$runtime_dir" "$dir"
    exit 0
    ;;
  remove)
    # If arg looks like a number, treat as column removal; otherwise project removal
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
      require_running_session
      doey_remove_column "$session" "$runtime_dir" "$2"
      exit 0
    elif [[ -z "${2:-}" ]]; then
      # No arg: if dynamic session running, remove last column; else project removal
      dir="$(pwd)"
      name="$(find_project "$dir")"
      if [[ -n "$name" ]]; then
        session="doey-${name}"
        if session_exists "$session"; then
          runtime_dir="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
          # shellcheck disable=SC1090
          source "${runtime_dir}/session.env"
          if [[ "${GRID:-}" == "dynamic" ]]; then
            doey_remove_column "$session" "$runtime_dir"
            exit 0
          fi
        fi
      fi
      # Fall through to project removal
      remove_project "${2:-}"
      exit 0
    else
      remove_project "${2:-}"
      exit 0
    fi
    ;;
  collapse)
    col="${2:?Usage: doey collapse <column>}"
    require_running_session
    # shellcheck disable=SC1090
    source "${runtime_dir}/session.env"
    if [[ "$GRID" == "dynamic" ]]; then
      cols="${CURRENT_COLS}"
    else
      cols="${GRID%x*}"
    fi
    collapse_column "$session" "$col" "$runtime_dir"
    rebalance_columns "$session" "$cols" "$runtime_dir"
    exit 0
    ;;
  expand)
    col="${2:?Usage: doey expand <column>}"
    require_running_session
    # shellcheck disable=SC1090
    source "${runtime_dir}/session.env"
    if [[ "$GRID" == "dynamic" ]]; then
      cols="${CURRENT_COLS}"
    else
      cols="${GRID%x*}"
    fi
    expand_column "$session" "$col" 80 "$runtime_dir"  # temporary width, rebalance corrects it
    rebalance_columns "$session" "$cols" "$runtime_dir"
    exit 0
    ;;
  [0-9]*x[0-9]*)
    grid="$1"
    ;;
  "")
    # No args — fall through to smart launch
    ;;
  # Note: 'dynamic' and 'd' are handled explicitly above, not here
  *)
    printf "  ${ERROR}Unknown command: %s${RESET}\n" "$1"
    printf "  Run ${BOLD}doey --help${RESET} for usage\n"
    exit 1
    ;;
esac

# ── Smart Launch ──────────────────────────────────────────────────────

check_for_updates

dir="$(pwd)"
name="$(find_project "$dir")"

if [[ -n "$name" ]]; then
  # Known project
  session="doey-${name}"
  if session_exists "$session"; then
    # Already running — just attach
    printf "  ${SUCCESS}Attaching to${RESET} ${BOLD}%s${RESET}...\n" "$session"
    if [[ -n "${TMUX:-}" ]]; then
      tmux switch-client -t "$session"
    else
      tmux attach -t "$session"
    fi
  else
    # Known but not running — launch with premium UI
    if [[ "${grid}" == "dynamic" || "${grid}" == "d" ]]; then
      launch_session_dynamic "$name" "$dir"
    else
      launch_session "$name" "$dir" "${grid:-6x2}"
    fi
  fi
else
  # Unknown directory — show interactive menu
  show_menu "${grid:-6x2}"
fi
