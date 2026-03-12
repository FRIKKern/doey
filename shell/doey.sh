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
      printf "  Stopping doey session: ${BOLD}${current_session}${RESET}...\n"
      _kill_doey_session "$current_session"
      printf "  ${SUCCESS}Stopped${RESET} ${current_session}\n"
      return 0
    fi
  fi

  # 2) If pwd matches a registered project, stop that
  local name
  name="$(find_project "$(pwd)")"
  if [[ -n "$name" ]]; then
    local session="doey-${name}"
    if session_exists "$session"; then
      printf "  Stopping doey session: ${BOLD}${session}${RESET}...\n"
      _kill_doey_session "$session"
      printf "  ${SUCCESS}Stopped${RESET} ${session}\n"
    else
      printf "  ${DIM}No active session for ${name}${RESET}\n"
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
    [[ -n "$pane_pid" ]] && pkill -P "$pane_pid" 2>/dev/null || true
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
  printf "  ${WARN}No project registered for $(pwd)${RESET}\n"
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
PASTE_SETTLE_MS=500
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
    " #{?pane_active,#[fg=cyan#,bold],#[fg=colour245]}#(${SCRIPT_DIR}/pane-border-status.sh #{session_name}:#{window_index}.#{pane_index}) #[default]"
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
    "#[fg=colour245] #{pane_title} #[fg=colour233,bg=colour240]  %H:%M #[fg=colour233,bg=colour245,bold] #(${SCRIPT_DIR}/tmux-statusbar.sh) "
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

  # Suppress terminal bell from worker panes — prevents notification spam
  # Our on-stop.sh hook handles Manager-only notifications via osascript
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
    "claude --dangerously-skip-permissions --agent doey-manager" Enter
  sleep 0.5

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
      "Team is online (project: ${name}, dir: $dir). You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (auto-accepts prompts). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
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

    # Create per-worker system prompt file (base prompt + worker identity)
    local worker_prompt_file="${runtime_dir}/worker-system-prompt-${booted}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file"
    printf '\n\n## Identity\nYou are Worker %s in pane 0.%s of session %s.\n' "$booted" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus"
    worker_cmd+=" --append-system-prompt-file ${worker_prompt_file}"
    tmux send-keys -t "$session:0.$i" "$worker_cmd" Enter
    sleep 0.3
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

  if [[ ! -f "$repo_path_file" ]]; then
    printf "  ${ERROR}Could not find the doey repo.${RESET}\n"
    printf "  Run ${BOLD}./install.sh${RESET} from the repo to register its location.\n"
    exit 1
  fi

  repo_dir="$(cat "$repo_path_file")"
  if [[ ! -d "$repo_dir" ]]; then
    printf "  ${ERROR}Could not find the doey repo.${RESET}\n"
    printf "  Run ${BOLD}./install.sh${RESET} from the repo to register its location.\n"
    exit 1
  fi

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
      printf "  ${SUCCESS}✓${RESET} Repo registered  ${DIM}${repo_dir}${RESET}\n"
    else
      printf "  ${ERROR}✗${RESET} Repo path registered but directory missing  ${DIM}${repo_dir}${RESET}\n"
    fi
  else
    printf "  ${ERROR}✗${RESET} Repo path not registered  ${DIM}~/.claude/doey/repo-path missing${RESET}\n"
  fi

  # Version tracking
  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    local ver vdate
    ver="$(grep "^version=" "$version_file" | cut -d= -f2)"
    vdate="$(grep "^date=" "$version_file" | cut -d= -f2)"
    printf "  ${SUCCESS}✓${RESET} Version tracked  ${DIM}${ver} (${vdate})${RESET}\n"
  else
    printf "  ${WARN}⚠${RESET} No version file  ${DIM}Run 'doey update' to generate${RESET}\n"
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
    printf "  Usage: ${BOLD}doey remove <name>${RESET}\n"
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
  if session_exists "doey-${name}"; then
    printf "  ${WARN}Session doey-${name} is still running. Use 'doey stop' in that directory to stop it.${RESET}\n"
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
    printf "  ${DIM}Version${RESET}    ${BOLD}${ver}${RESET}  ${DIM}(installed ${installed_date})${RESET}\n"
    if [[ -n "$repo_dir" ]] && [[ -d "$repo_dir" ]]; then
      local latest
      latest="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo '')"
      if [[ -n "$latest" ]] && [[ "$latest" != "$ver" ]]; then
        printf "  ${DIM}Update${RESET}     ${WARN}${latest} available${RESET}  ${DIM}(run 'doey update')${RESET}\n"
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
        printf "  ${DIM}Version${RESET}    ${BOLD}${version_info}${RESET}  ${DIM}(no version file — reinstall to track)${RESET}\n"
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
  printf "  ${DIM}Projects${RESET}   ${BOLD}${project_count} registered${RESET}\n"

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

  # ── Create session ──
  printf "  ${DIM}Creating session ${session}...${RESET}\n"
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}

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
PASTE_SETTLE_MS=500
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
    " #{?pane_active,#[fg=cyan#,bold],#[fg=colour245]}#(${SCRIPT_DIR}/pane-border-status.sh #{session_name}:#{window_index}.#{pane_index}) #[default]"
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

  # ── Name panes ──
  printf "  ${DIM}Naming panes...${RESET}\n"
  tmux select-pane -t "$session:0.0" -T "MGR Manager"
  tmux select-pane -t "$session:0.$watchdog_pane" -T "WDG Watchdog"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    (( wnum++ ))
    tmux select-pane -t "$session:0.$i" -T "W${wnum} Worker ${wnum}"
  done

  # ── Launch Manager & Watchdog ──
  printf "  ${DIM}Launching Manager & Watchdog...${RESET}\n"
  tmux send-keys -t "$session:0.0" \
    "claude --dangerously-skip-permissions --agent doey-manager" Enter
  sleep 0.5

  (
    sleep 8
    worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.0" \
      "Team is online (project: ${name}, dir: $dir). You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (auto-accepts prompts). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
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
  ) &

  # ── Boot workers ──
  printf "  ${DIM}Booting ${worker_count} workers...${RESET}\n"
  local booted=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    (( booted++ ))

    local worker_prompt_file="${runtime_dir}/worker-system-prompt-${booted}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file"
    printf '\n\n## Identity\nYou are Worker %s in pane 0.%s of session %s.\n' "$booted" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus"
    worker_cmd+=" --append-system-prompt-file ${worker_prompt_file}"
    tmux send-keys -t "$session:0.$i" "$worker_cmd" Enter
    sleep 0.3
  done

  printf "  ${SUCCESS}Team launched${RESET} — session ${BOLD}${session}${RESET} with ${worker_count} workers\n"
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
        printf "  ${ERROR}Unknown test flag: $1${RESET}\n"
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
  local repo_dir
  repo_dir="$(cat "$HOME/.claude/doey/repo-path")"
  # Copy all hook scripts
  for hook_file in "${repo_dir}"/.claude/hooks/*.sh; do
    [ -f "$hook_file" ] && cp "$hook_file" "${project_dir}/.claude/hooks/$(basename "$hook_file")"
  done
  cp "${repo_dir}/.claude/settings.local.json" "${project_dir}/.claude/settings.local.json"

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
  local journey_file="${repo_dir}/tests/e2e/journey.md"
  if [[ ! -f "$journey_file" ]]; then
    printf "  ${ERROR}Journey file not found: ${journey_file}${RESET}\n"
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
    sed -i '' "/^${test_project_name}:/d" "$PROJECTS_FILE"
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
    remove     Unregister a project (by name, or current dir)
    uninstall  Remove all Doey files (keeps git repo and agent-memory)
    test       Run E2E integration test (--keep, --open, --grid NxM)
    version    Show version and installation info
    --help     Show this help

  Grid:
    NxM        Grid layout (e.g., 6x2, 4x3, 3x2)
               Only used when launching a new session

  Examples:
    doey              # smart launch
    doey init         # register current dir
    doey 4x3          # launch with 4x3 grid
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
      launch_session "$name" "$dir" "${grid:-6x2}"
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
  remove)
    remove_project "${2:-}"
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
  [0-9]*x[0-9]*)
    grid="$1"
    ;;
  "")
    # No args — fall through to smart launch
    ;;
  *)
    printf "  ${ERROR}Unknown command: $1${RESET}\n"
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
    printf "  ${SUCCESS}Attaching to${RESET} ${BOLD}${session}${RESET}...\n"
    if [[ -n "${TMUX:-}" ]]; then
      tmux switch-client -t "$session"
    else
      tmux attach -t "$session"
    fi
  else
    # Known but not running — launch with premium UI
    launch_session "$name" "$dir" "${grid:-6x2}"
  fi
else
  # Unknown directory — show interactive menu
  show_menu "${grid:-6x2}"
fi
