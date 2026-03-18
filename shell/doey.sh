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
#   doey purge        # Scan and clean stale runtime files
#   doey update       # Pull latest + reinstall (alias: reinstall)
#   doey reload       # Hot-reload running session (Manager + Watchdog)
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
  basename "$1" | tr '[:upper:] .' '[:lower:]--' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//;s/-$//'
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

# Write a per-window team environment file
# Read TEAM_WINDOWS from session.env (strips quotes, defaults to "0")
read_team_windows() {
  local runtime_dir="$1" tw
  tw=$(grep '^TEAM_WINDOWS=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2) || true
  tw="${tw//\"/}"
  echo "${tw:-0}"
}

# Usage: write_team_env <runtime_dir> <window_index> <grid> <watchdog_pane> <worker_panes> <worker_count> [manager_pane] [worktree_dir] [worktree_branch]
write_team_env() {
  local runtime_dir="$1" window_index="$2" grid="$3"
  local watchdog_pane="$4" worker_panes="$5" worker_count="$6"
  local manager_pane="${7:-0}"
  local worktree_dir="${8:-}"
  local worktree_branch="${9:-}"
  local session_name
  session_name=$(grep '^SESSION_NAME=' "${runtime_dir}/session.env" | cut -d= -f2)
  session_name="${session_name//\"/}"
  cat > "${runtime_dir}/team_${window_index}.env.tmp" << TEAMEOF
WINDOW_INDEX="${window_index}"
GRID="${grid}"
MANAGER_PANE="${manager_pane}"
WATCHDOG_PANE="${watchdog_pane}"
WORKER_PANES="${worker_panes}"
WORKER_COUNT="${worker_count}"
SESSION_NAME="${session_name}"
WORKTREE_DIR="${worktree_dir}"
WORKTREE_BRANCH="${worktree_branch}"
TEAMEOF
  mv "${runtime_dir}/team_${window_index}.env.tmp" "${runtime_dir}/team_${window_index}.env"
}

# Generate a team-specific agent definition copy
# Usage: generate_team_agent <base_agent_name> <team_number>
# Example: generate_team_agent "doey-watchdog" 1 → outputs "t1-watchdog"
generate_team_agent() {
  local base_name="$1" team_num="$2"
  local role="${base_name#doey-}"
  local new_name="t${team_num}-${role}"
  local src="$HOME/.claude/agents/${base_name}.md"
  local dst="$HOME/.claude/agents/${new_name}.md"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
    sed "s/name: ${base_name}/name: ${new_name}/" "$dst" > "${dst}.tmp"
    mv "${dst}.tmp" "$dst"
  fi
  echo "$new_name"
}

# Create a git worktree for a team window (isolated repo copy).
# Usage: create_team_worktree <project_dir> <team_window> [branch_name]
# Echoes the worktree path on success; returns 1 on failure.
create_team_worktree() {
  local project_dir="$1" team_window="$2" branch_name="${3:-}"
  if [ -z "$branch_name" ]; then
    branch_name="doey/team-${team_window}-$(date +%m%d-%H%M)"
  fi
  local project_name
  project_name="$(basename "$project_dir")"
  local wt_path="/tmp/doey/${project_name}/worktrees/team-${team_window}"
  mkdir -p "$(dirname "$wt_path")"
  if ! git -C "$project_dir" worktree add "$wt_path" -b "$branch_name" >/dev/null 2>&1; then
    if ! git -C "$project_dir" worktree add "$wt_path" "$branch_name" >/dev/null 2>&1; then
      echo "Error: failed to create worktree at $wt_path for branch $branch_name" >&2
      return 1
    fi
  fi
  # Copy hook settings into the worktree so Claude Code picks them up
  if [ -f "$project_dir/.claude/settings.local.json" ]; then
    mkdir -p "$wt_path/.claude"
    cp "$project_dir/.claude/settings.local.json" "$wt_path/.claude/"
  fi
  echo "$wt_path"
}

# Remove a git worktree and prune stale entries.
# Usage: remove_team_worktree <project_dir> <worktree_dir>
remove_team_worktree() {
  local project_dir="$1" worktree_dir="$2"
  [ -z "$worktree_dir" ] && return 0
  [ -d "$worktree_dir" ] || return 0
  git -C "$project_dir" worktree remove "$worktree_dir" --force 2>/dev/null || true
  git -C "$project_dir" worktree prune 2>/dev/null || true
}

# Safely remove a worktree, auto-saving uncommitted changes first.
# Calls remove_team_worktree() for the actual removal after preserving work.
# Usage: _worktree_safe_remove <project_dir> <worktree_dir> [force]
_worktree_safe_remove() {
  local project_dir="$1" worktree_dir="$2" force="${3:-false}"

  # Guard: nothing to do if dir doesn't exist
  if [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; then
    return 0
  fi

  # Check for uncommitted changes
  local dirty=""
  dirty=$(git -C "$worktree_dir" status --porcelain 2>/dev/null) || true

  if [ -n "$dirty" ] && [ "$force" != "true" ]; then
    # Auto-commit to preserve work
    local branch_name
    branch_name=$(git -C "$worktree_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    git -C "$worktree_dir" add -A 2>/dev/null || true
    git -C "$worktree_dir" commit -m "doey: auto-save before teardown $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
    printf '  Worktree had uncommitted changes — auto-saved to branch: %s\n' "$branch_name"
  fi

  # Report if branch has unmerged commits
  local branch_name commits_ahead
  branch_name=$(git -C "$worktree_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch_name" ] && [ "$branch_name" != "HEAD" ]; then
    commits_ahead=$(git -C "$project_dir" rev-list --count "HEAD..${branch_name}" 2>/dev/null || echo "0")
    if [ "$commits_ahead" -gt 0 ] 2>/dev/null; then
      printf '  Branch %s has %s commit(s). Merge with: git merge %s\n' "$branch_name" "$commits_ahead" "$branch_name"
    fi
  fi

  # Remove worktree via existing helper
  remove_team_worktree "$project_dir" "$worktree_dir"
}

# Build the Dashboard window (window 0) with 2 columns:
#   Left: Info Panel (full height)
#   Right: Session Manager (top) + 6 Watchdog slots side-by-side (bottom)
#
#   ┌──────────┬────────────────────────────────────┐
#   │          │         Session Manager             │
#   │  Info    ├────────┬────────┬────────┬──────────┤
#   │  Panel   │  WD 1  │  WD 2  │  WD 3  │  WD 4  │
#   └──────────┴────────┴────────┴────────┴──────────┘
#
# Usage: setup_dashboard <session> <dir> <runtime_dir>
# Sets: WDG_SLOT_1..6, SM_PANE (pane indices in window 0)
setup_dashboard() {
  local session="$1" dir="$2" runtime_dir="$3"

  # Start: single pane 0.0 (will become Info Panel)
  # Split left/right — right column gets 60% (use -l for tmux 3.4 detached compat)
  tmux split-window -h -t "$session:0.0" -l 150 -c "$dir"
  # Indices: 0.0=info(left), 0.1=right

  # Split right column: top 65% (SM area) + bottom 35% (watchdog row)
  tmux split-window -v -t "$session:0.1" -l 28 -c "$dir"
  # Indices: 0.0=info, 0.1=top-right, 0.2=bottom-right

  # Split bottom-right into 6 horizontal watchdog slots
  # Each split targets the NEW (right/larger) pane from the previous split
  tmux split-window -h -t "$session:0.2" -l 125 -c "$dir"
  tmux split-window -h -t "$session:0.3" -l 100 -c "$dir"
  tmux split-window -h -t "$session:0.4" -l 75 -c "$dir"
  tmux split-window -h -t "$session:0.5" -l 50 -c "$dir"
  tmux split-window -h -t "$session:0.6" -l 25 -c "$dir"
  # Indices: 0.0=info, 0.1=SM, 0.2=WD1, 0.3=WD2, 0.4=WD3, 0.5=WD4, 0.6=WD5, 0.7=WD6

  # Balance watchdog pane widths
  local _wd_total=0 _wd_w _wd_target
  for _wd_i in 2 3 4 5 6 7; do
    _wd_w=$(tmux display-message -t "$session:0.${_wd_i}" -p '#{pane_width}')
    _wd_total=$((_wd_total + _wd_w))
  done
  _wd_target=$((_wd_total / 6))
  for _wd_i in 2 3 4 5 6; do
    tmux resize-pane -t "$session:0.${_wd_i}" -x "$_wd_target"
  done

  # Name panes
  tmux select-pane -t "$session:0.0" -T ""
  tmux select-pane -t "$session:0.1" -T "Session Manager"
  tmux select-pane -t "$session:0.2" -T "T1 Watchdog"
  tmux select-pane -t "$session:0.3" -T "T2 Watchdog"
  tmux select-pane -t "$session:0.4" -T "T3 Watchdog"
  tmux select-pane -t "$session:0.5" -T "T4 Watchdog"
  tmux select-pane -t "$session:0.6" -T "T5 Watchdog"
  tmux select-pane -t "$session:0.7" -T "T6 Watchdog"

  # Show placeholder in empty Watchdog slots
  local _wd_s
  for _wd_s in 2 3 4 5 6 7; do
    tmux send-keys -t "$session:0.${_wd_s}" "echo 'Watchdog slot — awaiting team assignment...'" Enter
  done

  # Launch info panel and session manager
  tmux send-keys -t "$session:0.0" "clear && info-panel.sh '${runtime_dir}'" Enter
  tmux send-keys -t "$session:0.1" "claude --dangerously-skip-permissions --agent doey-session-manager" Enter
  tmux rename-window -t "$session:0" "Dashboard"
  write_pane_status "$runtime_dir" "${session}:0.1" "READY"

  # Export slot pane indices (stable after creation)
  WDG_SLOT_1="0.2"
  WDG_SLOT_2="0.3"
  WDG_SLOT_3="0.4"
  WDG_SLOT_4="0.5"
  WDG_SLOT_5="0.6"
  WDG_SLOT_6="0.7"
  SM_PANE="0.1"
}

# Validate and auto-fix session.env files with encoding/quoting issues
# This catches any files created with unquoted variables (spaces in paths)
validate_session_env() {
  local session_env="$1"
  [ -f "$session_env" ] || return 0

  if ! (source "$session_env") 2>/dev/null; then
    printf "  ${WARN}Fixing malformed session.env (unquoted paths with spaces)${RESET}\n" >&2
    local temp_file="${session_env}.fixed"
    {
      while IFS='=' read -r key value; do
        case "$key" in
          ''|'#'*) echo "$key${value:+=$value}"; continue ;;
        esac
        case "$value" in
          \"*\"|\'*\') echo "$key=$value" ;;
          *)           echo "$key=\"$value\"" ;;
        esac
      done < "$session_env"
    } > "$temp_file"
    mv "$temp_file" "$session_env"
  fi
}

# Source session.env with validation
safe_source_session_env() {
  validate_session_env "$1"
  # shellcheck disable=SC1090
  source "$1"
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
  # Clean up worktrees before removing runtime dir
  local project_name="${session#doey-}"
  local _sess_env="/tmp/doey/${project_name}/session.env"
  if [ -f "$_sess_env" ]; then
    local _proj_dir
    _proj_dir=$(grep '^PROJECT_DIR=' "$_sess_env" | cut -d= -f2- | tr -d '"')
    if [ -n "$_proj_dir" ]; then
      local _te _wt_dir
      for _te in "/tmp/doey/${project_name}"/team_*.env; do
        [ -f "$_te" ] || continue
        _wt_dir=$(grep '^WORKTREE_DIR=' "$_te" | cut -d= -f2- | tr -d '"')
        if [ -n "$_wt_dir" ]; then
          _worktree_safe_remove "$_proj_dir" "$_wt_dir"
        fi
      done
      git -C "$_proj_dir" worktree prune 2>/dev/null || true
    fi
  fi

  # Clean up runtime directory
  rm -rf "/tmp/doey/${project_name}" 2>/dev/null || true
}

# Show interactive project picker menu
show_menu() {
  local grid="$1"

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
          attach_or_switch "$selected_session"
        else
          launch_with_grid "$selected_name" "$selected_path" "$grid"
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
        launch_with_grid "$init_name" "$(pwd)" "$grid"
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

# ── Shared launch helpers ────────────────────────────────────────────

# Write the shared worker system prompt to <runtime_dir>/worker-system-prompt.md
# Usage: write_worker_system_prompt <runtime_dir> <name> <dir>
write_worker_system_prompt() {
  local runtime_dir="$1" name="$2" dir="$3"
  cat > "${runtime_dir}/worker-system-prompt.md" << 'WORKER_PROMPT'
# Doey Worker

You are a **Worker** on the Doey team, coordinated by a Window Manager in pane 0 of your team window. You receive tasks via this chat and execute them independently.

## Rules
1. **Absolute paths only** — Always use absolute file paths. Never use relative paths.
2. **Stay in scope** — Only make changes within the scope of your assigned task. Do not refactor, clean up, or "improve" code outside your task.
3. **Concurrent awareness** — Other workers are editing other files in this codebase simultaneously. Avoid broad sweeping changes (global renames, config modifications, formatter runs) unless your task explicitly requires it.
4. **When done, stop** — Complete your task and stop. Do not ask follow-up questions unless you are genuinely blocked. The Window Manager will check your output.
5. **If blocked, describe and stop** — If you encounter an unrecoverable error, describe it clearly and stop.
6. **No git commits** — Do not create git commits unless your task explicitly says to. The Window Manager coordinates commits.
7. **No tmux interaction** — Do not try to communicate with other panes. Just do your work.
WORKER_PROMPT

  cat >> "${runtime_dir}/worker-system-prompt.md" << WORKER_CONTEXT

## Project
- **Name:** ${name}
- **Root:** ${dir}
- **Runtime directory:** ${runtime_dir}

## Workspace
- If your working directory differs from the main project, you are on an isolated worktree branch
- Use absolute paths based on your working directory
- Other teams cannot see your file changes until the branch is merged
WORKER_CONTEXT
}

# Apply the Doey tmux theme to a session
# Usage: apply_doey_theme <session> <name> <pane_border_format> <status_interval>
apply_doey_theme() {
  local session="$1" name="$2" pane_border_fmt="$3" status_interval="$4"

  # Pane borders — heavy lines with role-aware titles
  tmux set-option -t "$session" pane-border-status top
  tmux set-option -t "$session" pane-border-format "$pane_border_fmt"
  tmux set-option -t "$session" pane-border-style 'fg=colour238'
  tmux set-option -t "$session" pane-active-border-style 'fg=cyan'
  tmux set-option -t "$session" pane-border-lines heavy

  # Status bar — transparent, minimal
  tmux set-option -t "$session" status-position bottom
  tmux set-option -t "$session" status-style 'bg=default,fg=colour240'
  tmux set-option -t "$session" status-left-length 10
  tmux set-option -t "$session" status-right-length 60
  tmux set-option -t "$session" status-left \
    "#[fg=cyan,dim] DOEY #[default] "
  tmux set-option -t "$session" status-right \
    "#[fg=colour240]%H:%M  #[fg=colour245]#('${SCRIPT_DIR}/tmux-statusbar.sh') "
  tmux set-option -t "$session" status-interval "$status_interval"

  # Window status — colored segments with Dashboard distinction
  # Apply window options to ALL existing windows (tmux 3.6+ requires per-window targeting)
  local _wsfmt='#[fg=colour245,bg=default] #I #W '
  local _wscfmt='#[fg=cyan,bg=default,bold] #I #W #[nobold]'

  for _win in $(tmux list-windows -t "$session" -F '#I'); do
    tmux set-window-option -t "$session:$_win" window-status-separator ''
    tmux set-window-option -t "$session:$_win" window-status-format "$_wsfmt"
    tmux set-window-option -t "$session:$_win" window-status-current-format "$_wscfmt"
    tmux set-window-option -t "$session:$_win" window-status-activity-style 'fg=colour214,bg=colour236,bold'
    tmux set-window-option -t "$session:$_win" monitor-activity on
    tmux set-window-option -t "$session:$_win" allow-rename off
  done

  # Ensure new windows also get the theme
  tmux set-hook -t "$session" after-new-window "set-window-option window-status-separator ''; set-window-option window-status-format \"$_wsfmt\"; set-window-option window-status-current-format \"$_wscfmt\"; set-window-option window-status-activity-style 'fg=colour214,bg=colour236,bold'; set-window-option monitor-activity on; set-window-option allow-rename off"

  tmux set-option -t "$session" message-style 'bg=colour233,fg=cyan'
  tmux set-option -t "$session" visual-activity off

  # Terminal tab/window title — shows project name in macOS Terminal tabs
  tmux set-option -t "$session" set-titles on
  tmux set-option -t "$session" set-titles-string "🤖 #{session_name} — #{pane_title}"

  # Enable mouse for pane selection, scrolling, resizing
  tmux set-option -t "$session" mouse on

  # Suppress terminal bell from worker panes — prevents notification spam
  tmux set-option -t "$session" bell-action none
  tmux set-option -t "$session" visual-bell off
}

# Pre-accept trust for the project directory in Claude settings
# Usage: ensure_project_trusted <dir> [indent]
ensure_project_trusted() {
  local dir="$1" indent="${2:-   }"
  local claude_settings="$HOME/.claude/settings.json"
  if command -v jq &>/dev/null; then
    if [ -f "$claude_settings" ]; then
      if ! jq --arg dir "$dir" -e '.trustedDirectories // [] | index($dir)' "$claude_settings" > /dev/null 2>&1; then
        jq --arg dir "$dir" '(.trustedDirectories // []) |= . + [$dir]' "$claude_settings" 2>/dev/null > "${claude_settings}.tmp" \
          && mv "${claude_settings}.tmp" "$claude_settings"
        printf "${indent}${DIM}Trusted project directory added to ~/.claude/settings.json${RESET}\n"
      fi
    else
      mkdir -p "$(dirname "$claude_settings")"
      printf '{"trustedDirectories": ["%s"]}\n' "$dir" > "$claude_settings"
      printf "${indent}${DIM}Created ~/.claude/settings.json with trusted directory${RESET}\n"
    fi
  else
    printf "${indent}${WARN}jq not found — skipping auto-trust (you may see trust prompts)${RESET}\n"
  fi
}

# Attach to or switch to a tmux session (handles both inside/outside tmux)
# Usage: attach_or_switch <session>
attach_or_switch() {
  local session="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach -t "$session"
  fi
}

# ── Purge helpers ─────────────────────────────────────────────────────

# Format bytes as human-readable (B/KB/MB)
_purge_format_bytes() {
  local bytes="$1"
  if [[ "$bytes" -ge 1048576 ]]; then
    printf "%.1f MB" "$(echo "$bytes 1048576" | awk '{printf "%.1f", $1/$2}')"
  elif [[ "$bytes" -ge 1024 ]]; then
    printf "%.1f KB" "$(echo "$bytes 1024" | awk '{printf "%.1f", $1/$2}')"
  else
    printf "%d B" "$bytes"
  fi
}

# Get file modification time (cross-platform)
_purge_file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Add a file to the purge list (appends to temp file)
_purge_collect() {
  local file="$1" list_file="$2"
  local size
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  echo "${size}:${file}" >> "$list_file"
}

# Scan stale runtime files
# Args: <runtime_dir> <session_active> <session_name> <list_file>
# Writes stale file paths to list_file, one per line (size:path format)
_purge_scan_runtime() {
  local rt="$1" active="$2" session_name="$3" list_file="$4" now="$5"
  local count=0

  # Get list of live panes (if session active)
  local live_panes=""
  if $active; then
    live_panes="$(tmux list-panes -s -t "$session_name" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | tr '\n' '|')"
  fi

  # Scan status files for dead panes
  local status_count=0
  for f in "$rt"/status/*.status; do
    [[ -f "$f" ]] || continue
    if $active; then
      local pane_id
      pane_id="$(head -1 "$f" | sed 's/^PANE: //')"
      if ! echo "$live_panes" | grep -qF "$pane_id"; then
        _purge_collect "$f" "$list_file"
        status_count=$((status_count + 1))
      fi
    else
      _purge_collect "$f" "$list_file"
      status_count=$((status_count + 1))
    fi
  done
  if [[ $status_count -gt 0 ]]; then
    printf "         Found %d stale status files\n" "$status_count"
  fi

  # Scan dispatched markers — always safe to clean (consumed on read by is_dispatched)
  for f in "$rt"/status/*.dispatched; do
    [[ -f "$f" ]] || continue
    _purge_collect "$f" "$list_file"
  done

  # Notification cooldown markers (always safe)
  local cooldown_count=0
  for f in "$rt"/status/notif_cooldown_*; do
    [[ -f "$f" ]] || continue
    _purge_collect "$f" "$list_file"
    cooldown_count=$((cooldown_count + 1))
  done
  if [[ $cooldown_count -gt 0 ]]; then
    printf "         Found %d cooldown markers\n" "$cooldown_count"
  fi

  # Session-stopped-only files
  if ! $active; then
    for f in "$rt"/status/pane_map "$rt"/status/col_*.collapsed \
             "$rt"/status/pane_hash_* "$rt"/status/watchdog_W*.heartbeat \
             "$rt"/status/watchdog_pane_states_W*.json; do
      [[ -f "$f" ]] || continue
      _purge_collect "$f" "$list_file"
    done
  fi

  # Old undelivered messages (>1h)
  local msg_count=0
  for f in "$rt"/messages/*.msg; do
    [[ -f "$f" ]] || continue
    local mtime
    mtime="$(_purge_file_mtime "$f")"
    if [[ $((now - mtime)) -gt 3600 ]]; then
      _purge_collect "$f" "$list_file"
      msg_count=$((msg_count + 1))
    fi
  done
  if [[ $msg_count -gt 0 ]]; then
    printf "         Found %d stale undelivered messages\n" "$msg_count"
  fi

  # Old broadcasts (>1h)
  for f in "$rt"/broadcasts/*.broadcast; do
    [[ -f "$f" ]] || continue
    local mtime
    mtime="$(_purge_file_mtime "$f")"
    if [[ $((now - mtime)) -gt 3600 ]]; then
      _purge_collect "$f" "$list_file"
    fi
  done

  # Old results (>24h)
  local result_count=0
  for f in "$rt"/results/*; do
    [[ -f "$f" ]] || continue
    local mtime
    mtime="$(_purge_file_mtime "$f")"
    if [[ $((now - mtime)) -gt 86400 ]]; then
      _purge_collect "$f" "$list_file"
      result_count=$((result_count + 1))
    fi
  done
  if [[ $result_count -gt 0 ]]; then
    printf "         Found %d old result files (>24h)\n" "$result_count"
  fi
}

# Scan expired research/reports (48h TTL)
# Args: <runtime_dir> <list_file> <now_epoch>
_purge_scan_research() {
  local rt="$1" list_file="$2" now="$3"
  local count=0 ttl=172800

  for dir in "$rt/research" "$rt/reports"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/*; do
      [[ -f "$f" ]] || continue
      local mtime
      mtime="$(_purge_file_mtime "$f")"
      if [[ $((now - mtime)) -gt $ttl ]]; then
        _purge_collect "$f" "$list_file"
        count=$((count + 1))
      fi
    done
  done

  if [[ $count -gt 0 ]]; then
    printf "         Found %d research/report files older than 48h\n" "$count"
  else
    printf "         ${DIM}No expired research artifacts${RESET}\n"
  fi
}

# Audit context file sizes (report only, no deletions)
_purge_audit_context() {
  local total_bytes=0
  local recommendations=""
  local rec_count=0

  printf '\n'

  # Check installed agents
  for f in "$HOME"/.claude/agents/doey-*.md; do
    [[ -f "$f" ]] || continue
    local size lines short_name
    size=$(wc -c < "$f" | tr -d ' ')
    lines=$(wc -l < "$f" | tr -d ' ')
    short_name="~/.claude/agents/$(basename "$f")"
    printf "         %-45s %s  (%d lines)\n" "$short_name" "$(_purge_format_bytes "$size")" "$lines"
    total_bytes=$((total_bytes + size))
    if [[ $size -gt 8192 ]]; then
      recommendations="${recommendations}         - $(basename "$f") is >8KB — consider splitting rules into memory\n"
      rec_count=$((rec_count + 1))
    fi
  done

  # Check installed commands/skills
  local skill_count=0 skill_bytes=0
  for f in "$HOME"/.claude/commands/doey-*.md; do
    [[ -f "$f" ]] || continue
    local size
    size=$(wc -c < "$f" | tr -d ' ')
    skill_bytes=$((skill_bytes + size))
    skill_count=$((skill_count + 1))
    if [[ $size -gt 3072 ]]; then
      recommendations="${recommendations}         - $(basename "$f") is >3KB — consider compressing\n"
      rec_count=$((rec_count + 1))
    fi
  done
  if [[ $skill_count -gt 0 ]]; then
    printf "         %-45s %s total\n" "${skill_count} skills" "$(_purge_format_bytes "$skill_bytes")"
    total_bytes=$((total_bytes + skill_bytes))
  fi
  if [[ $skill_bytes -gt 30720 ]]; then
    recommendations="${recommendations}         - ${skill_count} skills total >30KB — consider per-role skill sets\n"
    rec_count=$((rec_count + 1))
  fi

  # Check project CLAUDE.md
  local project_dir
  project_dir="$(pwd)"
  if [[ -f "$project_dir/CLAUDE.md" ]]; then
    local size lines
    size=$(wc -c < "$project_dir/CLAUDE.md" | tr -d ' ')
    lines=$(wc -l < "$project_dir/CLAUDE.md" | tr -d ' ')
    printf "         %-45s %s  (%d lines)\n" "CLAUDE.md" "$(_purge_format_bytes "$size")" "$lines"
    total_bytes=$((total_bytes + size))
    if [[ $size -gt 5120 ]]; then
      recommendations="${recommendations}         - CLAUDE.md is >5KB — consider moving stable info to memory\n"
      rec_count=$((rec_count + 1))
    fi
  fi

  printf "         %-45s ~%s\n" "Total loaded context:" "$(_purge_format_bytes "$total_bytes")"

  if [[ $rec_count -gt 0 ]]; then
    printf '\n'
    printf "         ${WARN}Recommendations:${RESET}\n"
    printf "$recommendations"
  fi
  printf '\n'
}

# Run context-audit.sh if available
_purge_audit_hooks() {
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  local audit_script="${repo_dir}/shell/context-audit.sh"

  if [[ ! -x "$audit_script" ]]; then
    printf "         ${DIM}context-audit.sh not found — skipping${RESET}\n"
    return 0
  fi

  local audit_output
  audit_output="$("$audit_script" --installed --no-color 2>&1)" || true

  if [[ -z "$audit_output" ]]; then
    printf "         ${SUCCESS}Context audit: clean${RESET}\n"
  else
    printf "%s\n" "$audit_output"
  fi
}

# Print purge summary table
# Args: <runtime_files> <runtime_bytes> <research_files> <research_bytes> <dry_run>
_purge_summary() {
  local rt_files="$1" rt_bytes="$2" res_files="$3" res_bytes="$4" dry_run="$5"
  local total_files=$((rt_files + res_files))
  local total_bytes=$((rt_bytes + res_bytes))

  printf '\n'
  printf "         ${DIM}┌─────────────┬────────┬──────────────┐${RESET}\n"
  printf "         ${DIM}│${RESET} ${BOLD}Category${RESET}    ${DIM}│${RESET} ${BOLD}Files${RESET}  ${DIM}│${RESET} ${BOLD}Size${RESET}         ${DIM}│${RESET}\n"
  printf "         ${DIM}├─────────────┼────────┼──────────────┤${RESET}\n"
  printf "         ${DIM}│${RESET} Runtime     ${DIM}│${RESET} %5d  ${DIM}│${RESET} %-12s ${DIM}│${RESET}\n" "$rt_files" "$(_purge_format_bytes "$rt_bytes")"
  printf "         ${DIM}│${RESET} Research    ${DIM}│${RESET} %5d  ${DIM}│${RESET} %-12s ${DIM}│${RESET}\n" "$res_files" "$(_purge_format_bytes "$res_bytes")"
  printf "         ${DIM}├─────────────┼────────┼──────────────┤${RESET}\n"
  printf "         ${DIM}│${RESET} ${BOLD}Total${RESET}       ${DIM}│${RESET} ${BOLD}%5d${RESET}  ${DIM}│${RESET} ${BOLD}%-12s${RESET} ${DIM}│${RESET}\n" "$total_files" "$(_purge_format_bytes "$total_bytes")"
  printf "         ${DIM}└─────────────┴────────┴──────────────┘${RESET}\n"

  if $dry_run; then
    printf "         ${DIM}(dry run — no files were deleted)${RESET}\n"
  fi
  printf '\n'
}

# Delete collected stale files
# Args: <list_file>
_purge_execute() {
  local list_file="$1"
  local count=0 bytes=0

  while IFS=: read -r size path; do
    [[ -z "$path" ]] && continue
    rm -f "$path" 2>/dev/null && {
      count=$((count + 1))
      bytes=$((bytes + size))
    }
  done < "$list_file"

  printf "   ${SUCCESS}Purged %d files, freed %s.${RESET}\n" "$count" "$(_purge_format_bytes "$bytes")"
}

# Write purge report JSON
# Args: <runtime_dir> <project> <session_active> <dry_run> <scope>
#        <rt_files> <rt_bytes> <res_files> <res_bytes>
_purge_write_report() {
  local rt="$1" project="$2" active="$3" dry_run="$4" scope="$5"
  local rt_files="$6" rt_bytes="$7" res_files="$8" res_bytes="$9"
  local total_files=$((rt_files + res_files))
  local total_bytes=$((rt_bytes + res_bytes))
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  local report_name="purge_report_$(date '+%Y%m%d_%H%M%S').json"

  mkdir -p "$rt/results"
  cat > "$rt/results/$report_name" << REPORT_EOF
{
  "timestamp": "$ts",
  "project": "$project",
  "session_active": $active,
  "dry_run": $dry_run,
  "scope": "$scope",
  "runtime": { "files_found": $rt_files, "bytes_freed": $rt_bytes },
  "research": { "files_found": $res_files, "bytes_freed": $res_bytes },
  "total_files_purged": $total_files,
  "total_bytes_freed": $total_bytes
}
REPORT_EOF
  printf "   Report: ${DIM}%s${RESET}\n" "$rt/results/$report_name"
}

# Count files and total bytes from a list file (size:path per line)
# Sets _COUNT and _BYTES globals
_purge_tally() {
  local list_file="$1"
  _COUNT=0
  _BYTES=0
  if [[ -s "$list_file" ]]; then
    while IFS=: read -r size path; do
      [[ -z "$path" ]] && continue
      _COUNT=$((_COUNT + 1))
      _BYTES=$((_BYTES + size))
    done < "$list_file"
  fi
}

# Help text for doey purge
purge_usage() {
  cat << 'PURGE_HELP'

  Usage: doey purge [options]

  Scan and clean stale runtime files, audit context bloat.

  Options:
    --dry-run    Report only, no deletions
    --force      Skip confirmation prompt
    --scope X    Limit scope: runtime, context, hooks, all (default: all)
    -h, --help   Show this help

  Examples:
    doey purge                    # Interactive scan and clean
    doey purge --dry-run          # See what would be purged
    doey purge --force            # Purge without asking
    doey purge --scope runtime    # Only clean runtime files

PURGE_HELP
}

# Main entry point for doey purge
doey_purge() {
  local dry_run=false
  local force=false
  local scope="all"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry_run=true ;;
      --force)    force=true ;;
      --scope)    scope="${2:?--scope requires a value}"; shift ;;
      -h|--help)  purge_usage; return 0 ;;
      *)          printf "  ${ERROR}Unknown purge flag: %s${RESET}\n" "$1"; return 1 ;;
    esac
    shift
  done

  # Validate scope
  case "$scope" in
    runtime|context|hooks|all) ;;
    *) printf "  ${ERROR}Invalid scope: %s (use: runtime, context, hooks, all)${RESET}\n" "$scope"; return 1 ;;
  esac

  # Resolve project
  local dir name session runtime_dir session_active
  dir="$(pwd)"
  name="$(find_project "$dir")"
  if [[ -z "$name" ]]; then
    printf "  ${DIM}No project registered for %s — nothing to purge${RESET}\n" "$dir"
    return 0
  fi

  session="doey-${name}"
  runtime_dir="/tmp/doey/${name}"
  session_active=false

  if session_exists "$session"; then
    session_active=true
    local tmux_rt
    tmux_rt="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
    [[ -n "$tmux_rt" ]] && runtime_dir="$tmux_rt"
  fi

  if [[ ! -d "$runtime_dir" ]]; then
    printf "  ${DIM}No runtime directory found — nothing to purge${RESET}\n"
    return 0
  fi

  # Header
  printf '\n'
  printf "  ${BRAND}Doey — Purge${RESET}"
  if $session_active; then
    printf "  ${DIM}(session active)${RESET}"
  else
    printf "  ${DIM}(session stopped)${RESET}"
  fi
  printf '\n\n'

  # Calculate step count based on scope (use local to avoid mutating global)
  local step=0
  local purge_steps
  case "$scope" in
    runtime) purge_steps=2 ;;
    context) purge_steps=2 ;;
    hooks)   purge_steps=2 ;;
    all)     purge_steps=5 ;;
  esac
  STEP_TOTAL=$purge_steps

  # Temp file for collecting stale file list
  local list_file now
  list_file="$(mktemp /tmp/doey_purge_XXXXXX)"
  trap "rm -f '$list_file'" RETURN
  now="$(date +%s)"

  local rt_files=0 rt_bytes=0 res_files=0 res_bytes=0

  # Step: Scan runtime files
  if [[ "$scope" == "runtime" || "$scope" == "all" ]]; then
    step=$((step + 1))
    step_start "$step" "Scanning stale runtime files..."
    step_done
    _purge_scan_runtime "$runtime_dir" "$session_active" "$session" "$list_file" "$now"
    _purge_tally "$list_file"
    rt_files=$_COUNT
    rt_bytes=$_BYTES
  fi

  # Step: Scan research artifacts (only for --scope all)
  if [[ "$scope" == "all" ]]; then
    step=$((step + 1))
    local rt_count_before=$_COUNT
    step_start "$step" "Scanning expired research artifacts..."
    step_done
    _purge_scan_research "$runtime_dir" "$list_file" "$now"
    _purge_tally "$list_file"
    res_files=$((_COUNT - rt_count_before))
    res_bytes=$((_BYTES - rt_bytes))
  fi

  # Step: Audit context
  if [[ "$scope" == "context" || "$scope" == "all" ]]; then
    step=$((step + 1))
    step_start "$step" "Auditing context file sizes..."
    step_done
    _purge_audit_context
  fi

  # Step: Audit hooks
  if [[ "$scope" == "hooks" || "$scope" == "all" ]]; then
    step=$((step + 1))
    step_start "$step" "Running context audit..."
    step_done
    _purge_audit_hooks
  fi

  # Step: Summary
  step=$((step + 1))
  step_start "$step" "Summary"
  printf '\n'

  local total_files=$((rt_files + res_files))
  local total_bytes=$((rt_bytes + res_bytes))

  if [[ $total_files -eq 0 ]]; then
    printf "         ${SUCCESS}Nothing to purge — runtime is clean.${RESET}\n\n"
    _purge_write_report "$runtime_dir" "$name" "$session_active" "$dry_run" "$scope" \
      "$rt_files" "$rt_bytes" "$res_files" "$res_bytes"
    return 0
  fi

  _purge_summary "$rt_files" "$rt_bytes" "$res_files" "$res_bytes" "$dry_run"

  # Dry run — stop here
  if $dry_run; then
    _purge_write_report "$runtime_dir" "$name" "$session_active" "$dry_run" "$scope" \
      "$rt_files" "$rt_bytes" "$res_files" "$res_bytes"
    return 0
  fi

  # Confirmation prompt (unless --force)
  if ! $force; then
    local confirm
    printf "   Found %d stale files (%s). Purge? (y/N) " "$total_files" "$(_purge_format_bytes "$total_bytes")"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      printf "  ${DIM}Cancelled${RESET}\n"
      return 0
    fi
  fi

  # Execute purge
  _purge_execute "$list_file"
  _purge_write_report "$runtime_dir" "$name" "$session_active" "$dry_run" "$scope" \
    "$rt_files" "$rt_bytes" "$res_files" "$res_bytes"
}

# ── Initial worker columns ────────────────────────────────────────────
# Number of worker columns to add on dynamic launch (2 workers per column)
INITIAL_WORKER_COLS=3
# Number of team windows to create on dynamic launch (max 6, one per Dashboard watchdog slot)
INITIAL_TEAMS=2

# ── Launch dispatcher ─────────────────────────────────────────────────
# Routes to dynamic or static launch based on grid type.
launch_with_grid() {
  local name="$1" dir="$2" grid="$3"
  if [[ "$grid" == "dynamic" || "$grid" == "d" ]]; then
    launch_session_dynamic "$name" "$dir"
  else
    launch_session "$name" "$dir" "$grid"
  fi
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
  local worker_count=$(( total - 1 ))
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
  ensure_project_trusted "$dir"

  # ── Install Doey hooks into target project ─────────────────────
  install_doey_hooks "$dir" "   "

  # ── Build worker pane list (needed for manifest and briefings) ──
  # Pane 0 = Manager, panes 1+ = Workers
  local worker_panes_csv=""
  for (( i=1; i<total; i++ )); do
    [[ -n "$worker_panes_csv" ]] && worker_panes_csv+=","
    worker_panes_csv+="$i"
  done

  # ── Step 1: Create session ─────────────────────────────────────
  step_start 1 "Creating session for ${name}..."
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}

  # Write session manifest — readable by Window Manager, Watchdog, and all skills/commands
  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR="$dir"
PROJECT_NAME="$name"
SESSION_NAME="$session"
GRID="$grid"
TOTAL_PANES="$total"
WORKER_COUNT="$worker_count"
WATCHDOG_PANE="0.2"
WORKER_PANES="$worker_panes_csv"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="500"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
TEAM_WINDOWS="1"
WDG_SLOT_1="0.2"
WDG_SLOT_2="0.3"
WDG_SLOT_3="0.4"
WDG_SLOT_4="0.5"
WDG_SLOT_5="0.6"
WDG_SLOT_6="0.7"
SM_PANE="0.1"
MANIFEST

  # Write per-window team env for window 1 (watchdog in Dashboard slot 0.2, manager in team pane 0)
  write_team_env "$runtime_dir" "1" "$grid" "0.2" "$worker_panes_csv" "$worker_count" "0" "" ""

  # Generate shared worker system prompt
  write_worker_system_prompt "$runtime_dir" "$name" "$dir"

  tmux new-session -d -s "$session" -x 250 -y 80 -c "$dir" >/dev/null
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"

  # Dashboard window (window 0) — info panel + watchdog slots + session manager
  setup_dashboard "$session" "$dir" "$runtime_dir"

  # Team grid window (window 1)
  local team_window=1
  tmux new-window -t "$session" -c "$dir"

  step_done

  # ── Step 2: Apply theme ────────────────────────────────────────
  step_start 2 "Applying theme..."
  local border_fmt=" #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  apply_doey_theme "$session" "$name" "$border_fmt" 2
  step_done

  # ── Step 3: Build grid ─────────────────────────────────────────
  step_start 3 "Building ${cols}x${rows} grid (${total} panes)..."

  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "$session:${team_window}.0" -c "$dir"
  done
  tmux select-layout -t "$session:${team_window}" even-vertical

  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "$session:${team_window}.$((r * cols))" -c "$dir"
    done
  done

  sleep 2

  # Verify pane count
  local actual
  actual=$(tmux list-panes -t "$session:${team_window}" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$actual" -ne "$total" ]]; then
    printf "\n"
    printf "   ${WARN}⚠ Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total" "$actual"
  fi

  step_done

  # ── Step 4: Name panes ─────────────────────────────────────────
  step_start 4 "Naming panes..."

  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    wnum=$((wnum + 1))
    tmux select-pane -t "$session:${team_window}.$i" -T "T${team_window} W${wnum}"
  done
  tmux rename-window -t "$session:${team_window}" "Team ${team_window}"

  step_done

  # ── Step 5: Launch Window Manager & Watchdog ──────────────────
  step_start 5 "Launching Window Manager & Watchdog..."

  # Launch Window Manager in team window pane 0
  mgr_agent=$(generate_team_agent "doey-manager" "$team_window")
  tmux send-keys -t "$session:${team_window}.0" \
    "claude --dangerously-skip-permissions --name \"T${team_window} Window Manager\" --agent \"$mgr_agent\"" Enter
  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  sleep 0.5

  write_pane_status "$runtime_dir" "${session}:${team_window}.0" "READY"

  # Send initial briefing once Window Manager is ready
  (
    sleep 8
    worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="${team_window}.$i"
    done
    tmux send-keys -t "$session:${team_window}.0" \
      "Team is online (project: ${name}, dir: $dir). You have $((total - 1)) workers in panes ${worker_panes}. Your workers are in window ${team_window}. Watchdog is in Dashboard pane ${WDG_SLOT_1} (monitors workers). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Brief Session Manager (pane ${SM_PANE}) after it boots
  (
    sleep 15
    tmux send-keys -t "$session:${SM_PANE}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. Team window ${team_window} has $((total - 1)) workers. Use /doey-add-window to create new team windows and /doey-list-windows to see all teams. Awaiting instructions." Enter
  ) &

  # Launch Watchdog in Dashboard slot 1 (pane ${WDG_SLOT_1})
  tmux send-keys -t "$session:${WDG_SLOT_1}" C-c
  sleep 0.3
  wdg_agent=$(generate_team_agent "doey-watchdog" "$team_window")
  tmux send-keys -t "$session:${WDG_SLOT_1}" \
    "claude --dangerously-skip-permissions --model haiku --effort low --name \"T${team_window} Watchdog\" --agent \"$wdg_agent\"" Enter
  tmux select-pane -t "$session:${WDG_SLOT_1}" -T "T${team_window} Watchdog"
  sleep 0.5

  # Auto-start the watchdog loop
  (
    sleep 12
    watch_panes=""
    for (( i=1; i<total; i++ )); do
      [[ -n "$watch_panes" ]] && watch_panes+=", "
      watch_panes+="${team_window}.$i"
    done
    tmux send-keys -t "$session:${WDG_SLOT_1}" \
      "Start monitoring session $session. Total panes: $total. Skip pane ${WDG_SLOT_1} (yourself, in Dashboard). Manager is in team window pane ${team_window}.0. Monitor panes ${watch_panes}." Enter
    # Schedule periodic compact to keep Watchdog context lean
    sleep 20
    tmux send-keys -t "$session:${WDG_SLOT_1}" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &

  # Clean up background jobs on early exit
  trap 'jobs -p | xargs kill 2>/dev/null' EXIT INT TERM

  step_done

  # ── Step 6: Boot workers ───────────────────────────────────────
  step_start 6 "Booting ${worker_count} workers..."
  printf '\n'

  local booted=0
  local bar_width=30
  for (( i=1; i<total; i++ )); do
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
    printf '\n\n## Identity\nYou are Worker %s in pane %s.%s of session %s.\n' "$booted" "$team_window" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus --name \"T${team_window} W${booted}\""
    worker_cmd+=" --append-system-prompt-file \"${worker_prompt_file}\""
    tmux send-keys -t "$session:${team_window}.$i" "$worker_cmd" Enter
    sleep 0.3

    write_pane_status "$runtime_dir" "${session}:${team_window}.${i}" "READY"
  done
  printf "${SUCCESS}done${RESET}\n"

  # ── Final summary ──────────────────────────────────────────────
  printf '\n'
  printf "   ${DIM}┌─────────────────────────────────────────────────┐${RESET}\n"
  printf "   ${DIM}│${RESET}  ${SUCCESS}Doey is ready${RESET}                           ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Dashboard${RESET}  ${DIM}win 0${RESET} Info panel + Session Manager  ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Win Manager${RESET} ${DIM}${team_window}.0${RESET}   Online                      ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Watchdog${RESET}   ${DIM}0.1${RESET}   Online (Dashboard)              ${DIM}│${RESET}\n"
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

  # ── Focus on Dashboard window, attach ──────────────────────────────
  # Clear the trap — background briefing jobs should complete normally after attach
  trap - EXIT INT TERM
  tmux select-window -t "$session:0"
  attach_or_switch "$session"
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
    local web_repo_url="https://github.com/FRIKKern/doey.git"
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
  printf "  Running sessions need a restart: ${BOLD}doey stop && doey${RESET} or ${BOLD}doey reload${RESET}\n"
}

# ── Reload (hot-reload a running session) ─────────────────────────
# Updates files on disk, then kills + relaunches Manager and Watchdog
# so they pick up new agent definitions. Workers are optionally restarted.
reload_session() {
  local restart_workers=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers|--all) restart_workers=true; shift ;;
      *) shift ;;
    esac
  done

  # 1. Find running session
  local dir name session runtime_dir
  dir="$(pwd)"
  name="$(find_project "$dir")"
  if [ -z "$name" ]; then
    printf "  ${ERROR}✗ No doey project found for %s${RESET}\n" "$dir"
    exit 1
  fi
  session="doey-${name}"
  runtime_dir="/tmp/doey/${name}"

  if ! session_exists "$session"; then
    printf "  ${ERROR}✗ No running session: ${session}${RESET}\n"
    exit 1
  fi

  printf "  ${BRAND}Reloading ${session}...${RESET}\n\n"

  # 2. Run install.sh (updates agents, commands, shell scripts on disk)
  local repo_dir
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || echo "")"
  if [ -n "$repo_dir" ] && [ -d "$repo_dir" ]; then
    printf "  ${DIM}Installing latest files...${RESET}\n"
    bash "$repo_dir/install.sh" 2>&1 | sed 's/^/    /'
    printf "\n  ${SUCCESS}✓ Files installed${RESET}\n\n"
  else
    printf "  ${WARN}⚠ No repo path found — skipping install${RESET}\n\n"
  fi

  # 3. Copy hooks to project dir (if not the doey repo itself)
  install_doey_hooks "$dir" "  "

  # 3b. Also refresh hooks in worktree directories
  for _te in "${runtime_dir}"/team_*.env; do
    [ -f "$_te" ] || continue
    local _wt_dir
    _wt_dir=$(grep '^WORKTREE_DIR=' "$_te" | cut -d= -f2- | tr -d '"')
    if [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ]; then
      install_doey_hooks "$_wt_dir" "  "
    fi
  done

  # 4. Source current session.env to know the layout
  if [ ! -f "${runtime_dir}/session.env" ]; then
    printf "  ${ERROR}✗ session.env not found${RESET}\n"
    exit 1
  fi
  safe_source_session_env "${runtime_dir}/session.env"

  # 4b. Fix stale session.env WATCHDOG_PANE if needed
  local cur_ses_wdg
  cur_ses_wdg=$(grep '^WATCHDOG_PANE=' "${runtime_dir}/session.env" | cut -d= -f2)
  cur_ses_wdg="${cur_ses_wdg//\"/}"
  case "$cur_ses_wdg" in
    0.*) ;; # already correct
    *)
      # Rewrite WATCHDOG_PANE to "0.2" (default Dashboard slot for team 1)
      sed -i '' 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env"
      # Add WDG_SLOT entries if missing
      if ! grep -q '^WDG_SLOT_1=' "${runtime_dir}/session.env"; then
        printf 'WDG_SLOT_1="0.2"\nWDG_SLOT_2="0.3"\nWDG_SLOT_3="0.4"\nWDG_SLOT_4="0.5"\nWDG_SLOT_5="0.6"\nWDG_SLOT_6="0.7"\n' >> "${runtime_dir}/session.env"
      fi
      # Remove stale MGR_SLOT entries
      sed -i '' '/^MGR_SLOT_/d' "${runtime_dir}/session.env"
      printf "  ${DIM}Fixed stale session.env: WATCHDOG_PANE=%s → 0.2${RESET}\n" "$cur_ses_wdg"
      # Re-source with fixed values
      safe_source_session_env "${runtime_dir}/session.env"
      ;;
  esac

  # 5. Regenerate worker system prompts
  write_worker_system_prompt "$runtime_dir" "$name" "$dir"
  printf "  ${SUCCESS}✓ Worker system prompts updated${RESET}\n"

  # 6. Reload Manager(s) and Watchdog(s) — kill + relaunch
  printf "\n  ${DIM}Reloading Manager and Watchdog...${RESET}\n"

  # Find all team windows from team_*.env files
  local team_windows=""
  local tf tw
  for tf in "${runtime_dir}"/team_*.env; do
    [ -f "$tf" ] || continue
    tw=$(grep '^WINDOW_INDEX=' "$tf" | cut -d= -f2)
    tw="${tw//\"/}"
    [ -n "$tw" ] && team_windows="$team_windows $tw"
  done

  # Rewrite team envs if WATCHDOG_PANE looks stale (should be "0.X" for Dashboard slot)
  for tw in $team_windows; do
    local team_env="${runtime_dir}/team_${tw}.env"
    [ -f "$team_env" ] || continue
    local cur_wdg
    cur_wdg=$(grep '^WATCHDOG_PANE=' "$team_env" | cut -d= -f2)
    cur_wdg="${cur_wdg//\"/}"
    # If WATCHDOG_PANE doesn't start with "0." it's stale — fix it
    case "$cur_wdg" in
      0.*) ;; # already correct
      *)
        # Find which Dashboard slot this team uses from session.env
        local slot_key="WDG_SLOT_${tw}"
        local slot_val
        slot_val=$(grep "^${slot_key}=" "${runtime_dir}/session.env" | cut -d= -f2)
        slot_val="${slot_val//\"/}"
        [ -z "$slot_val" ] && slot_val="0.${tw}"  # fallback: 0.1 for team 1, 0.2 for team 2, etc.
        local cur_wpanes cur_wcount
        cur_wpanes=$(grep '^WORKER_PANES=' "$team_env" | cut -d= -f2)
        cur_wpanes="${cur_wpanes//\"/}"
        cur_wcount=$(grep '^WORKER_COUNT=' "$team_env" | cut -d= -f2)
        cur_wcount="${cur_wcount//\"/}"
        write_team_env "$runtime_dir" "$tw" "dynamic" "$slot_val" "$cur_wpanes" "$cur_wcount" "0" "" ""
        printf "    ${DIM}Fixed stale team_${tw}.env: WATCHDOG_PANE=%s → %s${RESET}\n" "$cur_wdg" "$slot_val"
        ;;
    esac
  done

  for tw in $team_windows; do
    local team_env="${runtime_dir}/team_${tw}.env"
    [ -f "$team_env" ] || continue

    local mgr_pane wdg_pane
    mgr_pane=$(grep '^MANAGER_PANE=' "$team_env" | cut -d= -f2)
    mgr_pane="${mgr_pane//\"/}"
    wdg_pane=$(grep '^WATCHDOG_PANE=' "$team_env" | cut -d= -f2)
    wdg_pane="${wdg_pane//\"/}"

    # Kill and relaunch Manager (team_window.mgr_pane)
    local mgr_ref="${session}:${tw}.${mgr_pane:-0}"
    printf "    Manager %s..." "$mgr_ref"
    local mgr_shell_pid mgr_child attempt
    mgr_shell_pid=$(tmux display-message -t "$mgr_ref" -p '#{pane_pid}' 2>/dev/null || true)
    if [ -n "$mgr_shell_pid" ]; then
      mgr_child=$(pgrep -P "$mgr_shell_pid" 2>/dev/null || true)
      [ -n "$mgr_child" ] && kill "$mgr_child" 2>/dev/null || true
      sleep 2
      for attempt in 1 2 3; do
        mgr_child=$(pgrep -P "$mgr_shell_pid" 2>/dev/null || true)
        [ -z "$mgr_child" ] && break
        kill -9 "$mgr_child" 2>/dev/null || true
        sleep 1
      done
      tmux send-keys -t "$mgr_ref" "clear" Enter 2>/dev/null || true
      sleep 0.5
      mgr_agent=$(generate_team_agent "doey-manager" "$tw")
      tmux send-keys -t "$mgr_ref" "claude --dangerously-skip-permissions --model opus --name \"T${tw} Window Manager\" --agent \"$mgr_agent\"" Enter
      printf " ${SUCCESS}✓${RESET}\n"

      # Re-brief manager after boot
      local worker_panes_csv
      worker_panes_csv=$(grep '^WORKER_PANES=' "$team_env" | cut -d= -f2)
      worker_panes_csv="${worker_panes_csv//\"/}"
      local worker_count_tw
      worker_count_tw=$(grep '^WORKER_COUNT=' "$team_env" | cut -d= -f2)
      worker_count_tw="${worker_count_tw//\"/}"
      local wp_list=""
      local wp
      for wp in $(echo "$worker_panes_csv" | tr ',' ' '); do
        [ -n "$wp_list" ] && wp_list="${wp_list}, "
        wp_list="${wp_list}${tw}.${wp}"
      done
      (
        sleep 8
        tmux send-keys -t "$mgr_ref" \
          "Team is online (project: ${name}, dir: $dir). You have ${worker_count_tw:-0} workers in panes ${wp_list}. Your workers are in window ${tw}. Watchdog is in Dashboard pane ${wdg_pane:-0.1}. Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
      ) &
    else
      printf " ${WARN}(not found)${RESET}\n"
    fi

    # Kill and relaunch Watchdog (Dashboard slot — wdg_pane is like "0.1")
    if [ -n "$wdg_pane" ]; then
      local wdg_ref="${session}:${wdg_pane}"
      printf "    Watchdog %s..." "$wdg_ref"
      local wdg_shell_pid wdg_child
      wdg_shell_pid=$(tmux display-message -t "$wdg_ref" -p '#{pane_pid}' 2>/dev/null || true)
      if [ -n "$wdg_shell_pid" ]; then
        wdg_child=$(pgrep -P "$wdg_shell_pid" 2>/dev/null || true)
        [ -n "$wdg_child" ] && kill "$wdg_child" 2>/dev/null || true
        sleep 2
        for attempt in 1 2 3; do
          wdg_child=$(pgrep -P "$wdg_shell_pid" 2>/dev/null || true)
          [ -z "$wdg_child" ] && break
          kill -9 "$wdg_child" 2>/dev/null || true
          sleep 1
        done
        tmux send-keys -t "$wdg_ref" "clear" Enter 2>/dev/null || true
        sleep 0.5
        wdg_agent=$(generate_team_agent "doey-watchdog" "$tw")
        tmux send-keys -t "$wdg_ref" "claude --dangerously-skip-permissions --model haiku --effort low --name \"T${tw} Watchdog\" --agent \"$wdg_agent\"" Enter
        printf " ${SUCCESS}✓${RESET}\n"

        # Re-brief watchdog after boot
        (
          sleep 12
          tmux send-keys -t "$wdg_ref" \
            "Start monitoring session ${session} window ${tw}. Skip pane ${wdg_pane} (yourself, in Dashboard). Manager is in team window pane ${tw}.0. Monitor panes ${wp_list}." Enter
          sleep 20
          tmux send-keys -t "$wdg_ref" \
            '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
        ) &
      else
        printf " ${WARN}(not found)${RESET}\n"
      fi
    fi
  done

  printf "\n  ${SUCCESS}✓ Manager + Watchdog reloaded${RESET}\n"

  # 7. Optionally restart workers
  if $restart_workers; then
    printf "\n  ${DIM}Restarting workers...${RESET}\n"
    for tw in $team_windows; do
      local team_env="${runtime_dir}/team_${tw}.env"
      [ -f "$team_env" ] || continue
      local worker_panes_csv
      worker_panes_csv=$(grep '^WORKER_PANES=' "$team_env" | cut -d= -f2)
      worker_panes_csv="${worker_panes_csv//\"/}"

      for wp in $(echo "$worker_panes_csv" | tr ',' ' '); do
        local pane_ref="${session}:${tw}.${wp}"
        local shell_pid child_pid
        shell_pid=$(tmux display-message -t "$pane_ref" -p '#{pane_pid}' 2>/dev/null || true)
        [ -z "$shell_pid" ] && continue
        child_pid=$(pgrep -P "$shell_pid" 2>/dev/null || true)

        # Skip already-ready workers
        local output
        output=$(tmux capture-pane -t "$pane_ref" -p 2>/dev/null || true)
        if [ -n "$child_pid" ] && echo "$output" | grep -q "bypass permissions" && echo "$output" | grep -q '❯'; then
          printf "    %s.%s ${DIM}(already ready — skipped)${RESET}\n" "$tw" "$wp"
          continue
        fi

        [ -n "$child_pid" ] && kill "$child_pid" 2>/dev/null || true
        sleep 1
        child_pid=$(pgrep -P "$shell_pid" 2>/dev/null || true)
        [ -n "$child_pid" ] && kill -9 "$child_pid" 2>/dev/null || true
        sleep 0.5

        tmux send-keys -t "$pane_ref" "clear" Enter 2>/dev/null || true
        sleep 0.5

        local w_name
        w_name=$(tmux display-message -t "$pane_ref" -p '#{pane_title}' 2>/dev/null || echo "T${tw} W${wp}")

        local worker_prompt
        worker_prompt=$(grep -rl "pane ${tw}\.${wp} " "${runtime_dir}"/worker-system-prompt-*.md 2>/dev/null | head -1)
        if [ -n "$worker_prompt" ]; then
          tmux send-keys -t "$pane_ref" "claude --dangerously-skip-permissions --model opus --name \"${w_name}\" --append-system-prompt-file \"${worker_prompt}\"" Enter
        else
          tmux send-keys -t "$pane_ref" "claude --dangerously-skip-permissions --model opus --name \"${w_name}\"" Enter
        fi
        printf "    %s.%s ${SUCCESS}✓${RESET}\n" "$tw" "$wp"
        sleep 0.5
      done
    done
    printf "\n  ${SUCCESS}✓ Workers restarted${RESET}\n"
  fi

  printf "\n  ${SUCCESS}✓ Reload complete!${RESET}\n"
  printf "  ${DIM}Hooks + commands take effect immediately (no restart needed).${RESET}\n"
  printf "  ${DIM}Manager + Watchdog relaunched with latest agent definitions.${RESET}\n"
  if ! $restart_workers; then
    printf "  ${DIM}Workers kept running. Use 'doey reload --workers' to restart them too.${RESET}\n"
  fi
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
  rm -f ~/.local/bin/tmux-statusbar.sh
  rm -f ~/.local/bin/pane-border-status.sh
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
# Starts the full team (session, grid, Window Manager, Watchdog, workers) but
# does not print the ASCII banner, summary box, or attach to tmux.

launch_session_headless() {
  local name="$1"
  local dir="$2"
  local grid="${3:-6x2}"
  local cols="${grid%x*}"
  local rows="${grid#*x}"
  local total=$(( cols * rows ))
  local worker_count=$(( total - 1 ))
  local session="doey-${name}"
  local runtime_dir="/tmp/doey/${name}"

  cd "$dir"

  # ── Build worker pane list (pane 0 = Manager, panes 1+ = Workers) ──
  local worker_panes_csv=""
  for (( i=1; i<total; i++ )); do
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
WATCHDOG_PANE="0.2"
WORKER_PANES="$worker_panes_csv"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="500"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
TEAM_WINDOWS="1"
WDG_SLOT_1="0.2"
WDG_SLOT_2="0.3"
WDG_SLOT_3="0.4"
WDG_SLOT_4="0.5"
WDG_SLOT_5="0.6"
WDG_SLOT_6="0.7"
SM_PANE="0.1"
MANIFEST

  # Write per-window team env for window 1 (watchdog in Dashboard slot 0.2, manager in team pane 0)
  write_team_env "$runtime_dir" "1" "$grid" "0.2" "$worker_panes_csv" "$worker_count" "0" "" ""

  write_worker_system_prompt "$runtime_dir" "$name" "$dir"

  tmux new-session -d -s "$session" -x 250 -y 80 -c "$dir" >/dev/null
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"

  # Dashboard window (window 0) — info panel + watchdog slots + session manager
  setup_dashboard "$session" "$dir" "$runtime_dir"

  # Team grid window (window 1)
  local team_window=1
  tmux new-window -t "$session" -c "$dir"

  # ── Apply theme ──
  printf "  ${DIM}Applying theme...${RESET}\n"
  local border_fmt=" #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  apply_doey_theme "$session" "$name" "$border_fmt" 2

  # ── Build grid ──
  printf "  ${DIM}Building ${cols}x${rows} grid (${total} panes)...${RESET}\n"
  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "$session:${team_window}.0" -c "$dir"
  done
  tmux select-layout -t "$session:${team_window}" even-vertical

  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "$session:${team_window}.$((r * cols))" -c "$dir"
    done
  done

  sleep 2

  # Verify pane count
  local actual
  actual=$(tmux list-panes -t "$session:${team_window}" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$actual" -ne "$total" ]]; then
    printf "  ${WARN}⚠ Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total" "$actual"
  fi

  # ── Name panes ──
  printf "  ${DIM}Naming panes...${RESET}\n"
  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  local wnum=0
  for (( i=1; i<total; i++ )); do
    wnum=$((wnum + 1))
    tmux select-pane -t "$session:${team_window}.$i" -T "T${team_window} W${wnum}"
  done
  tmux rename-window -t "$session:${team_window}" "Team ${team_window}"

  # ── Launch Window Manager & Watchdog ──
  printf "  ${DIM}Launching Window Manager & Watchdog...${RESET}\n"

  # Launch Window Manager in team window pane 0
  mgr_agent=$(generate_team_agent "doey-manager" "$team_window")
  tmux send-keys -t "$session:${team_window}.0" \
    "claude --dangerously-skip-permissions --name \"T${team_window} Window Manager\" --agent \"$mgr_agent\"" Enter
  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  sleep 0.5

  write_pane_status "$runtime_dir" "${session}:${team_window}.0" "READY"

  (
    sleep 8
    worker_panes=""
    for (( i=1; i<total; i++ )); do
      [[ -n "$worker_panes" ]] && worker_panes+=", "
      worker_panes+="${team_window}.$i"
    done
    tmux send-keys -t "$session:${team_window}.0" \
      "Team is online (project: ${name}, dir: $dir). You have $((total - 1)) workers in panes ${worker_panes}. Your workers are in window ${team_window}. Watchdog is in Dashboard pane ${WDG_SLOT_1} (monitors workers). Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Brief Session Manager (pane ${SM_PANE}) after it boots
  (
    sleep 15
    tmux send-keys -t "$session:${SM_PANE}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. Team window ${team_window} has $((total - 1)) workers. Use /doey-add-window to create new team windows and /doey-list-windows to see all teams. Awaiting instructions." Enter
  ) &

  # Launch Watchdog in Dashboard slot 1 (pane ${WDG_SLOT_1})
  tmux send-keys -t "$session:${WDG_SLOT_1}" C-c
  sleep 0.3
  wdg_agent=$(generate_team_agent "doey-watchdog" "$team_window")
  tmux send-keys -t "$session:${WDG_SLOT_1}" \
    "claude --dangerously-skip-permissions --model haiku --effort low --name \"T${team_window} Watchdog\" --agent \"$wdg_agent\"" Enter
  tmux select-pane -t "$session:${WDG_SLOT_1}" -T "T${team_window} Watchdog"
  sleep 0.5

  (
    sleep 12
    watch_panes=""
    for (( i=1; i<total; i++ )); do
      [[ -n "$watch_panes" ]] && watch_panes+=", "
      watch_panes+="${team_window}.$i"
    done
    tmux send-keys -t "$session:${WDG_SLOT_1}" \
      "Start monitoring session $session. Total panes: $total. Skip pane ${WDG_SLOT_1} (yourself, in Dashboard). Manager is in team window pane ${team_window}.0. Monitor panes ${watch_panes}." Enter
    # Schedule periodic compact to keep Watchdog context lean
    sleep 20
    tmux send-keys -t "$session:${WDG_SLOT_1}" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &

  # Clean up background jobs on early exit
  trap 'jobs -p | xargs kill 2>/dev/null' EXIT INT TERM

  # ── Boot workers ──
  printf "  ${DIM}Booting ${worker_count} workers...${RESET}\n"
  local booted=0
  for (( i=1; i<total; i++ )); do
    booted=$((booted + 1))

    local worker_prompt_file="${runtime_dir}/worker-system-prompt-${booted}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file"
    printf '\n\n## Identity\nYou are Worker %s in pane %s.%s of session %s.\n' "$booted" "$team_window" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus --name \"T${team_window} W${booted}\""
    worker_cmd+=" --append-system-prompt-file \"${worker_prompt_file}\""
    tmux send-keys -t "$session:${team_window}.$i" "$worker_cmd" Enter
    sleep 0.3

    write_pane_status "$runtime_dir" "${session}:${team_window}.${i}" "READY"
  done

  # Clear the trap — background briefing jobs should complete normally
  trap - EXIT INT TERM
  tmux select-window -t "$session:0"
  printf "  ${SUCCESS}Team launched${RESET} — session ${BOLD}%s${RESET} with %s workers\n" "$session" "$worker_count"
}

# ── Dynamic Grid — 2-row × N-column mode ─────────────────────────────
# Creates a Manager-only pane, then adds 3 worker columns (6 workers default).
# Columns added/removed on demand via `doey add` / `doey remove <col>`.

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
  local initial_workers=$(( INITIAL_WORKER_COLS * 2 ))
  printf "   ${DIM}Project${RESET} ${BOLD}${name}${RESET}  ${DIM}Grid${RESET} ${BOLD}dynamic${RESET}  ${DIM}Workers${RESET} ${BOLD}${initial_workers} (auto-expands)${RESET}\n"
  printf "   ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}  ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  # ── Pre-accept trust for project directory ───────────────────
  ensure_project_trusted "$dir"

  # ── Step 1: Create session ─────────────────────────────────────
  step_start 1 "Creating session for ${name}..."
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}

  # Generate shared worker system prompt
  write_worker_system_prompt "$runtime_dir" "$name" "$dir"

  tmux new-session -d -s "$session" -x 250 -y 80 -c "$dir" >/dev/null
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"

  # Dashboard window (window 0) — info panel + watchdog slots + session manager
  setup_dashboard "$session" "$dir" "$runtime_dir"

  # Team grid window (window 1)
  local team_window=1
  tmux new-window -t "$session" -c "$dir"

  step_done

  # ── Step 2: Apply theme ────────────────────────────────────────
  step_start 2 "Applying theme..."
  local border_fmt=' #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#{pane_title} #[default]'
  apply_doey_theme "$session" "$name" "$border_fmt" 5
  step_done

  # ── Step 3: Build initial grid (Manager only — Watchdog lives in Dashboard)
  step_start 3 "Building grid..."

  # Single pane: Manager (watchdog is in Dashboard slot)
  # No split needed — pane 0 IS the manager
  sleep 0.5

  step_done

  # ── Step 4: Name panes ─────────────────────────────────────────
  step_start 4 "Naming panes..."

  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  tmux rename-window -t "$session:${team_window}" "Team ${team_window}"

  step_done

  # ── Step 5: Write session.env ──────────────────────────────────
  step_start 5 "Writing session manifest..."

  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR="$dir"
PROJECT_NAME="$name"
SESSION_NAME="$session"
GRID="dynamic"
ROWS="2"
MAX_WORKERS="$max_workers"
WORKER_PANES=""
WORKER_COUNT="0"
WATCHDOG_PANE="0.2"
CURRENT_COLS="1"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="500"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
TEAM_WINDOWS="1"
WDG_SLOT_1="0.2"
WDG_SLOT_2="0.3"
WDG_SLOT_3="0.4"
WDG_SLOT_4="0.5"
WDG_SLOT_5="0.6"
WDG_SLOT_6="0.7"
SM_PANE="0.1"
MANIFEST

  # Write per-window team env for window 1 (watchdog in Dashboard slot 0.2, manager in team pane 0)
  write_team_env "$runtime_dir" "1" "dynamic" "0.2" "" "0" "0" "" ""

  step_done

  # ── Step 6: Launch Window Manager & Watchdog ──────────────────
  step_start 6 "Launching Window Manager & Watchdog..."

  # Launch Window Manager in team window pane 0
  mgr_agent=$(generate_team_agent "doey-manager" "$team_window")
  tmux send-keys -t "$session:${team_window}.0" \
    "claude --dangerously-skip-permissions --name \"T${team_window} Window Manager\" --agent \"$mgr_agent\"" Enter
  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  sleep 0.5

  # Send initial briefing once Window Manager is ready
  (
    sleep 8
    tmux send-keys -t "$session:${team_window}.0" \
      "Team is online (project: ${name}, dir: $dir). Dynamic grid — started with ${initial_workers} workers, auto-expands when all are busy. Use doey add to add more. Your workers are in window ${team_window}. Watchdog is in Dashboard pane ${WDG_SLOT_1}. Session: $session. All workers are idle and awaiting tasks." Enter
  ) &

  # Session Manager briefing deferred until all teams are created (after step 8)

  # Launch Watchdog in Dashboard slot 1 (pane ${WDG_SLOT_1})
  tmux send-keys -t "$session:${WDG_SLOT_1}" C-c
  sleep 0.3
  wdg_agent=$(generate_team_agent "doey-watchdog" "$team_window")
  tmux send-keys -t "$session:${WDG_SLOT_1}" \
    "claude --dangerously-skip-permissions --model haiku --effort low --name \"T${team_window} Watchdog\" --agent \"$wdg_agent\"" Enter
  tmux select-pane -t "$session:${WDG_SLOT_1}" -T "T${team_window} Watchdog"
  sleep 0.5

  # Auto-start watchdog loop (no workers to monitor yet)
  (
    sleep 12
    tmux send-keys -t "$session:${WDG_SLOT_1}" \
      "Start monitoring session $session. Dynamic grid — ${initial_workers} initial workers, auto-expands when all are busy. Skip pane ${WDG_SLOT_1} (yourself, in Dashboard). Manager is in team window pane ${team_window}.0. Monitor all worker panes for status changes." Enter
    sleep 20
    tmux send-keys -t "$session:${WDG_SLOT_1}" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &

  step_done

  # ── Step 7: Add initial worker columns ──────────────────────────
  STEP_TOTAL=9
  step_start 7 "Adding ${INITIAL_WORKER_COLS} worker columns (${initial_workers} workers)..."

  # Wait for Window Manager/Watchdog to settle before adding columns
  sleep 3

  local _col_i
  for (( _col_i=0; _col_i<INITIAL_WORKER_COLS; _col_i++ )); do
    doey_add_column "$session" "$runtime_dir" "$dir"
    (( _col_i < INITIAL_WORKER_COLS - 1 )) && sleep 1
  done

  step_done

  # ── Step 8: Add additional team windows ────────────────────────────
  local _extra_teams=$((INITIAL_TEAMS - 1))
  if [ "$_extra_teams" -gt 0 ]; then
    STEP_TOTAL=9
    step_start 8 "Adding ${_extra_teams} more team windows..."

    local _team_i
    for (( _team_i=0; _team_i<_extra_teams; _team_i++ )); do
      add_dynamic_team_window "$session" "$runtime_dir" "$dir"
      (( _team_i < _extra_teams - 1 )) && sleep 2
    done

    step_done
  fi

  # ── Step 9: Add isolated worktree teams ─────────────────────────
  STEP_TOTAL=9
  local INITIAL_WORKTREE_TEAMS=2
  step_start 9 "Adding ${INITIAL_WORKTREE_TEAMS} isolated worktree teams..."
  local _wt_i _wt_ok=0
  for (( _wt_i=0; _wt_i<INITIAL_WORKTREE_TEAMS; _wt_i++ )); do
    if add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$INITIAL_WORKER_COLS" "auto"; then
      _wt_ok=$((_wt_ok + 1))
    fi
    (( _wt_i < INITIAL_WORKTREE_TEAMS - 1 )) && sleep 2
  done
  if [ "$_wt_ok" -gt 0 ]; then
    step_done
  else
    printf "${WARN}skipped${RESET}\n"
  fi

  # Read final team windows list for summary
  local final_team_windows
  final_team_windows=$(read_team_windows "$runtime_dir")
  local team_count=0
  local _tw
  for _tw in $(echo "$final_team_windows" | tr ',' ' '); do
    team_count=$((team_count + 1))
  done

  # Re-brief Session Manager with all teams
  (
    sleep 20
    tmux send-keys -t "$session:${SM_PANE}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. ${team_count} team windows (${final_team_windows}). Team 1 has ${initial_workers} workers (dynamic grid, auto-expands). Use /doey-add-window to create new team windows and /doey-list-windows to see all teams. Awaiting instructions." Enter
  ) &

  # ── Final summary ──────────────────────────────────────────────
  printf '\n'
  printf "   ${DIM}┌─────────────────────────────────────────────────┐${RESET}\n"
  printf "   ${DIM}│${RESET}  ${SUCCESS}Doey is ready${RESET}  ${DIM}(dynamic grid)${RESET}                ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Dashboard${RESET}  ${DIM}win 0${RESET} Info panel + Session Manager  ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Teams${RESET}      ${DIM}%-4s${RESET} ${DIM}windows (${final_team_windows})${RESET}              ${DIM}│${RESET}\n" "$team_count"
  printf "   ${DIM}│${RESET}  ${BOLD}Watchdogs${RESET}  ${DIM}0.2-0.7${RESET} ${DIM}Online (Dashboard)${RESET}          ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${BOLD}Workers${RESET}    ${DIM}T1: %-4s${RESET} ${DIM}(auto-expands, doey add)${RESET}  ${DIM}│${RESET}\n" "$initial_workers"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Project${RESET}   ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "$name"
  printf "   ${DIM}│${RESET}  ${DIM}Grid${RESET}      ${BOLD}dynamic${RESET}  ${DIM}Max workers${RESET}  ${BOLD}%-13s${RESET} ${DIM}│${RESET}\n" "$max_workers"
  printf "   ${DIM}│${RESET}  ${DIM}Session${RESET}   ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "$session"
  printf "   ${DIM}│${RESET}  ${DIM}Manifest${RESET}  ${BOLD}%-38s${RESET} ${DIM}│${RESET}\n" "${runtime_dir}/session.env"
  printf "   ${DIM}│${RESET}                                                 ${DIM}│${RESET}\n"
  printf "   ${DIM}│${RESET}  ${DIM}Tip: doey add — adds 2 more workers${RESET}            ${DIM}│${RESET}\n"
  printf "   ${DIM}└─────────────────────────────────────────────────┘${RESET}\n"
  printf '\n'

  # ── Focus on Dashboard window, attach ──────────────────────────────
  tmux select-window -t "$session:0"
  attach_or_switch "$session"
}

# ── Add a worker column to a dynamic grid session ────────────────────

# Compute tmux layout checksum (rotating 16-bit sum)
_layout_checksum() {
  local s="$1" csum=0 i c
  for ((i=0; i<${#s}; i++)); do
    c=$(printf '%d' "'${s:$i:1}")
    csum=$(( ((csum >> 1) + ((csum & 1) << 15) + c) & 0xffff ))
  done
  printf '%04x' "$csum"
}

# Generate and apply a Manager-aware column layout.
# Pane 0 is the Manager — gets a narrow full-height column on the left.
# Remaining panes are workers — paired into equal-width 2-row columns.
# Handles odd worker counts (last column gets 1 full-height pane).
rebalance_grid_layout() {
  local session="$1"
  local team_window="${2:-1}"
  local mgr_width=60  # Fixed width for Manager column

  local win_w win_h
  win_w="$(tmux display-message -t "$session:${team_window}" -p '#{window_width}')"
  win_h="$(tmux display-message -t "$session:${team_window}" -p '#{window_height}')"

  # Collect pane IDs in index order
  local pane_ids=()
  while IFS=$'\t' read -r _idx _pid; do
    pane_ids+=("${_pid#%}")
  done < <(tmux list-panes -t "$session:${team_window}" -F '#{pane_index}	#{pane_id}')

  local num_panes=${#pane_ids[@]}
  # Need at least Manager + 2 workers to do anything useful
  if (( num_panes < 3 )); then return 0; fi

  local num_workers=$((num_panes - 1))
  local worker_cols=$(( (num_workers + 1) / 2 ))  # ceiling division for odd counts

  # Ensure Manager column doesn't eat too much space (cap at 25% of window)
  local max_mgr=$((win_w / 4))
  if (( mgr_width > max_mgr )); then
    mgr_width=$max_mgr
  fi

  local worker_area=$((win_w - mgr_width - 1))  # -1 for border between mgr and workers
  local top_h=$((win_h / 2))
  local bot_h=$((win_h - top_h - 1))

  # Build layout string: Manager column first, then worker columns
  local body="" x=0

  # Manager column: single pane, full height
  local mgr_id="${pane_ids[0]}"
  body="${mgr_width}x${win_h},${x},0,${mgr_id}"
  x=$((mgr_width + 1))

  # Worker columns: each has 2 rows (top + bottom worker)
  local c w wi
  for ((c=0; c<worker_cols; c++)); do
    if ((c == worker_cols - 1)); then
      w=$((win_w - x))  # last column gets remaining width
    else
      w=$((worker_area / worker_cols))
    fi

    wi=$((c * 2 + 1))  # worker pane index (1-based, skipping Manager)
    local tp="${pane_ids[$wi]}"

    body+=","
    if (( wi + 1 < num_panes )); then
      # Normal column: 2 workers (top + bottom)
      local bp="${pane_ids[$((wi + 1))]}"
      body+="${w}x${win_h},${x},0[${w}x${top_h},${x},0,${tp},${w}x${bot_h},${x},$((top_h+1)),${bp}]"
    else
      # Odd worker count: last column has 1 worker at full height
      body+="${w}x${win_h},${x},0,${tp}"
    fi
    x=$((x + w + 1))
  done

  local layout_str="${win_w}x${win_h},0,0{${body}}"
  local csum
  csum="$(_layout_checksum "$layout_str")"
  tmux select-layout -t "$session:${team_window}" "${csum},${layout_str}" 2>/dev/null || true
}

# Rebuild pane state from tmux pane list.
# Pane 0 = Manager, all others = workers (titles are unreliable — Claude Code overwrites them).
# Sets: _wdg_pane, _worker_panes
rebuild_pane_state() {
  local session="$1"
  _wdg_pane=""
  _worker_panes=""

  local pidx
  while IFS='' read -r pidx; do
    # Skip pane 0 (Manager)
    [ "$pidx" = "0" ] && continue
    [ -n "$_worker_panes" ] && _worker_panes+=","
    _worker_panes+="$pidx"
  done < <(tmux list-panes -t "$session" -F '#{pane_index}')
}

doey_add_column() {
  local session="$1"
  local runtime_dir="$2"
  local dir="$3"
  local team_window="${4:-1}"

  # Source session-level settings
  safe_source_session_env "${runtime_dir}/session.env"

  local max_workers="${MAX_WORKERS:-20}"
  local name="${PROJECT_NAME}"

  # Read team-level state from team env (falls back to session.env for team 1 compat)
  local team_env="${runtime_dir}/team_${team_window}.env"
  local worker_count=0 watchdog_pane="${WATCHDOG_PANE}" current_cols="${CURRENT_COLS:-1}" team_grid="${GRID:-dynamic}"
  if [ -f "$team_env" ]; then
    worker_count=$(grep '^WORKER_COUNT=' "$team_env" | cut -d= -f2)
    worker_count="${worker_count//\"/}"
    worker_count="${worker_count:-0}"
    watchdog_pane=$(grep '^WATCHDOG_PANE=' "$team_env" | cut -d= -f2)
    watchdog_pane="${watchdog_pane//\"/}"
    team_grid=$(grep '^GRID=' "$team_env" | cut -d= -f2)
    team_grid="${team_grid//\"/}"
    team_grid="${team_grid:-dynamic}"
    # Count current columns from pane count: (panes - 1 manager) / 2 rows + 1 for manager col
    local _pane_count
    _pane_count=$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l | tr -d ' ')
    current_cols=$(( (_pane_count - 1) / 2 ))
    [ "$current_cols" -lt 1 ] && current_cols=1
  fi

  # Check if this team uses a worktree; if so, use worktree path for new panes
  local team_dir="$dir"
  if [ -f "$team_env" ]; then
    local _wt_dir
    _wt_dir=$(grep '^WORKTREE_DIR=' "$team_env" | cut -d= -f2- | tr -d '"')
    if [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ]; then
      team_dir="$_wt_dir"
    fi
  fi

  if [[ "$team_grid" != "dynamic" ]]; then
    printf "  ${ERROR}Team window %s is not using dynamic grid mode${RESET}\n" "$team_window"
    return 1
  fi

  if (( worker_count >= max_workers )); then
    printf "  ${ERROR}Max workers reached (${max_workers})${RESET}\n"
    return 1
  fi

  printf "  ${DIM}Adding worker column to team %s...${RESET}\n" "$team_window"

  # Strategy: split the last pane horizontally (adds column on the right),
  # then split that new pane vertically for 2 worker rows.
  local last_pane
  last_pane="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"
  tmux split-window -h -t "$session:$team_window.${last_pane}" -c "$team_dir"
  sleep 0.3

  # The new pane is the new last pane
  local new_pane_top
  new_pane_top="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"
  tmux split-window -v -t "$session:$team_window.${new_pane_top}" -c "$team_dir"
  sleep 0.3

  # Bottom pane is now the last pane
  local new_pane_bottom
  new_pane_bottom="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"

  # Determine new worker numbers
  local w1_num=$(( worker_count + 1 ))
  local w2_num=$(( worker_count + 2 ))

  # Name the new worker panes
  tmux select-pane -t "$session:$team_window.${new_pane_top}" -T "T${team_window} W${w1_num}"
  tmux select-pane -t "$session:$team_window.${new_pane_bottom}" -T "T${team_window} W${w2_num}"

  # Rebuild worker pane list from titles
  rebuild_pane_state "$session:$team_window"
  local new_worker_panes="$_worker_panes"

  local new_worker_count=$(( worker_count + 2 ))
  local new_cols=$(( current_cols + 1 ))

  # Preserve existing worktree fields
  local _existing_wt_dir=""
  local _existing_wt_branch=""
  if [ -f "$team_env" ]; then
    _existing_wt_dir=$(grep '^WORKTREE_DIR=' "$team_env" | cut -d= -f2- | tr -d '"')
    _existing_wt_branch=$(grep '^WORKTREE_BRANCH=' "$team_env" | cut -d= -f2- | tr -d '"')
  fi

  # Update team env with new worker state
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$watchdog_pane" "$new_worker_panes" "$new_worker_count" "" "$_existing_wt_dir" "$_existing_wt_branch"

  # Launch Claude in both new panes
  local worker_prompt_file_1="${runtime_dir}/worker-system-prompt-w${team_window}-${w1_num}.md"
  cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file_1"
  printf '\n\n## Identity\nYou are Worker %s in pane %s.%s of session %s.\n' \
    "$w1_num" "$team_window" "$new_pane_top" "$session" >> "$worker_prompt_file_1"

  local worker_cmd="claude --dangerously-skip-permissions --model opus --name \"T${team_window} W${w1_num}\""
  worker_cmd+=" --append-system-prompt-file \"${worker_prompt_file_1}\""
  tmux send-keys -t "$session:$team_window.${new_pane_top}" "$worker_cmd" Enter
  sleep 0.3

  local worker_prompt_file_2="${runtime_dir}/worker-system-prompt-w${team_window}-${w2_num}.md"
  cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file_2"
  printf '\n\n## Identity\nYou are Worker %s in pane %s.%s of session %s.\n' \
    "$w2_num" "$team_window" "$new_pane_bottom" "$session" >> "$worker_prompt_file_2"

  local worker_cmd2="claude --dangerously-skip-permissions --model opus --name \"T${team_window} W${w2_num}\""
  worker_cmd2+=" --append-system-prompt-file \"${worker_prompt_file_2}\""
  tmux send-keys -t "$session:$team_window.${new_pane_bottom}" "$worker_cmd2" Enter

  # Rebalance to proper column layout (each column = 2 rows)
  rebalance_grid_layout "$session" "$team_window"

  printf "  ${SUCCESS}Added${RESET} workers ${BOLD}W${w1_num}${RESET} (${team_window}.${new_pane_top}) and ${BOLD}W${w2_num}${RESET} (${team_window}.${new_pane_bottom})\n"
  printf "  ${DIM}Total workers: ${new_worker_count} in ${new_cols} columns${RESET}\n"
}

# ── Remove a worker column from a dynamic grid session ───────────────
doey_remove_column() {
  local session="$1"
  local runtime_dir="$2"
  local col_index="${3:-}"
  local team_window="${4:-1}"

  # Source session-level settings (for PROJECT_NAME, PROJECT_DIR, MAX_WORKERS)
  safe_source_session_env "${runtime_dir}/session.env"

  local name="${PROJECT_NAME}"
  local dir="${PROJECT_DIR}"

  # Read team-level state from team env (same pattern as doey_add_column)
  local team_env="${runtime_dir}/team_${team_window}.env"
  local worker_count=0 watchdog_pane="" current_cols=2 team_grid="${GRID:-dynamic}" team_worker_panes=""
  if [ -f "$team_env" ]; then
    worker_count=$(grep '^WORKER_COUNT=' "$team_env" | cut -d= -f2)
    worker_count="${worker_count//\"/}"
    worker_count="${worker_count:-0}"
    watchdog_pane=$(grep '^WATCHDOG_PANE=' "$team_env" | cut -d= -f2)
    watchdog_pane="${watchdog_pane//\"/}"
    team_grid=$(grep '^GRID=' "$team_env" | cut -d= -f2)
    team_grid="${team_grid//\"/}"
    team_grid="${team_grid:-dynamic}"
    team_worker_panes=$(grep '^WORKER_PANES=' "$team_env" | cut -d= -f2)
    team_worker_panes="${team_worker_panes//\"/}"
    # Count current columns from pane count
    local _pane_count
    _pane_count=$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l | tr -d ' ')
    current_cols=$(( (_pane_count - 1) / 2 ))
    [ "$current_cols" -lt 1 ] && current_cols=1
  fi

  if [[ "$team_grid" != "dynamic" ]]; then
    printf "  ${ERROR}Team window %s is not using dynamic grid mode${RESET}\n" "$team_window"
    return 1
  fi

  if (( worker_count == 0 )); then
    printf "  ${ERROR}No worker columns to remove${RESET}\n"
    return 1
  fi

  # If no column specified, remove the last worker column
  if [[ -z "$col_index" ]]; then
    col_index="last"
  fi

  # Find worker panes to remove
  # Workers are listed in WORKER_PANES as comma-separated indices
  # Each column has 2 workers (top + bottom), added as consecutive pairs
  # Convert comma-separated WORKER_PANES to positional params (bash 3.2 safe)
  local _old_ifs="$IFS"
  IFS=','
  set -- $team_worker_panes
  IFS="$_old_ifs"
  local wp_count=$#

  if [ "$wp_count" -lt 2 ]; then
    printf "  ${ERROR}Not enough worker panes to remove a column${RESET}\n"
    return 1
  fi

  # Determine which 2 panes to remove
  local remove_top remove_bottom
  if [ "$col_index" = "last" ]; then
    # Remove the last two entries (last column added)
    eval "remove_top=\${$(( wp_count - 1 ))}"
    eval "remove_bottom=\${${wp_count}}"
  else
    # Remove specific column by position (1-indexed among worker columns)
    local ci=$(( col_index ))
    if [ "$ci" -lt 1 ] || [ "$ci" -gt $(( worker_count / 2 )) ]; then
      printf "  ${ERROR}Invalid worker column: ${col_index} (valid: 1-$(( worker_count / 2 )))${RESET}\n"
      return 1
    fi
    local pair_start=$(( (ci - 1) * 2 + 1 ))
    eval "remove_top=\${${pair_start}}"
    eval "remove_bottom=\${$(( pair_start + 1 ))}"
  fi

  printf "  ${DIM}Removing worker panes ${team_window}.${remove_top} and ${team_window}.${remove_bottom}...${RESET}\n"

  # Kill Claude processes in the target panes
  for pane_idx in "$remove_top" "$remove_bottom"; do
    local pane_pid
    pane_pid=$(tmux display-message -t "$session:$team_window.${pane_idx}" -p '#{pane_pid}' 2>/dev/null || true)
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
  tmux kill-pane -t "$session:$team_window.${first_kill}" 2>/dev/null || true
  tmux kill-pane -t "$session:$team_window.${second_kill}" 2>/dev/null || true
  sleep 0.5

  # After killing panes, ALL indices shift — must re-read everything
  rebuild_pane_state "$session:$team_window"
  local new_worker_panes="$_worker_panes"

  local new_worker_count=$(( worker_count - 2 ))
  local new_cols=$(( current_cols - 1 ))

  # Preserve existing worktree fields
  local _existing_wt_dir=""
  local _existing_wt_branch=""
  if [ -f "$team_env" ]; then
    _existing_wt_dir=$(grep '^WORKTREE_DIR=' "$team_env" | cut -d= -f2- | tr -d '"')
    _existing_wt_branch=$(grep '^WORKTREE_BRANCH=' "$team_env" | cut -d= -f2- | tr -d '"')
  fi

  # Update team env only (session.env is session-level, not per-team)
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$watchdog_pane" "$new_worker_panes" "$new_worker_count" "" "$_existing_wt_dir" "$_existing_wt_branch"

  # Rebalance to proper column layout (each column = 2 rows)
  rebalance_grid_layout "$session" "$team_window"

  printf "  ${SUCCESS}Removed${RESET} worker column — ${BOLD}${new_worker_count}${RESET} workers remaining\n"
}

# ── Team Window Lifecycle ─────────────────────────────────────────────

# Add a new team window with its own Window Manager, Watchdog, and Workers
# Usage: add_team_window <session> <runtime_dir> <dir> [grid]
# Add a dynamic-grid team window (Manager only, then add worker columns)
# Usage: add_dynamic_team_window <session> <runtime_dir> <dir> [initial_cols]
add_dynamic_team_window() {
  local session="$1" runtime_dir="$2" dir="$3" initial_cols="${4:-$INITIAL_WORKER_COLS}"
  local worktree_spec="${5:-}"

  # Create worktree if requested
  local team_dir="$dir"
  local worktree_branch=""
  local wt_dir_for_env=""

  # Create new window with just the Manager pane (need window_index first for worktree)
  tmux new-window -t "$session" -c "$dir"
  sleep 0.5
  local window_index
  window_index=$(tmux display-message -t "$session" -p '#{window_index}')

  # Set up worktree if requested (now that we know window_index)
  if [ -n "$worktree_spec" ]; then
    # "auto" means auto-generate branch name; anything else is a literal branch name
    local _wt_branch_arg=""
    if [ "$worktree_spec" != "auto" ]; then
      _wt_branch_arg="$worktree_spec"
    fi
    team_dir=$(create_team_worktree "$dir" "$window_index" "$_wt_branch_arg") || {
      printf "  ${WARN}Worktree creation failed for team %s — falling back to shared repo${RESET}\n" "$window_index"
      team_dir="$dir"
      worktree_spec=""
    }
    if [ -n "$worktree_spec" ]; then
      worktree_branch=$(git -C "$team_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "doey/team-${window_index}")
      wt_dir_for_env="$team_dir"
    fi
  fi

  if [ -n "$wt_dir_for_env" ]; then
    printf "  ${DIM}Creating dynamic team window %s [worktree: %s]...${RESET}\n" "$window_index" "$worktree_branch"
  else
    printf "  ${DIM}Creating dynamic team window %s...${RESET}\n" "$window_index"
  fi

  # Apply pane border theme to the new window
  local border_fmt=" #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  tmux set-window-option -t "${session}:${window_index}" pane-border-status top
  tmux set-window-option -t "${session}:${window_index}" pane-border-format "$border_fmt"
  tmux set-window-option -t "${session}:${window_index}" pane-border-style 'fg=colour238'
  tmux set-window-option -t "${session}:${window_index}" pane-active-border-style 'fg=cyan'
  tmux set-window-option -t "${session}:${window_index}" pane-border-lines heavy

  # Name Manager pane and window
  tmux select-pane -t "${session}:${window_index}.0" -T "T${window_index} Window Manager"
  if [ -n "$wt_dir_for_env" ]; then
    tmux rename-window -t "${session}:${window_index}" "T${window_index} [wt]"
  else
    tmux rename-window -t "${session}:${window_index}" "Team ${window_index}"
  fi

  # Find next available Dashboard watchdog slot
  local wdg_slot=""
  local slot_key=""
  local sn
  for sn in 1 2 3 4 5 6; do
    local slot_val=""
    slot_val=$(grep "^WDG_SLOT_${sn}=" "${runtime_dir}/session.env" | cut -d= -f2)
    slot_val="${slot_val//\"/}"
    # Check if this slot is already claimed by an existing team
    local slot_taken=""
    local tf
    for tf in "${runtime_dir}"/team_*.env; do
      [ -f "$tf" ] || continue
      local tf_wdg
      tf_wdg=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2)
      tf_wdg="${tf_wdg//\"/}"
      if [ "$tf_wdg" = "$slot_val" ]; then
        slot_taken="yes"
        break
      fi
    done
    if [ -z "$slot_taken" ]; then
      wdg_slot="$slot_val"
      slot_key="$sn"
      break
    fi
  done

  if [ -z "$wdg_slot" ]; then
    printf "  ${WARN}All 3 Dashboard watchdog slots are occupied — team %s will run without a Watchdog${RESET}\n" "$window_index"
  fi

  # Write team env with dynamic grid, 0 workers initially
  write_team_env "$runtime_dir" "$window_index" "dynamic" "${wdg_slot:-}" "" "0" "0" "$wt_dir_for_env" "$worktree_branch"

  # Update session.env TEAM_WINDOWS (atomic)
  local current_windows
  current_windows=$(read_team_windows "$runtime_dir")
  local new_windows="${current_windows},${window_index}"
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=\"${new_windows}\"/" "${runtime_dir}/session.env" > "${runtime_dir}/session.env.tmp"
  mv "${runtime_dir}/session.env.tmp" "${runtime_dir}/session.env"

  # Ensure shared worker system prompt exists
  if [ ! -f "${runtime_dir}/worker-system-prompt.md" ]; then
    local project_name
    project_name=$(grep '^PROJECT_NAME=' "${runtime_dir}/session.env" | cut -d= -f2)
    project_name="${project_name//\"/}"
    write_worker_system_prompt "$runtime_dir" "$project_name" "$team_dir"
  fi

  # Launch Window Manager in team window pane 0
  mgr_agent=$(generate_team_agent "doey-manager" "$window_index")
  tmux send-keys -t "${session}:${window_index}.0" \
    "claude --dangerously-skip-permissions --name \"T${window_index} Window Manager\" --agent \"$mgr_agent\"" Enter
  tmux select-pane -t "${session}:${window_index}.0" -T "T${window_index} Window Manager"
  sleep 0.5

  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"

  # Launch Watchdog in Dashboard slot (if available)
  if [ -n "$wdg_slot" ]; then
    tmux send-keys -t "${session}:${wdg_slot}" C-c
    sleep 0.3
    wdg_agent=$(generate_team_agent "doey-watchdog" "$window_index")
    tmux send-keys -t "${session}:${wdg_slot}" \
      "claude --dangerously-skip-permissions --model haiku --effort low --name \"T${window_index} Watchdog\" --agent \"$wdg_agent\"" Enter
    tmux select-pane -t "${session}:${wdg_slot}" -T "T${window_index} Watchdog"
    sleep 0.5
  fi

  # Add initial worker columns
  local _col_i
  for (( _col_i=0; _col_i<initial_cols; _col_i++ )); do
    doey_add_column "$session" "$runtime_dir" "$team_dir" "$window_index"
    (( _col_i < initial_cols - 1 )) && sleep 1
  done

  # Build worker pane list for briefings
  local wp_list=""
  local _pi
  local _pane_list
  _pane_list=$(tmux list-panes -t "${session}:${window_index}" -F '#{pane_index}')
  for _pi in $_pane_list; do
    [ "$_pi" = "0" ] && continue
    [ -n "$wp_list" ] && wp_list="${wp_list}, "
    wp_list="${wp_list}${window_index}.${_pi}"
  done
  local worker_count
  worker_count=$(grep '^WORKER_COUNT=' "${runtime_dir}/team_${window_index}.env" | cut -d= -f2)
  worker_count="${worker_count//\"/}"

  # Brief the new Window Manager after boot
  local _wt_brief=""
  if [ -n "$wt_dir_for_env" ]; then
    _wt_brief=" ISOLATED WORKTREE: branch ${worktree_branch}, dir ${wt_dir_for_env}. Workers operate on this isolated copy — changes do NOT affect the main repo until merged."
  fi
  local _wdg_brief=""
  if [ -n "$wdg_slot" ]; then
    _wdg_brief="Watchdog is in Dashboard pane ${wdg_slot}."
  else
    _wdg_brief="No Watchdog assigned (all Dashboard slots occupied)."
  fi
  (
    sleep 8
    tmux send-keys -t "${session}:${window_index}.0" \
      "Team is online in window ${window_index}. Dynamic grid — ${worker_count} workers, auto-expands when all are busy. Your workers are in panes ${wp_list}. ${_wdg_brief} Session: ${session}.${_wt_brief} All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Start watchdog monitoring (if watchdog was launched)
  if [ -n "$wdg_slot" ]; then
    (
      sleep 12
      tmux send-keys -t "${session}:${wdg_slot}" \
        "Start monitoring session ${session} window ${window_index}. Dynamic grid — auto-expands when all are busy. Skip pane ${wdg_slot} (yourself, in Dashboard). Manager is in team window pane ${window_index}.0. Monitor panes ${wp_list}." Enter
      sleep 20
      tmux send-keys -t "${session}:${wdg_slot}" \
        '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
    ) &
  fi

  if [ -n "$wt_dir_for_env" ]; then
    printf "  ${SUCCESS}Team window %s created${RESET} — dynamic grid, %s workers, ${BOLD}worktree${RESET} (%s)\n" "$window_index" "$worker_count" "$worktree_branch"
  else
    printf "  ${SUCCESS}Team window %s created${RESET} — dynamic grid, %s workers, watchdog in Dashboard slot %s\n" "$window_index" "$worker_count" "$slot_key"
  fi
}

add_team_window() {
  local session="$1" runtime_dir="$2" dir="$3" grid="${4:-4x2}"
  local worktree_spec="${5:-}"
  local cols rows total_panes watchdog_pane worker_panes worker_count

  cols="${grid%x*}"
  rows="${grid#*x}"
  total_panes=$((cols * rows))

  if [ "$total_panes" -lt 3 ]; then
    printf "  ${ERROR}Grid %s too small — need at least 3 panes (Window Manager + Watchdog + 1 Worker)${RESET}\n" "$grid"
    return 1
  fi

  # Create new window
  tmux new-window -t "$session" -c "$dir"
  sleep 0.5
  local window_index
  window_index=$(tmux display-message -t "$session" -p '#{window_index}')

  # Set up worktree if requested (now that we know window_index)
  local team_dir="$dir"
  local worktree_branch=""
  local wt_dir_for_env=""
  if [ -n "$worktree_spec" ]; then
    team_dir=$(create_team_worktree "$dir" "$window_index" "$worktree_spec") || {
      echo "Error: Failed to create worktree for team window $window_index" >&2
      tmux kill-window -t "${session}:${window_index}" 2>/dev/null
      return 1
    }
    worktree_branch=$(git -C "$team_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$worktree_spec")
    wt_dir_for_env="$team_dir"
  fi

  printf "  ${DIM}Creating team window %s (%s grid, %s panes)...${RESET}\n" "$window_index" "$grid" "$total_panes"

  # Apply pane border theme to the new window
  local border_fmt=" #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  tmux set-window-option -t "${session}:${window_index}" pane-border-status top
  tmux set-window-option -t "${session}:${window_index}" pane-border-format "$border_fmt"
  tmux set-window-option -t "${session}:${window_index}" pane-border-style 'fg=colour238'
  tmux set-window-option -t "${session}:${window_index}" pane-active-border-style 'fg=cyan'
  tmux set-window-option -t "${session}:${window_index}" pane-border-lines heavy

  # Build grid: pane 0 already exists from new-window
  # First create rows by splitting vertically
  local r
  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "${session}:${window_index}.0" -c "$team_dir"
  done
  if [ "$rows" -gt 1 ]; then
    tmux select-layout -t "${session}:${window_index}" even-vertical
  fi

  # Then create columns within each row
  local c
  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "${session}:${window_index}.$((r * cols))" -c "$team_dir"
    done
  done

  sleep 1

  # Verify pane count
  local actual
  actual=$(tmux list-panes -t "${session}:${window_index}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$actual" -ne "$total_panes" ]; then
    printf "  ${WARN}Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total_panes" "$actual"
  fi

  # Pane assignments: 0=Manager, 1+=Workers (Watchdog lives in Dashboard)
  worker_panes=""
  worker_count=0
  local i
  for (( i=1; i<total_panes; i++ )); do
    [ -n "$worker_panes" ] && worker_panes="${worker_panes},"
    worker_panes="${worker_panes}${i}"
    worker_count=$((worker_count + 1))
  done

  # Find next available Dashboard watchdog slot
  local wdg_slot=""
  local slot_key=""
  for sn in 1 2 3 4 5 6; do
    local slot_val=""
    slot_val=$(grep "^WDG_SLOT_${sn}=" "${runtime_dir}/session.env" | cut -d= -f2)
    slot_val="${slot_val//\"/}"
    # Check if this slot is already claimed by an existing team
    local slot_taken=""
    for tf in "${runtime_dir}"/team_*.env; do
      [ -f "$tf" ] || continue
      local tf_wdg
      tf_wdg=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2)
      tf_wdg="${tf_wdg//\"/}"
      if [ "$tf_wdg" = "$slot_val" ]; then
        slot_taken="yes"
        break
      fi
    done
    if [ -z "$slot_taken" ]; then
      wdg_slot="$slot_val"
      slot_key="$sn"
      break
    fi
  done

  if [ -z "$wdg_slot" ]; then
    printf "  ${ERROR}All 3 Dashboard watchdog slots are occupied — cannot add more teams${RESET}\n"
    tmux kill-window -t "${session}:${window_index}" 2>/dev/null
    return 1
  fi

  # Name panes
  tmux select-pane -t "${session}:${window_index}.0" -T "T${window_index} Window Manager"
  local wnum=0
  for (( i=1; i<total_panes; i++ )); do
    wnum=$((wnum + 1))
    tmux select-pane -t "${session}:${window_index}.${i}" -T "T${team_window} W${wnum}"
  done
  tmux rename-window -t "${session}:${window_index}" "Team ${window_index}"

  # Rename window to indicate worktree if applicable
  if [ -n "$worktree_spec" ]; then
    tmux rename-window -t "${session}:${window_index}" "Team ${window_index} [wt]"
  fi

  # Write team env (watchdog in Dashboard slot, manager in team pane 0)
  write_team_env "$runtime_dir" "$window_index" "$grid" "$wdg_slot" "$worker_panes" "$worker_count" "0" "$wt_dir_for_env" "$worktree_branch"

  # Update session.env TEAM_WINDOWS (atomic)
  local current_windows
  current_windows=$(read_team_windows "$runtime_dir")
  local new_windows="${current_windows},${window_index}"
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=\"${new_windows}\"/" "${runtime_dir}/session.env" > "${runtime_dir}/session.env.tmp"
  mv "${runtime_dir}/session.env.tmp" "${runtime_dir}/session.env"

  # Ensure shared worker system prompt exists
  if [ ! -f "${runtime_dir}/worker-system-prompt.md" ]; then
    local project_name
    project_name=$(grep '^PROJECT_NAME=' "${runtime_dir}/session.env" | cut -d= -f2)
    project_name="${project_name//\"/}"
    write_worker_system_prompt "$runtime_dir" "$project_name" "$team_dir"
  fi

  # Launch Window Manager in team window pane 0
  mgr_agent=$(generate_team_agent "doey-manager" "$window_index")
  tmux send-keys -t "${session}:${window_index}.0" \
    "claude --dangerously-skip-permissions --name \"T${window_index} Window Manager\" --agent \"$mgr_agent\"" Enter
  tmux select-pane -t "${session}:${window_index}.0" -T "T${window_index} Window Manager"
  sleep 0.5

  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"

  # Launch Watchdog in Dashboard slot (pane $wdg_slot)
  tmux send-keys -t "${session}:${wdg_slot}" C-c
  sleep 0.3
  wdg_agent=$(generate_team_agent "doey-watchdog" "$window_index")
  tmux send-keys -t "${session}:${wdg_slot}" \
    "claude --dangerously-skip-permissions --model haiku --effort low --name \"T${window_index} Watchdog\" --agent \"$wdg_agent\"" Enter
  tmux select-pane -t "${session}:${wdg_slot}" -T "T${window_index} Watchdog"
  sleep 0.5

  # Launch Workers
  wnum=0
  for (( i=1; i<total_panes; i++ )); do
    wnum=$((wnum + 1))
    local worker_prompt_file="${runtime_dir}/worker-system-prompt-w${window_index}-${wnum}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$worker_prompt_file"
    printf '\n\n## Identity\nYou are Worker %s in pane %s.%s of session %s.\n' \
      "$wnum" "$window_index" "$i" "$session" >> "$worker_prompt_file"

    local worker_cmd="claude --dangerously-skip-permissions --model opus --name \"T${window_index} W${wnum}\""
    worker_cmd+=" --append-system-prompt-file \"${worker_prompt_file}\""
    tmux send-keys -t "${session}:${window_index}.${i}" "$worker_cmd" Enter
    sleep 0.3

    write_pane_status "$runtime_dir" "${session}:${window_index}.${i}" "READY"
  done

  # Build worker pane list once (shared by Window Manager briefing and Watchdog start)
  local wp_list=""
  for (( i=1; i<total_panes; i++ )); do
    [ -n "$wp_list" ] && wp_list="${wp_list}, "
    wp_list="${wp_list}${window_index}.${i}"
  done

  # Brief the new Window Manager after boot
  (
    sleep 8
    tmux send-keys -t "${session}:${window_index}.0" \
      "Team is online in window ${window_index}. You have ${worker_count} workers in panes ${wp_list}. Your workers are in window ${window_index}. Watchdog is in Dashboard pane ${wdg_slot}. Session: ${session}. All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &

  # Start watchdog monitoring
  (
    sleep 12
    tmux send-keys -t "${session}:${wdg_slot}" \
      "Start monitoring session ${session} window ${window_index}. Skip pane ${wdg_slot} (yourself, in Dashboard). Manager is in team window pane ${window_index}.0. Monitor panes ${wp_list}." Enter
    sleep 20
    tmux send-keys -t "${session}:${wdg_slot}" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &

  printf "  ${SUCCESS}Team window %s created${RESET} — grid %s, %s workers, watchdog in Dashboard slot %s\n" "$window_index" "$grid" "$worker_count" "$slot_key"
}

# Kill a team window and clean up its resources
# Usage: kill_team_window <session> <runtime_dir> <window>
kill_team_window() {
  local session="$1" runtime_dir="$2" window="$3"
  local team_env="${runtime_dir}/team_${window}.env"

  if [ ! -f "$team_env" ]; then
    printf "  ${ERROR}No team env for window %s${RESET}\n" "$window"
    return 1
  fi

  if [ "$window" = "0" ]; then
    printf "  ${ERROR}Cannot kill window 0 — use 'doey stop' to stop the entire session${RESET}\n"
    return 1
  fi

  local worker_panes="" watchdog_pane="" manager_pane=""
  while IFS='=' read -r key value; do
    value="${value%\"}"
    value="${value#\"}"
    case "$key" in
      WORKER_PANES) worker_panes="$value" ;;
      WATCHDOG_PANE) watchdog_pane="$value" ;;
      MANAGER_PANE)  manager_pane="$value" ;;
    esac
  done < "$team_env"

  printf "  ${DIM}Killing team window %s...${RESET}\n" "$window"

  # Kill all Claude processes in this window's panes
  local pane_id pane_pid
  for pane_id in $(tmux list-panes -t "${session}:${window}" -F '#{pane_id}' 2>/dev/null); do
    pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null) || continue
    if [ -n "$pane_pid" ]; then
      pkill -P "$pane_pid" 2>/dev/null || true
      kill -- -"$pane_pid" 2>/dev/null || true
    fi
  done

  sleep 1

  # Kill the tmux window
  tmux kill-window -t "${session}:${window}" 2>/dev/null || true

  # Clean up worktree if this team had one
  if [ -f "$team_env" ]; then
    local _wt_dir
    _wt_dir=$(grep '^WORKTREE_DIR=' "$team_env" | cut -d= -f2- | tr -d '"')
    if [ -n "$_wt_dir" ]; then
      local _proj_dir
      _proj_dir=$(grep '^PROJECT_DIR=' "${runtime_dir}/session.env" | cut -d= -f2- | tr -d '"')
      if [ -n "$_proj_dir" ]; then
        _worktree_safe_remove "$_proj_dir" "$_wt_dir"
      fi
    fi
  fi

  # Remove team env file
  rm -f "$team_env"

  # Clean up team-specific agent files
  rm -f "$HOME/.claude/agents/t${window}-watchdog.md" 2>/dev/null || true
  rm -f "$HOME/.claude/agents/t${window}-manager.md" 2>/dev/null || true

  # Clean status/results files for this window's panes
  local safe_prefix="${session//[:.]/_}_${window}_"
  rm -f "${runtime_dir}/status/${safe_prefix}"* 2>/dev/null || true
  rm -f "${runtime_dir}/results/"*"_${window}_"* 2>/dev/null || true

  # Update session.env TEAM_WINDOWS (remove this window)
  local current_windows new_windows=""
  current_windows=$(read_team_windows "$runtime_dir")
  local IFS_SAVE="$IFS"
  IFS=','
  local w
  for w in $current_windows; do
    [ "$w" = "$window" ] && continue
    [ -n "$new_windows" ] && new_windows="${new_windows},"
    new_windows="${new_windows}${w}"
  done
  IFS="$IFS_SAVE"
  sed "s/^TEAM_WINDOWS=.*/TEAM_WINDOWS=\"${new_windows}\"/" "${runtime_dir}/session.env" > "${runtime_dir}/session.env.tmp"
  mv "${runtime_dir}/session.env.tmp" "${runtime_dir}/session.env"

  printf "  ${SUCCESS}Team window %s killed and cleaned up${RESET}\n" "$window"
}

# List all team windows with their status
# Usage: list_team_windows <session> <runtime_dir>
list_team_windows() {
  local session="$1" runtime_dir="$2"

  printf '\n'
  printf "  ${BRAND}Doey — Team Windows${RESET}\n"
  printf '\n'

  local team_windows
  team_windows=$(read_team_windows "$runtime_dir")

  if [ "$team_windows" = "0" ] && [ ! -f "${runtime_dir}/team_0.env" ]; then
    printf "  ${DIM}(no team windows — single-window mode)${RESET}\n"
    printf '\n'
    return 0
  fi

  printf "  ${BOLD}%-8s %-8s %-10s %-8s %-20s${RESET}\n" "Window" "Grid" "Workers" "Status" "Team Env"
  printf "  ${DIM}%-8s %-8s %-10s %-8s %-20s${RESET}\n" "------" "----" "-------" "------" "--------"

  local IFS_SAVE="$IFS"
  IFS=','
  local w
  for w in $team_windows; do
    local team_env="${runtime_dir}/team_${w}.env"
    if [ -f "$team_env" ]; then
      local t_grid="" t_workers=""
      t_grid=$(grep '^GRID=' "$team_env" | cut -d= -f2)
      t_grid="${t_grid//\"/}"
      t_workers=$(grep '^WORKER_COUNT=' "$team_env" | cut -d= -f2)
      t_workers="${t_workers//\"/}"
      local status="active"
      if ! tmux list-panes -t "${session}:${w}" >/dev/null 2>&1; then
        status="dead"
      fi
      printf "  %-8s %-8s %-10s %-8s %-20s\n" "$w" "$t_grid" "$t_workers" "$status" "team_${w}.env"
    else
      printf "  %-8s ${DIM}(no env file)${RESET}\n" "$w"
    fi
  done
  IFS="$IFS_SAVE"

  printf '\n'
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

grid="dynamic"

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
    purge      Scan and clean stale runtime files, audit context bloat
    stop       Stop the session for the current project
    update     Pull latest changes and reinstall (alias: reinstall)
    reload     Hot-reload running session (--workers to restart workers too)
    doctor     Check installation health and prerequisites
    remove     Unregister a project (by name) or worker column (by number)
    uninstall  Remove all Doey files (keeps git repo and agent-memory)
    test       Run E2E integration test (--keep, --open, --grid NxM)
    dynamic    Launch with dynamic grid (add workers on demand)
    add        Add a worker column (2 workers) to a dynamic grid session
    add-team   Add a team window with its own Window Manager+Watchdog+Workers
    kill-team  Kill a team window by window index
    list-teams Show all team windows and their status
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
    doey reload       # hot-reload Manager + Watchdog
    doey reload --workers  # also restart workers
    doey doctor       # check system health
    doey remove myapp # unregister a project
    doey uninstall    # remove all installed files
    doey version      # show install info
    doey add-team 3x2 # add a team window (3x2 grid)
    doey kill-team 1  # kill team window 1
    doey list-teams   # show all team windows
HELP
    printf '\n'
    exit 0
    ;;
  init)
    register_project "$(pwd)"
    dir="$(pwd)"
    name="$(find_project "$dir")"
    if [[ -n "$name" ]]; then
      launch_with_grid "$name" "$dir" "$grid"
    fi
    exit 0
    ;;
  list)
    list_projects
    exit 0
    ;;
  purge)
    shift
    doey_purge "$@"
    exit $?
    ;;
  stop)
    stop_project
    exit $?
    ;;
  update|reinstall)
    update_system
    exit 0
    ;;
  reload)
    shift
    reload_session "$@"
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
        tmux select-window -t "$session:0"
        attach_or_switch "$session"
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
    elif [ -z "${2:-}" ]; then
      # No arg: if dynamic session running, remove last column; else project removal
      dir="$(pwd)"
      name="$(find_project "$dir")"
      if [[ -n "$name" ]]; then
        session="doey-${name}"
        if session_exists "$session"; then
          runtime_dir="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
          safe_source_session_env "${runtime_dir}/session.env"
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
  add-window|add-team)
    require_running_session
    _wt_spec=""
    _grid_arg="4x2"
    shift
    for _arg in "$@"; do
      case "$_arg" in
        --worktree) _wt_spec="auto" ;;
        *x*) _grid_arg="$_arg" ;;
      esac
    done
    if [ -n "$_wt_spec" ]; then
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$INITIAL_WORKER_COLS" "$_wt_spec"
    else
      add_team_window "$session" "$runtime_dir" "$dir" "$_grid_arg"
    fi
    exit 0
    ;;
  kill-window|kill-team)
    if [ -z "${2:-}" ]; then
      printf "  ${ERROR}Usage: doey kill-team <window-index>${RESET}\n"
      exit 1
    fi
    require_running_session
    kill_team_window "$session" "$runtime_dir" "$2"
    exit 0
    ;;
  list-windows|list-teams)
    require_running_session
    list_team_windows "$session" "$runtime_dir"
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
    # Already running — just attach (land on dashboard window 0)
    printf "  ${SUCCESS}Attaching to${RESET} ${BOLD}%s${RESET}...\n" "$session"
    tmux select-window -t "$session:0"
    attach_or_switch "$session"
  else
    # Known but not running — launch with premium UI
    launch_with_grid "$name" "$dir" "$grid"
  fi
else
  # Unknown directory — show interactive menu
  show_menu "${grid}"
fi
