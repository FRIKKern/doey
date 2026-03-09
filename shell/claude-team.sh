#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# claude-team — Launch a TMUX Claude Team session
#
# Usage:
#   claude-team              # 6x2 grid (12 panes) in current directory
#   claude-team 4x3          # 4x3 grid (12 panes)
#   claude-team 8x1          # 8x1 grid (8 panes)
#
# Environment:
#   CLAUDE_TEAM_DIR   — Working directory (default: $PWD)
#   CLAUDE_TEAM_NAME  — tmux session name (default: "claude-team")
#
# Alias suggestion:
#   alias ct="claude-team"
# ──────────────────────────────────────────────────────────────────────

claude-team() {
  # ── Color palette ─────────────────────────────────────────────────
  local BRAND='\033[1;36m'    # Bold cyan
  local SUCCESS='\033[0;32m'  # Green
  local INFO='\033[0;34m'     # Blue
  local DIM='\033[0;90m'      # Gray
  local WARN='\033[0;33m'     # Yellow
  local ERROR='\033[0;31m'    # Red
  local BOLD='\033[1m'        # Bold
  local RESET='\033[0m'       # Reset

  # ── Parse arguments ───────────────────────────────────────────────
  local dir="${CLAUDE_TEAM_DIR:-$PWD}"
  local grid="${1:-6x2}"
  local cols="${grid%x*}"
  local rows="${grid#*x}"
  local total=$(( cols * rows ))
  local worker_count=$(( total - 2 ))
  local watchdog_pane=$cols
  local session="${CLAUDE_TEAM_NAME:-claude-team}"
  local short_dir="${dir/#$HOME/~}"

  cd "$dir"

  # ── Banner ────────────────────────────────────────────────────────
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
  printf "   ${DIM}Grid${RESET} ${BOLD}${grid}${RESET}  ${DIM}Workers${RESET} ${BOLD}${worker_count}${RESET}  ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}\n"
  printf "   ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  # ── Helper: step printer ──────────────────────────────────────────
  local step_total=6
  _step_start() {
    local n="$1"; local label="$2"
    printf "   ${DIM}[${n}/${step_total}]${RESET} %-40s" "$label"
  }
  _step_done() {
    printf "${SUCCESS}done${RESET}\n"
  }
  _step_fail() {
    printf "${ERROR}fail${RESET}\n"
  }

  # ── Build worker pane list (needed for manifest and briefings) ────
  local worker_panes_csv=""
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    [[ -n "$worker_panes_csv" ]] && worker_panes_csv+=","
    worker_panes_csv+="$i"
  done

  # ── Step 1: Create session ────────────────────────────────────────
  _step_start 1 "Creating session for $(basename "$dir")..."
  tmux kill-session -t "$session" 2>/dev/null
  rm -rf /tmp/claude-team
  mkdir -p /tmp/claude-team/{messages,broadcasts,status}

  # Write session manifest — readable by Manager, Watchdog, and all skills/commands
  cat > /tmp/claude-team/session.env << MANIFEST
PROJECT_DIR=$dir
PROJECT_NAME=$(basename "$dir")
SESSION_NAME=$session
GRID=$grid
TOTAL_PANES=$total
WORKER_COUNT=$worker_count
WATCHDOG_PANE=$watchdog_pane
WORKER_PANES=$worker_panes_csv
MANIFEST

  tmux new-session -d -s "$session" -c "$dir"
  _step_done

  # ── Step 2: Apply theme ───────────────────────────────────────────
  _step_start 2 "Applying theme..."

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
    '#[fg=colour233,bg=cyan,bold]  CLAUDE TEAM #[fg=cyan,bg=colour236,nobold] #S #[fg=colour236,bg=colour233] '
  tmux set-option -t "$session" status-right \
    '#[fg=colour245] #{pane_title} #[fg=colour233,bg=colour240]  %H:%M #[fg=colour233,bg=colour245,bold] '"${worker_count}"' workers '
  tmux set-option -t "$session" status-interval 5

  # Window status styling
  tmux set-option -t "$session" window-status-format '#[fg=colour245] #I #W '
  tmux set-option -t "$session" window-status-current-format '#[fg=cyan,bold] #I #W '
  tmux set-option -t "$session" message-style 'bg=colour233,fg=cyan'

  _step_done

  # ── Step 3: Build grid ────────────────────────────────────────────
  _step_start 3 "Building ${cols}x${rows} grid (${total} panes)..."

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
  _step_done

  # ── Step 4: Name panes ───────────────────────────────────────────
  _step_start 4 "Naming panes..."

  tmux select-pane -t "$session:0.0" -T "MGR Manager"
  tmux select-pane -t "$session:0.$watchdog_pane" -T "WDG Watchdog"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    (( wnum++ ))
    tmux select-pane -t "$session:0.$i" -T "W${wnum} Worker ${wnum}"
  done

  _step_done

  # ── Step 5: Launch Manager & Watchdog ─────────────────────────────
  _step_start 5 "Launching Manager & Watchdog..."

  # Launch Manager (pane 0.0)
  tmux send-keys -t "$session:0.0" \
    "claude --dangerously-skip-permissions --agent tmux-manager" Enter
  sleep 0.5

  # Auto-send initial briefing once Manager is ready
  (
    sleep 10
    local worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.0" \
      "Team is online (project: $(basename "$dir"), dir: $dir). You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (auto-accepts prompts). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Launch Watchdog (pane 0.$watchdog_pane)
  tmux send-keys -t "$session:0.$watchdog_pane" \
    "claude --dangerously-skip-permissions --agent tmux-watchdog" Enter
  sleep 0.5

  # Auto-start the watchdog loop
  (
    sleep 12
    local watch_panes=""
    for (( i=1; i<total; i++ )); do
      [[ $i -eq $watchdog_pane ]] && continue
      [[ -n "$watch_panes" ]] && watch_panes+=", "
      watch_panes+="0.$i"
    done
    tmux send-keys -t "$session:0.$watchdog_pane" \
      "Start monitoring session $session. Total panes: $total. Skip pane 0.0 (Manager) and 0.$watchdog_pane (yourself). Monitor panes ${watch_panes}." Enter
  ) &

  _step_done

  # ── Step 6: Boot workers ──────────────────────────────────────────
  _step_start 6 "Booting ${worker_count} workers..."
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
    printf "\r   ${DIM}[6/${step_total}]${RESET} Booting workers  ${BRAND}${bar}${RESET}  ${BOLD}${booted}${RESET}${DIM}/${worker_count}${RESET}  "

    tmux send-keys -t "$session:0.$i" \
      "claude --dangerously-skip-permissions" Enter
    sleep 0.3
  done
  printf "${SUCCESS}done${RESET}\n"

  # ── Final summary ─────────────────────────────────────────────────
  printf '\n'
  local project_name
  project_name="$(basename "$dir")"

  printf "   ${DIM}┌─────────────────────────────────────────────┐${RESET}\n"
  printf "   ${DIM}│${RESET}  ${SUCCESS}Claude Team is ready${RESET}                       ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                             ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Manager${RESET}    ${DIM}0.0${RESET}   Online                  ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Watchdog${RESET}   ${DIM}0.%-3s${RESET} Online                  ${DIM}│${RESET}\n" "$watchdog_pane"
  printf "   ${DIM}│${RESET}  ${BOLD}Workers${RESET}    ${DIM}%-4s${RESET}  Booting...               ${DIM}│${RESET}\n" "$worker_count"
  printf "   ${DIM}│${RESET}                                             ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Project${RESET}  ${BOLD}%-35s${RESET} ${DIM}│${RESET}\n" "$project_name"
  printf "   ${DIM}│${RESET}  ${DIM}Grid${RESET}  ${BOLD}%-5s${RESET} ${DIM}Directory${RESET}  ${BOLD}%-16s${RESET} ${DIM}│${RESET}\n" "$grid" "$short_dir"
  printf "   ${DIM}│${RESET}  ${DIM}Session${RESET}  ${BOLD}%-35s${RESET} ${DIM}│${RESET}\n" "$session"
  printf "   ${DIM}│${RESET}  ${DIM}Manifest${RESET} ${BOLD}/tmp/claude-team/session.env${RESET}     ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                             ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Tip: Workers will be ready in ~15s${RESET}          ${DIM}│${RESET}\n"
  printf "   ${DIM}└─────────────────────────────────────────────┘${RESET}\n"
  printf '\n'

  # ── Focus on Manager pane, attach ─────────────────────────────────
  tmux select-pane -t "$session:0.0"
  tmux attach -t "$session"
}
