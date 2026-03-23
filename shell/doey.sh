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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_FILE="$HOME/.claude/doey/projects"
mkdir -p "$(dirname "$PROJECTS_FILE")"
touch "$PROJECTS_FILE"

# ── Configuration ───────────────────────────────────────────────────
# Load user config (optional), then apply defaults for any unset variables.
# Hierarchy: project .doey/config.sh > global ~/.config/doey/config.sh > defaults
_doey_load_config() {
  local global_config="${DOEY_CONFIG:-${HOME}/.config/doey/config.sh}"
  # shellcheck source=/dev/null
  [ -f "$global_config" ] && source "$global_config"
  # Project config — walk up from cwd to find .doey/config.sh
  local search_dir
  search_dir="$(pwd)"
  while [ "$search_dir" != "/" ]; do
    if [ -f "${search_dir}/.doey/config.sh" ]; then
      # shellcheck source=/dev/null
      source "${search_dir}/.doey/config.sh"
      break
    fi
    search_dir="$(dirname "$search_dir")"
  done
}
_doey_load_config

# Grid & Teams
DOEY_INITIAL_WORKER_COLS="${DOEY_INITIAL_WORKER_COLS:-2}"
DOEY_INITIAL_TEAMS="${DOEY_INITIAL_TEAMS:-2}"
DOEY_INITIAL_WORKTREE_TEAMS="${DOEY_INITIAL_WORKTREE_TEAMS:-0}"
DOEY_MAX_WORKERS="${DOEY_MAX_WORKERS:-20}"
DOEY_MAX_WATCHDOG_SLOTS="${DOEY_MAX_WATCHDOG_SLOTS:-6}"

# Auth & Launch Timing
DOEY_WORKER_LAUNCH_DELAY="${DOEY_WORKER_LAUNCH_DELAY:-3}"
DOEY_TEAM_LAUNCH_DELAY="${DOEY_TEAM_LAUNCH_DELAY:-15}"
DOEY_MANAGER_LAUNCH_DELAY="${DOEY_MANAGER_LAUNCH_DELAY:-3}"
DOEY_WATCHDOG_LAUNCH_DELAY="${DOEY_WATCHDOG_LAUNCH_DELAY:-3}"
DOEY_MANAGER_BRIEF_DELAY="${DOEY_MANAGER_BRIEF_DELAY:-15}"
DOEY_WATCHDOG_BRIEF_DELAY="${DOEY_WATCHDOG_BRIEF_DELAY:-20}"
DOEY_WATCHDOG_LOOP_DELAY="${DOEY_WATCHDOG_LOOP_DELAY:-25}"

# Dynamic Grid Behavior
DOEY_IDLE_COLLAPSE_AFTER="${DOEY_IDLE_COLLAPSE_AFTER:-60}"
DOEY_IDLE_REMOVE_AFTER="${DOEY_IDLE_REMOVE_AFTER:-300}"
DOEY_PASTE_SETTLE_MS="${DOEY_PASTE_SETTLE_MS:-500}"

# Panel & Monitoring
DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"
DOEY_WATCHDOG_SCAN_INTERVAL="${DOEY_WATCHDOG_SCAN_INTERVAL:-30}"

# Models
DOEY_MANAGER_MODEL="${DOEY_MANAGER_MODEL:-opus}"
DOEY_WORKER_MODEL="${DOEY_WORKER_MODEL:-opus}"
DOEY_WATCHDOG_MODEL="${DOEY_WATCHDOG_MODEL:-sonnet}"
DOEY_SESSION_MANAGER_MODEL="${DOEY_SESSION_MANAGER_MODEL:-opus}"

# ── Helpers ───────────────────────────────────────────────────────────

# Read a key=value from an env file, stripping quotes.
# Usage: _env_val <file> <KEY>
_env_val() {
  local v
  v=$(grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true
  v="${v//\"/}"
  echo "$v"
}

# Read per-team config: _read_team_config <team_num> <property> <default>
# Reads DOEY_TEAM_<N>_<PROPERTY>, falls back to <default>
_read_team_config() {
  local n="$1" prop="$2" default="$3"
  eval "echo \"\${DOEY_TEAM_${n}_${prop}:-${default}}\""
}

resolve_repo_dir() {
  if [ -f "$HOME/.claude/doey/repo-path" ]; then
    cat "$HOME/.claude/doey/repo-path"
  else
    (cd "$SCRIPT_DIR/.." && pwd)
  fi
}

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
  # Always write Doey hooks to settings.local.json (Doey owns this file).
  # User hooks belong in their project's settings.json — Claude Code merges both.
  cp "${repo_dir}/.claude/settings.json" "$target_dir/.claude/settings.local.json"
  # Copy doey-* skill directories so /doey-* commands are discoverable
  mkdir -p "$target_dir/.claude/skills"
  for d in "${repo_dir}"/.claude/skills/doey-*/; do
    [ -d "$d" ] || continue
    # Strip trailing slash — cp -R with trailing slash copies contents, not the directory
    cp -R "${d%/}" "$target_dir/.claude/skills/"
  done
  # Remove orphan doey-* skill dirs no longer in the source repo
  for d in "$target_dir"/.claude/skills/doey-*/; do
    [ -d "$d" ] || continue
    local name
    name="$(basename "$d")"
    if [ ! -d "${repo_dir}/.claude/skills/${name}" ]; then
      rm -rf "$d"
    fi
  done
  printf "${indent}${DIM}Doey hooks + skills installed${RESET}\n"
}

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

project_name_from_dir() {
  local raw
  if [ -f "$1/.doey-name" ]; then raw=$(head -1 "$1/.doey-name"); else raw=$(basename "$1"); fi
  echo "$raw" | tr '[:upper:] .' '[:lower:]--' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//;s/-$//'
}

# Generate a short project acronym from a hyphenated name (max 4 chars).
# e.g. "claude-code-tmux-team" → "cctm", "gyldendal-no" → "gn", "my-app" → "ma"
project_acronym() {
  local name="$1" acr="" seg
  local old_ifs="$IFS"; IFS='-'
  for seg in $name; do
    [ -n "$seg" ] && acr="${acr}$(printf '%s' "$seg" | cut -c1)"
  done
  IFS="$old_ifs"
  printf '%s' "$acr" | cut -c1-4
}

find_project() {
  local dir="$1"
  grep -m1 ":${dir}$" "$PROJECTS_FILE" 2>/dev/null | cut -d: -f1 || true
}

# < /dev/null prevents tmux from consuming stdin in read loops
session_exists() {
  tmux has-session -t "$1" < /dev/null 2>/dev/null
}

read_team_windows() {
  local tw
  tw=$(_env_val "$1/session.env" TEAM_WINDOWS)
  echo "${tw:-0}"
}

write_team_env() {
  local runtime_dir="$1" window_index="$2" grid="$3"
  local watchdog_pane="$4" worker_panes="$5" worker_count="$6"
  local manager_pane="${7:-0}"
  local worktree_dir="${8:-}"
  local worktree_branch="${9:-}"
  local team_name="${10:-}"
  local team_role="${11:-}"
  local worker_model="${12:-}"
  local manager_model="${13:-}"
  local session_name
  session_name=$(_env_val "${runtime_dir}/session.env" SESSION_NAME)
  local _tmp="${runtime_dir}/team_${window_index}.env.tmp.$$"
  cat > "$_tmp" << TEAMEOF
WINDOW_INDEX="${window_index}"
GRID="${grid}"
MANAGER_PANE="${manager_pane}"
WATCHDOG_PANE="${watchdog_pane}"
WORKER_PANES="${worker_panes}"
WORKER_COUNT="${worker_count}"
SESSION_NAME="${session_name}"
WORKTREE_DIR="${worktree_dir}"
WORKTREE_BRANCH="${worktree_branch}"
TEAM_NAME="${team_name}"
TEAM_ROLE="${team_role}"
WORKER_MODEL="${worker_model}"
MANAGER_MODEL="${manager_model}"
TEAMEOF
  mv "$_tmp" "${runtime_dir}/team_${window_index}.env"
}

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

create_team_worktree() {
  local project_dir="$1" team_window="$2" branch_name="${3:-}"
  if [ -z "$branch_name" ]; then
    branch_name="doey/team-${team_window}-$(date +%m%d-%H%M)"
  fi
  local project_name
  project_name="$(basename "$project_dir")"
  local wt_path="/tmp/doey/${project_name}/worktrees/team-${team_window}"

  # Clean up stale worktree state from prior runs
  git -C "$project_dir" worktree prune 2>/dev/null || true
  # If a stale worktree dir exists at the target path, remove it properly
  if [ -d "$wt_path" ]; then
    git -C "$project_dir" worktree remove "$wt_path" --force 2>/dev/null || true
    git -C "$project_dir" worktree prune 2>/dev/null || true
    # Last resort: nuke the directory if git couldn't clean it
    [ -d "$wt_path" ] && rm -rf "$wt_path"
  fi
  # Remove stale branch if it exists from a prior run
  git -C "$project_dir" branch -D "$branch_name" 2>/dev/null || true

  mkdir -p "$(dirname "$wt_path")"
  if ! git -C "$project_dir" worktree add "$wt_path" -b "$branch_name" >/dev/null 2>&1; then
    if ! git -C "$project_dir" worktree add "$wt_path" "$branch_name" >/dev/null 2>&1; then
      if ! git -C "$project_dir" worktree add --force "$wt_path" -b "$branch_name" >/dev/null 2>&1; then
        echo "Error: failed to create worktree at $wt_path for branch $branch_name" >&2
        return 1
      fi
    fi
  fi
  # Copy hook settings into the worktree so Claude Code picks them up
  if [ -f "$project_dir/.claude/settings.local.json" ]; then
    mkdir -p "$wt_path/.claude"
    cp "$project_dir/.claude/settings.local.json" "$wt_path/.claude/"
  fi
  echo "$wt_path"
}

remove_team_worktree() {
  local project_dir="$1" worktree_dir="$2"
  [ -z "$worktree_dir" ] && return 0
  [ -d "$worktree_dir" ] || return 0
  git -C "$project_dir" worktree remove "$worktree_dir" --force 2>/dev/null || true
  git -C "$project_dir" worktree prune 2>/dev/null || true
}

_worktree_safe_remove() {
  local project_dir="$1" worktree_dir="$2" force="${3:-false}"
  { [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0

  local branch_name
  branch_name=$(git -C "$worktree_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Auto-commit uncommitted changes unless forced
  if [ "$force" != "true" ]; then
    local dirty=""
    dirty=$(git -C "$worktree_dir" status --porcelain 2>/dev/null) || true
    if [ -n "$dirty" ]; then
      git -C "$worktree_dir" add -A 2>/dev/null || true
      git -C "$worktree_dir" commit -m "doey: auto-save before teardown $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
      printf '  Worktree had uncommitted changes — auto-saved to branch: %s\n' "$branch_name"
    fi
  fi

  # Report unmerged commits
  if [ -n "$branch_name" ] && [ "$branch_name" != "HEAD" ] && [ "$branch_name" != "unknown" ]; then
    local commits_ahead
    commits_ahead=$(git -C "$project_dir" rev-list --count "HEAD..${branch_name}" 2>/dev/null || echo "0")
    if [ "$commits_ahead" -gt 0 ] 2>/dev/null; then
      printf '  Branch %s has %s commit(s). Merge with: git merge %s\n' "$branch_name" "$commits_ahead" "$branch_name"
    fi
  fi

  remove_team_worktree "$project_dir" "$worktree_dir"
}

_balance_watchdog_panes() {
  local session="$1" num_slots="$2"
  local _bw_total=0 _bw_w _bw_target
  local _bw_last=$((num_slots + 1))
  local _bw_i
  for (( _bw_i=2; _bw_i<=_bw_last; _bw_i++ )); do
    _bw_w=$(tmux display-message -t "$session:0.${_bw_i}" -p '#{pane_width}')
    _bw_total=$((_bw_total + _bw_w))
  done
  _bw_target=$((_bw_total / num_slots))
  for (( _bw_i=2; _bw_i<_bw_last; _bw_i++ )); do
    tmux resize-pane -t "$session:0.${_bw_i}" -x "$_bw_target"
  done
}

_find_free_watchdog_slot() {
  local runtime_dir="$1"
  _FWS_SLOT=""
  # Collect all used watchdog panes
  local used_slots="" tf tf_wdg
  for tf in "${runtime_dir}"/team_*.env; do
    [ -f "$tf" ] || continue
    tf_wdg=$(_env_val "$tf" WATCHDOG_PANE)
    used_slots="${used_slots} ${tf_wdg}"
  done
  # Find first slot not in use
  local sn slot_val
  for sn in 1 2 3 4 5 6; do
    slot_val=$(_env_val "${runtime_dir}/session.env" "WDG_SLOT_${sn}")
    [ -n "$slot_val" ] || continue
    case " $used_slots " in
      *" $slot_val "*) continue ;;
    esac
    _FWS_SLOT="$slot_val"
    return 0
  done
  return 1
}

# Dashboard layout: Info Panel (left) | Session Manager (top-right) | Watchdog slots (bottom-right)
# Sets: WDG_SLOT_1..N, SM_PANE
setup_dashboard() {
  local session="$1" dir="$2" runtime_dir="$3"
  local num_slots="${4:-6}"

  # Start: single pane 0.0 (will become Info Panel)
  # Split left/right — right column gets 60% (use -l for tmux 3.4 detached compat)
  tmux split-window -h -t "$session:0.0" -l 150 -c "$dir"
  # Indices: 0.0=info(left), 0.1=right

  # Split right column: top 65% (SM area) + bottom 35% (watchdog row)
  tmux split-window -v -t "$session:0.1" -l 28 -c "$dir"
  # Indices: 0.0=info, 0.1=top-right, 0.2=bottom-right

  # Split bottom-right into $num_slots horizontal watchdog slots
  if [ "$num_slots" -gt 1 ]; then
    local _wd_total_w
    _wd_total_w=$(tmux display-message -t "$session:0.2" -p '#{pane_width}')
    local _wd_n
    for (( _wd_n=1; _wd_n<num_slots; _wd_n++ )); do
      local _wd_remaining=$((num_slots - _wd_n))
      local _wd_frac=$(( _wd_total_w * _wd_remaining / num_slots ))
      tmux split-window -h -t "$session:0.$((_wd_n + 1))" -l "$_wd_frac" -c "$dir"
    done
  fi
  _balance_watchdog_panes "$session" "$num_slots"

  tmux select-pane -t "$session:0.0" -T ""
  tmux select-pane -t "$session:0.1" -T "Session Manager"
  for (( _wd_i=1; _wd_i<=num_slots; _wd_i++ )); do
    local _pane="0.$((_wd_i + 1))"
    tmux select-pane -t "$session:${_pane}" -T "T${_wd_i} Watchdog"
    tmux send-keys -t "$session:${_pane}" "echo 'Watchdog slot — awaiting team assignment...'" Enter
    printf -v "WDG_SLOT_${_wd_i}" '%s' "$_pane"
  done
  SM_PANE="0.1"

  tmux send-keys -t "$session:0.0" "clear && info-panel.sh '${runtime_dir}'" Enter
  tmux send-keys -t "$session:0.1" "claude --dangerously-skip-permissions --model $DOEY_SESSION_MANAGER_MODEL --agent doey-session-manager" Enter
  tmux rename-window -t "$session:0" "Dashboard"
  write_pane_status "$runtime_dir" "${session}:0.1" "READY"
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

  # Create .doey/ project config directory with template
  if [ ! -d "${dir}/.doey" ]; then
    mkdir -p "${dir}/.doey"
    local template="${SCRIPT_DIR}/doey-config-default.sh"
    if [ -f "$template" ]; then
      cp "$template" "${dir}/.doey/config.sh"
    fi
    printf "  ${SUCCESS}Created${RESET} .doey/config.sh\n"
  fi
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
  # Clean up worktrees + runtime dir
  local project_name="${session#doey-}"
  local _rt="/tmp/doey/${project_name}"
  local _proj_dir=""
  [ -f "$_rt/session.env" ] && _proj_dir=$(_env_val "$_rt/session.env" PROJECT_DIR)
  if [ -n "$_proj_dir" ]; then
    local _te _wt_dir
    for _te in "$_rt"/team_*.env; do
      [ -f "$_te" ] || continue
      _wt_dir=$(_env_val "$_te" WORKTREE_DIR)
      [ -n "$_wt_dir" ] && _worktree_safe_remove "$_proj_dir" "$_wt_dir"
    done
    git -C "$_proj_dir" worktree prune 2>/dev/null || true
  fi
  rm -rf "$_rt" 2>/dev/null || true
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

  # Count running sessions for the kill-all option
  local running_count=0
  for i in "${!names[@]}"; do
    session_exists "doey-${names[$i]}" && running_count=$((running_count + 1))
  done

  printf "  ${DIM}Options:${RESET}\n"
  printf "    ${BOLD}#${RESET})    Enter number to open a project\n"
  printf "    ${BOLD}k#${RESET})   Kill a specific session ${DIM}(e.g. k1, k2)${RESET}\n"
  printf "    ${BOLD}r#${RESET})   Restart a session ${DIM}(e.g. r1, r2)${RESET}\n"
  printf "    ${BOLD}i${RESET})    Init current directory as new project\n"
  if [[ $running_count -gt 0 ]]; then
    printf "    ${BOLD}k${RESET})    Kill all running sessions ${DIM}(%d active)${RESET}\n" "$running_count"
  fi
  printf "    ${BOLD}q${RESET})    Quit\n"
  printf '\n'

  read -rp "  > " choice

  # Helper: parse number from choice, validate index, set _sel_name/_sel_path/_sel_session
  local _sel_idx _sel_name _sel_path _sel_session
  _menu_select() {
    local num="$1"
    _sel_idx=$((num - 1))
    if [[ $_sel_idx -lt 0 || $_sel_idx -ge ${#names[@]} ]]; then
      printf "  ${ERROR}Invalid selection${RESET}\n"; return 1
    fi
    _sel_name="${names[$_sel_idx]}"
    _sel_path="${paths[$_sel_idx]}"
    _sel_session="doey-${_sel_name}"
  }

  case "$choice" in
    [rR][0-9]*)
      _menu_select "${choice#[rR]}" || return 1
      if session_exists "$_sel_session"; then
        printf "  Restarting ${BOLD}%s${RESET}...\n" "$_sel_session"
        _kill_doey_session "$_sel_session"
        printf "  ${SUCCESS}Killed${RESET} %s\n" "$_sel_session"
      fi
      printf "  Launching ${BOLD}%s${RESET}...\n" "$_sel_name"
      launch_with_grid "$_sel_name" "$_sel_path" "$grid"
      ;;
    [kK][0-9]*)
      _menu_select "${choice#[kK]}" || return 1
      if session_exists "$_sel_session"; then
        read -rp "  Kill ${BOLD}${_sel_session}${RESET}? (y/N) " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          _kill_doey_session "$_sel_session"
          printf "  ${SUCCESS}Killed${RESET} %s\n" "$_sel_session"
        else
          printf "  ${DIM}Cancelled${RESET}\n"
        fi
      else
        printf "  ${DIM}%s is not running${RESET}\n" "$_sel_name"
      fi
      ;;
    [0-9]*)
      _menu_select "$choice" || return 1
      if session_exists "$_sel_session"; then
        attach_or_switch "$_sel_session"
      else
        launch_with_grid "$_sel_name" "$_sel_path" "$grid"
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
    k|K|kill)
      if [[ $running_count -eq 0 ]]; then
        printf "  ${DIM}No running sessions to kill${RESET}\n"
        return 0
      fi
      printf '\n'
      read -rp "  Kill all ${running_count} running session(s)? (y/N) " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for i in "${!names[@]}"; do
          local sess="doey-${names[$i]}"
          if session_exists "$sess"; then
            _kill_doey_session "$sess"
            printf "  ${SUCCESS}Killed${RESET} %s\n" "$sess"
          fi
        done
        printf "\n  ${SUCCESS}All sessions killed${RESET}\n"
      else
        printf "  ${DIM}Cancelled${RESET}\n"
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

  # Theme — pane borders, status bar, window tabs, keybindings
  source "${SCRIPT_DIR}/tmux-theme.sh"
}

# Pre-accept trust for the project directory in Claude settings
# Usage: ensure_project_trusted <dir> [indent]
ensure_project_trusted() {
  local dir="$1" indent="${2:-   }"
  local claude_settings="$HOME/.claude/settings.json"
  if command -v jq >/dev/null 2>&1; then
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

_purge_format_bytes() {
  local bytes="$1"
  if [[ "$bytes" -ge 1048576 ]]; then
    awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
  elif [[ "$bytes" -ge 1024 ]]; then
    awk "BEGIN{printf \"%.1f KB\", $bytes/1024}"
  else
    printf "%d B" "$bytes"
  fi
}

_purge_file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

_purge_collect() {
  local file="$1" list_file="$2"
  local size
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  echo "${size}:${file}" >> "$list_file"
}

_purge_collect_stale() {
  local glob="$1" max_age="$2" now="$3" list_file="$4" label="${5:-}"
  local count=0
  for f in $glob; do
    [[ -f "$f" ]] || continue
    if [[ "$max_age" -eq 0 ]] || [[ $((now - $(_purge_file_mtime "$f"))) -gt "$max_age" ]]; then
      _purge_collect "$f" "$list_file"
      count=$((count + 1))
    fi
  done
  [[ $count -gt 0 ]] && [[ -n "$label" ]] && printf "         Found %d %s\n" "$count" "$label"
}

_purge_scan_runtime() {
  local rt="$1" active="$2" session_name="$3" list_file="$4" now="$5"

  # --- Status files: dead-pane detection ---
  local live_panes="" status_count=0
  if $active; then
    live_panes="$(tmux list-panes -s -t "$session_name" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | tr '\n' '|')"
  fi
  for f in "$rt"/status/*.status; do
    [[ -f "$f" ]] || continue
    if $active; then
      local pane_id
      pane_id="$(head -1 "$f" | sed 's/^PANE: //')"
      echo "$live_panes" | grep -qF "$pane_id" && continue
    fi
    _purge_collect "$f" "$list_file"
    status_count=$((status_count + 1))
  done
  [[ $status_count -gt 0 ]] && printf "         Found %d stale status files\n" "$status_count"

  # --- Always-safe markers ---
  _purge_collect_stale "$rt/status/*.dispatched"     0 "$now" "$list_file" ""
  _purge_collect_stale "$rt/status/notif_cooldown_*" 0 "$now" "$list_file" "cooldown markers"

  # --- Session-stopped-only files ---
  if ! $active; then
    for f in "$rt"/status/pane_map "$rt"/status/col_*.collapsed \
             "$rt"/status/pane_hash_* "$rt"/status/watchdog_W*.heartbeat \
             "$rt"/status/watchdog_pane_states_W*.json; do
      [[ -f "$f" ]] || continue
      _purge_collect "$f" "$list_file"
    done
  fi

  # --- Age-based cleanup ---
  _purge_collect_stale "$rt/messages/*.msg"         3600  "$now" "$list_file" "stale undelivered messages"
  _purge_collect_stale "$rt/broadcasts/*.broadcast" 3600  "$now" "$list_file" ""
  _purge_collect_stale "$rt/results/*"              86400 "$now" "$list_file" "old result files (>24h)"
}

_purge_scan_research() {
  local rt="$1" list_file="$2" now="$3"
  local before=0
  [[ -s "$list_file" ]] && before="$(wc -l < "$list_file" | tr -d ' ')"
  _purge_collect_stale "$rt/research/*" 172800 "$now" "$list_file" ""
  _purge_collect_stale "$rt/reports/*"  172800 "$now" "$list_file" ""
  local after=0
  [[ -s "$list_file" ]] && after="$(wc -l < "$list_file" | tr -d ' ')"
  local count=$((after - before))
  if [[ $count -gt 0 ]]; then
    printf "         Found %d research/report files older than 48h\n" "$count"
  else
    printf "         ${DIM}No expired research artifacts${RESET}\n"
  fi
}

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
  for f in "$PROJECT_DIR"/.claude/skills/doey-*/SKILL.md; do
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
    printf '%b' "$recommendations"
  fi
  printf '\n'
}

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

_purge_summary() {
  local rt_files="$1" rt_bytes="$2" res_files="$3" res_bytes="$4" dry_run="$5"
  local total_files=$((rt_files + res_files))
  local total_bytes=$((rt_bytes + res_bytes))

  printf '\n'
  printf "         ${DIM}%-14s %7s  %-12s${RESET}\n" "Category" "Files" "Size"
  printf "         ${DIM}──────────────────────────────────────${RESET}\n"
  printf "         %-14s %5d  %-12s\n" "Runtime" "$rt_files" "$(_purge_format_bytes "$rt_bytes")"
  printf "         %-14s %5d  %-12s\n" "Research" "$res_files" "$(_purge_format_bytes "$res_bytes")"
  printf "         ${DIM}──────────────────────────────────────${RESET}\n"
  printf "         ${BOLD}%-14s %5d  %-12s${RESET}\n" "Total" "$total_files" "$(_purge_format_bytes "$total_bytes")"

  if $dry_run; then
    printf "         ${DIM}(dry run — no files were deleted)${RESET}\n"
  fi
  printf '\n'
}

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

_purge_write_report() {
  local rt="$1" project="$2" active="$3" dry_run="$4" scope="$5"
  local rt_files="$6" rt_bytes="$7" res_files="$8" res_bytes="$9"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

  mkdir -p "$rt/results"
  cat > "$rt/results/purge_report_$(date '+%Y%m%d_%H%M%S').json" << REPORT_EOF
{
  "timestamp": "$ts",
  "project": "$project",
  "session_active": $active,
  "dry_run": $dry_run,
  "scope": "$scope",
  "runtime": { "files_found": $rt_files, "bytes_freed": $rt_bytes },
  "research": { "files_found": $res_files, "bytes_freed": $res_bytes },
  "total_files_purged": $((rt_files + res_files)),
  "total_bytes_freed": $((rt_bytes + res_bytes))
}
REPORT_EOF
  printf "   Report: ${DIM}%s/results/purge_report_*.json${RESET}\n" "$rt"
}

_purge_tally() {
  local list_file="$1"
  _COUNT=0; _BYTES=0
  [[ -s "$list_file" ]] || return 0
  while IFS=: read -r size path; do
    [[ -z "$path" ]] && continue
    _COUNT=$((_COUNT + 1))
    _BYTES=$((_BYTES + size))
  done < "$list_file"
}

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
  PROJECT_DIR="$dir"
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
  local state_label="stopped"; $session_active && state_label="active"
  printf '\n'
  printf "  ${BRAND}Doey — Purge${RESET}  ${DIM}(session %s)${RESET}\n\n" "$state_label"

  # Calculate step count based on scope
  local step=0
  case "$scope" in
    all) STEP_TOTAL=5 ;;
    *)   STEP_TOTAL=2 ;;
  esac

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

  if [[ $total_files -eq 0 ]]; then
    printf "         ${SUCCESS}Nothing to purge — runtime is clean.${RESET}\n\n"
  elif $dry_run; then
    _purge_summary "$rt_files" "$rt_bytes" "$res_files" "$res_bytes" "$dry_run"
  else
    _purge_summary "$rt_files" "$rt_bytes" "$res_files" "$res_bytes" "$dry_run"
    # Confirmation prompt (unless --force)
    local do_purge=true
    if ! $force; then
      local confirm
      printf "   Found %d stale files (%s). Purge? (y/N) " "$total_files" "$(_purge_format_bytes "$((rt_bytes + res_bytes))")"
      read -r confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || do_purge=false
    fi
    if $do_purge; then
      _purge_execute "$list_file"
    else
      printf "  ${DIM}Cancelled${RESET}\n"
    fi
  fi

  _purge_write_report "$runtime_dir" "$name" "$session_active" "$dry_run" "$scope" \
    "$rt_files" "$rt_bytes" "$res_files" "$res_bytes"
}

INITIAL_WORKER_COLS=$DOEY_INITIAL_WORKER_COLS
INITIAL_TEAMS=$DOEY_INITIAL_TEAMS
MAX_WATCHDOG_SLOTS=$DOEY_MAX_WATCHDOG_SLOTS

check_claude_auth() {
  if ! command -v claude >/dev/null 2>&1; then
    printf "  ${ERROR}✗ claude CLI not found${RESET}\n"
    return 1
  fi
  local auth_json
  auth_json=$(claude auth status 2>&1) || auth_json=""
  if echo "$auth_json" | grep -q '"loggedIn": true'; then
    local method email sub
    method=$(echo "$auth_json" | grep '"authMethod"' | sed 's/.*: *"//;s/".*//')
    email=$(echo "$auth_json" | grep '"email"' | sed 's/.*: *"//;s/".*//')
    sub=$(echo "$auth_json" | grep '"subscriptionType"' | sed 's/.*: *"//;s/".*//')
    printf "  ${SUCCESS}✓ Authenticated${RESET} ${DIM}(%s · %s · %s)${RESET}\n" "$method" "$email" "$sub"
    return 0
  else
    printf "\n  ${ERROR}✗ Not logged in${RESET}\n"
    printf "  ${DIM}All Claude instances share one auth session.${RESET}\n"
    printf "  ${DIM}Run ${RESET}${BOLD}claude${RESET}${DIM} and authenticate, then retry.${RESET}\n\n"
    return 1
  fi
}

launch_with_grid() {
  local name="$1" dir="$2" grid="$3"
  check_claude_auth || return 1
  if [[ "$grid" == "dynamic" || "$grid" == "d" ]]; then
    launch_session_dynamic "$name" "$dir"
  else
    launch_session "$name" "$dir" "$grid"
  fi
}

# ── Core session launch logic (shared by launch_session & launch_session_headless) ──
_launch_session_core() {
  local name="$1" dir="$2" grid="$3" headless="$4"
  local cols="${grid%x*}" rows="${grid#*x}"
  local total=$(( cols * rows ))
  local worker_count=$(( total - 1 ))
  local session="doey-${name}"
  local runtime_dir="/tmp/doey/${name}"
  local team_window=1

  cd "$dir"

  local hook_indent="   "
  [[ "$headless" -eq 1 ]] && hook_indent="  "
  install_doey_hooks "$dir" "$hook_indent"

  local worker_panes_csv
  worker_panes_csv="$(_build_worker_csv "$total")"

  # -- Session creation --
  if [[ "$headless" -eq 0 ]]; then
    step_start 1 "Creating session for ${name}..."
  else
    printf "  ${DIM}Creating session ${session}...${RESET}\n"
  fi

  _init_doey_session "$session" "$runtime_dir" "$dir" "$name"

  local acronym
  acronym=$(project_acronym "$name")

  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR="$dir"
PROJECT_NAME="$name"
PROJECT_ACRONYM="$acronym"
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
SM_PANE="0.1"
WDG_SLOT_1="0.2"
MANIFEST

  write_team_env "$runtime_dir" "1" "$grid" "0.2" "$worker_panes_csv" "$worker_count" "0" "" ""

  setup_dashboard "$session" "$dir" "$runtime_dir" 1
  tmux new-window -t "$session" -c "$dir"

  [[ "$headless" -eq 0 ]] && step_done

  # -- Theme --
  if [[ "$headless" -eq 0 ]]; then
    step_start 2 "Applying theme..."
  else
    printf "  ${DIM}Applying theme...${RESET}\n"
  fi
  local border_fmt=" #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  apply_doey_theme "$session" "$name" "$border_fmt" 2
  [[ "$headless" -eq 0 ]] && step_done

  # -- Grid --
  if [[ "$headless" -eq 0 ]]; then
    step_start 3 "Building ${cols}x${rows} grid (${total} panes)..."
  else
    printf "  ${DIM}Building ${cols}x${rows} grid (${total} panes)...${RESET}\n"
  fi

  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "$session:${team_window}.0" -c "$dir"
  done
  tmux select-layout -t "$session:${team_window}" even-vertical

  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "$session:${team_window}.$((r * cols))" -c "$dir"
    done
  done

  sleep 0.5
  local actual
  actual=$(tmux list-panes -t "$session:${team_window}" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$actual" -ne "$total" ]] && \
    printf "\n   ${WARN}⚠ Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total" "$actual"

  [[ "$headless" -eq 0 ]] && step_done

  # -- Name panes --
  if [[ "$headless" -eq 0 ]]; then
    step_start 4 "Naming panes..."
  else
    printf "  ${DIM}Naming panes...${RESET}\n"
  fi

  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  for (( i=1; i<total; i++ )); do
    tmux select-pane -t "$session:${team_window}.$i" -T "T${team_window} W${i}"
  done
  tmux rename-window -t "$session:${team_window}" "Local Team"

  [[ "$headless" -eq 0 ]] && step_done

  # -- Manager & Watchdog --
  if [[ "$headless" -eq 0 ]]; then
    step_start 5 "Launching Window Manager & Watchdog..."
  else
    printf "  ${DIM}Launching Window Manager & Watchdog...${RESET}\n"
  fi

  _launch_team_manager "$session" "$runtime_dir" "$team_window"
  _launch_team_watchdog "$session" "${WDG_SLOT_1}" "$team_window"

  _build_worker_pane_list "$session" "$team_window"
  _brief_team "$session" "$team_window" "${WDG_SLOT_1}" "$_WPL_RESULT" "$worker_count" "Grid ${grid}"

  (
    sleep 15
    tmux send-keys -t "$session:${SM_PANE}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. Team window ${team_window} has ${worker_count} workers. Use /doey-add-window to create new team windows and /doey-list-windows to see all teams. Awaiting instructions." Enter
  ) &

  trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM

  [[ "$headless" -eq 0 ]] && step_done

  # -- Boot workers --
  if [[ "$headless" -eq 0 ]]; then
    step_start 6 "Booting ${worker_count} workers..."
    printf '\n'
  else
    printf "  ${DIM}Booting ${worker_count} workers...${RESET}\n"
  fi

  local _bw_pairs=()
  local _bw_i
  for (( _bw_i=1; _bw_i<total; _bw_i++ )); do
    _bw_pairs+=("${_bw_i}:${_bw_i}")
  done
  _batch_boot_workers "$session" "$runtime_dir" "$team_window" "${_bw_pairs[@]}"
  [[ "$headless" -eq 0 ]] && printf "\r   ${DIM}[6/${STEP_TOTAL}]${RESET} Booting workers  ${BOLD}${worker_count}${RESET}${DIM}/${worker_count}${RESET}  ${SUCCESS}done${RESET}\n"

  trap - EXIT INT TERM
  tmux select-window -t "$session:0"
}

launch_session() {
  local name="$1" dir="$2" grid="${3:-6x2}"
  local cols="${grid%x*}" rows="${grid#*x}"
  local worker_count=$(( cols * rows - 1 ))
  local session="doey-${name}"
  local short_dir="${dir/#$HOME/~}"

  _print_full_banner
  printf "   ${DIM}Project${RESET} ${BOLD}${name}${RESET}  ${DIM}Grid${RESET} ${BOLD}${grid}${RESET}  ${DIM}Workers${RESET} ${BOLD}${worker_count}${RESET}\n"
  printf "   ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}  ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  ensure_project_trusted "$dir"

  _launch_session_core "$name" "$dir" "$grid" 0

  printf '\n'
  printf "   ${SUCCESS}Doey is ready${RESET}\n"
  printf "   ${DIM}Project${RESET} ${BOLD}%s${RESET}  ${DIM}Grid${RESET} ${BOLD}%s${RESET}  ${DIM}Workers${RESET} ${BOLD}%s${RESET}\n" "$name" "$grid" "$worker_count"
  printf "   ${DIM}Session${RESET} ${BOLD}%s${RESET}  ${DIM}Dir${RESET} ${BOLD}%s${RESET}\n" "$session" "$short_dir"
  printf "   ${DIM}Manager${RESET} 1.0  ${DIM}Watchdog${RESET} ${WDG_SLOT_1}  ${DIM}Dashboard${RESET} win 0\n"
  printf "   ${DIM}Tip: Workers ready in ~15s${RESET}\n"
  printf '\n'

  attach_or_switch "$session"
}

# ── Shared helpers (used by update, reload, etc.) ─────────────────────
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

# Clean up old session, runtime dir, and stale worktree branches
_cleanup_old_session() {
  local session="$1" runtime_dir="$2"
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -rf "$runtime_dir"
  git worktree prune 2>/dev/null || true
  # Delete doey/team-* branches whose worktrees no longer exist
  git for-each-ref --format='%(refname:short)' 'refs/heads/doey/team-*' | while read -r b; do
    # Keep branches that still have an active worktree
    if git worktree list --porcelain 2>/dev/null | grep -q "branch refs/heads/${b}$"; then
      continue
    fi
    git branch -D "$b" 2>/dev/null || true
  done
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status}
}

# Build comma-separated worker pane indices "1,2,3,...,N"
_build_worker_csv() {
  local total="$1" csv="" i
  for (( i=1; i<total; i++ )); do
    [ -n "$csv" ] && csv+=","
    csv+="$i"
  done
  echo "$csv"
}

# Kill the child process in a tmux pane (SIGTERM → retry SIGKILL).
# Usage: _kill_pane_child <pane_ref> [retries=3]
_kill_pane_child() {
  local ref="$1" max="${2:-3}"
  local shell_pid child attempt
  shell_pid=$(tmux display-message -t "$ref" -p '#{pane_pid}' 2>/dev/null || true)
  [ -z "$shell_pid" ] && return 1
  child=$(pgrep -P "$shell_pid" 2>/dev/null || true)
  [ -z "$child" ] && return 0
  kill "$child" 2>/dev/null || true
  sleep 2
  for (( attempt=0; attempt<max; attempt++ )); do
    child=$(pgrep -P "$shell_pid" 2>/dev/null || true)
    [ -z "$child" ] && return 0
    kill -9 "$child" 2>/dev/null || true
    sleep 1
  done
  return 0
}

# Print a doctor-style check line.
# Usage: _doc_check ok|warn|fail|skip "label" ["detail"]
_doc_check() {
  local level="$1" label="$2" detail="${3:-}"
  case "$level" in
    ok)   printf "  ${SUCCESS}✓${RESET} %s" "$label" ;;
    warn) printf "  ${WARN}⚠${RESET} %s" "$label" ;;
    fail) printf "  ${ERROR}✗${RESET} %s" "$label" ;;
    skip) printf "  ${DIM}–${RESET} %s" "$label" ;;
  esac
  [ -n "$detail" ] && printf "  ${DIM}%s${RESET}" "$detail"
  printf '\n'
}

# ── Update / Reinstall ───────────────────────────────────────────────
update_system() {
  local repo_dir install_dir=""
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"

  printf "  ${BRAND}Updating doey...${RESET}\n\n"

  if [[ -n "$repo_dir" ]] && [[ -d "$repo_dir/.git" ]]; then
    local old_hash new_hash
    old_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
    [[ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]] && \
      printf "  ${WARN}⚠ Repo has local changes — git pull may fail${RESET}\n"
    git -C "$repo_dir" pull || printf "  ${WARN}git pull failed — continuing with reinstall${RESET}\n"
    new_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
    if [[ "$old_hash" == "$new_hash" ]]; then
      printf "  ${SUCCESS}Already up to date${RESET} ${DIM}($old_hash)${RESET}\n"
    else
      printf "  ${SUCCESS}Updated${RESET} ${DIM}$old_hash → $new_hash${RESET}\n"
    fi
    install_dir="$repo_dir"
  else
    install_dir=$(mktemp -d "${TMPDIR:-/tmp}/doey-update.XXXXXX")
    printf "  ${DIM}No local repo — cloning from remote...${RESET}\n"
    if ! git clone --depth 1 "https://github.com/FRIKKern/doey.git" "$install_dir"; then
      printf "  ${ERROR}✗ Clone failed${RESET}\n"
      rm -rf "$install_dir"
      exit 1
    fi
  fi

  printf "\n  ${DIM}Running install.sh...${RESET}\n"
  if ! bash "$install_dir/install.sh"; then
    printf "  ${ERROR}✗ Install failed${RESET}\n"
    [[ "$install_dir" == /tmp/* ]] && rm -rf "$install_dir"
    exit 1
  fi
  [[ "$install_dir" == /tmp/* ]] && rm -rf "$install_dir"

  rm -f "$HOME/.claude/doey/last-update-check.available"

  # Check for Claude Code updates
  _check_claude_update

  printf '\n'
  _print_doey_banner
  printf "   ${DIM}Let me Doey for you${RESET}\n\n"
  printf "  ${SUCCESS}Update complete.${RESET} Restart sessions: ${BOLD}doey reload${RESET}\n"
}

# Check if Claude Code CLI has an update available, offer to install it.
_check_claude_update() {
  if ! command -v claude >/dev/null 2>&1; then
    printf "\n  ${WARN}⚠${RESET} Claude Code CLI not installed\n"
    if command -v node >/dev/null 2>&1 && [ -t 0 ]; then
      printf "  Install now? ${DIM}[Y/n]${RESET} "
      read -r reply
      case "$reply" in
        [Nn]*) ;;
        *)
          printf "  ${DIM}Installing Claude Code...${RESET}\n"
          npm install -g @anthropic-ai/claude-code 2>&1 | tail -3
          command -v claude >/dev/null 2>&1 && printf "  ${SUCCESS}✓ Claude Code installed${RESET}\n"
          ;;
      esac
    else
      printf "  ${DIM}Install: npm install -g @anthropic-ai/claude-code${RESET}\n"
    fi
    return
  fi

  local current_ver latest_ver
  current_ver=$(claude --version 2>/dev/null || echo "unknown")
  printf "\n  ${DIM}Checking Claude Code version...${RESET}"

  # npm outdated exits 1 if outdated, 0 if current
  latest_ver=$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "")
  if [ -z "$latest_ver" ]; then
    printf "\r  ${DIM}Claude Code: ${RESET}${BOLD}%s${RESET} ${DIM}(couldn't check for updates)${RESET}\n" "$current_ver"
    return
  fi

  if [ "$current_ver" = "$latest_ver" ]; then
    printf "\r  ${SUCCESS}✓${RESET} Claude Code ${BOLD}%s${RESET} ${DIM}(latest)${RESET}                    \n" "$current_ver"
  else
    printf "\r  ${WARN}⚠${RESET} Claude Code ${BOLD}%s${RESET} → ${SUCCESS}%s${RESET} available              \n" "$current_ver" "$latest_ver"
    if [ -t 0 ]; then
      printf "  Update Claude Code? ${DIM}[Y/n]${RESET} "
      read -r reply
      case "$reply" in
        [Nn]*) ;;
        *)
          printf "  ${DIM}Updating Claude Code...${RESET}\n"
          if npm install -g @anthropic-ai/claude-code@latest 2>&1 | tail -3; then
            local new_ver
            new_ver=$(claude --version 2>/dev/null || echo "unknown")
            printf "  ${SUCCESS}✓ Claude Code updated to %s${RESET}\n" "$new_ver"
          else
            printf "  ${ERROR}✗ Update failed${RESET} — try: sudo npm install -g @anthropic-ai/claude-code@latest\n"
          fi
          ;;
      esac
    else
      printf "  ${DIM}Update: npm install -g @anthropic-ai/claude-code@latest${RESET}\n"
    fi
  fi
}

# ── Reload ────────────────────────────────────────────────────────
reload_session() {
  local restart_workers=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers|--all) restart_workers=true; shift ;;
      *) shift ;;
    esac
  done

  local dir name session runtime_dir
  dir="$(pwd)"
  name="$(find_project "$dir")"
  [ -z "$name" ] && { printf "  ${ERROR}✗ No doey project for %s${RESET}\n" "$dir"; exit 1; }
  session="doey-${name}"
  runtime_dir="/tmp/doey/${name}"
  session_exists "$session" || { printf "  ${ERROR}✗ No running session: ${session}${RESET}\n"; exit 1; }
  [ -f "${runtime_dir}/session.env" ] || { printf "  ${ERROR}✗ session.env not found${RESET}\n"; exit 1; }

  printf "  ${BRAND}Reloading ${session}...${RESET}\n\n"

  # Install latest files from repo
  local repo_dir
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
  if [ -n "$repo_dir" ] && [ -d "$repo_dir" ]; then
    printf "  ${DIM}Installing latest files...${RESET}\n"
    bash "$repo_dir/install.sh" 2>&1 | sed 's/^/    /'
    printf "\n  ${SUCCESS}✓ Files installed${RESET}\n\n"
  else
    printf "  ${WARN}⚠ No repo path — skipping install${RESET}\n\n"
  fi

  # Refresh hooks in project + worktree dirs
  install_doey_hooks "$dir" "  "
  for _te in "${runtime_dir}"/team_*.env; do
    [ -f "$_te" ] || continue
    local _wt_dir
    _wt_dir=$(_env_val "$_te" WORKTREE_DIR)
    { [ -n "$_wt_dir" ] && [ -d "$_wt_dir" ] && install_doey_hooks "$_wt_dir" "  "; } || true
  done

  safe_source_session_env "${runtime_dir}/session.env"

  # Fix stale session.env WATCHDOG_PANE if not in Dashboard (0.X)
  local cur_ses_wdg
  cur_ses_wdg=$(_env_val "${runtime_dir}/session.env" WATCHDOG_PANE)
  case "$cur_ses_wdg" in
    0.*) ;;
    *)
      _tmp=$(mktemp "${runtime_dir}/session.env.XXXXXX")
      sed 's/^WATCHDOG_PANE=.*/WATCHDOG_PANE="0.2"/' "${runtime_dir}/session.env" > "$_tmp" && mv "$_tmp" "${runtime_dir}/session.env"
      grep -q '^WDG_SLOT_1=' "${runtime_dir}/session.env" || printf 'WDG_SLOT_1="0.2"\n' >> "${runtime_dir}/session.env"
      _tmp=$(mktemp "${runtime_dir}/session.env.XXXXXX")
      sed '/^MGR_SLOT_/d' "${runtime_dir}/session.env" > "$_tmp" && mv "$_tmp" "${runtime_dir}/session.env"
      printf "  ${DIM}Fixed stale WATCHDOG_PANE=%s → 0.2${RESET}\n" "$cur_ses_wdg"
      safe_source_session_env "${runtime_dir}/session.env"
      ;;
  esac

  write_worker_system_prompt "$runtime_dir" "$name" "$dir"
  printf "  ${SUCCESS}✓ Worker system prompts updated${RESET}\n"

  printf "\n  ${DIM}Reloading Manager and Watchdog...${RESET}\n"

  local team_windows="" tf tw
  for tf in "${runtime_dir}"/team_*.env; do
    [ -f "$tf" ] || continue
    tw=$(_env_val "$tf" WINDOW_INDEX)
    [ -n "$tw" ] && team_windows="$team_windows $tw"
  done

  for tw in $team_windows; do
    local team_env="${runtime_dir}/team_${tw}.env"
    [ -f "$team_env" ] || continue

    # Fix stale WATCHDOG_PANE (should be "0.X" for Dashboard slot)
    local cur_wdg
    cur_wdg=$(_env_val "$team_env" WATCHDOG_PANE)
    case "$cur_wdg" in 0.*) ;; *)
      local slot_val
      slot_val=$(_env_val "${runtime_dir}/session.env" "WDG_SLOT_${tw}")
      [ -z "$slot_val" ] && slot_val="0.${tw}"
      write_team_env "$runtime_dir" "$tw" "dynamic" "$slot_val" \
        "$(_env_val "$team_env" WORKER_PANES)" "$(_env_val "$team_env" WORKER_COUNT)" "0" "" ""
      printf "    ${DIM}Fixed team_${tw} WATCHDOG_PANE=%s → %s${RESET}\n" "$cur_wdg" "$slot_val"
      ;; esac

    local mgr_pane wdg_pane
    mgr_pane=$(_env_val "$team_env" MANAGER_PANE)
    wdg_pane=$(_env_val "$team_env" WATCHDOG_PANE)

    local worker_panes_csv worker_count_tw wp_list="" wp
    worker_panes_csv=$(_env_val "$team_env" WORKER_PANES)
    worker_count_tw=$(_env_val "$team_env" WORKER_COUNT)
    for wp in $(echo "$worker_panes_csv" | tr ',' ' '); do
      [ -n "$wp_list" ] && wp_list="${wp_list}, "
      wp_list="${wp_list}${tw}.${wp}"
    done

    # Kill and relaunch Manager
    local mgr_ref="${session}:${tw}.${mgr_pane:-0}"
    printf "    Manager %s..." "$mgr_ref"
    if _kill_pane_child "$mgr_ref"; then
      tmux send-keys -t "$mgr_ref" "clear" Enter 2>/dev/null || true
      sleep 0.5
      mgr_agent=$(generate_team_agent "doey-manager" "$tw")
      tmux send-keys -t "$mgr_ref" "claude --dangerously-skip-permissions --model $DOEY_MANAGER_MODEL --name \"T${tw} Window Manager\" --agent \"$mgr_agent\"" Enter
      printf " ${SUCCESS}✓${RESET}\n"
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
      if _kill_pane_child "$wdg_ref"; then
        tmux send-keys -t "$wdg_ref" "clear" Enter 2>/dev/null || true
        sleep 0.5
        wdg_agent=$(generate_team_agent "doey-watchdog" "$tw")
        tmux send-keys -t "$wdg_ref" "claude --dangerously-skip-permissions --model $DOEY_WATCHDOG_MODEL --name \"T${tw} Watchdog\" --agent \"$wdg_agent\"" Enter
        printf " ${SUCCESS}✓${RESET}\n"
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
      worker_panes_csv=$(_env_val "$team_env" WORKER_PANES)

      for wp in $(echo "$worker_panes_csv" | tr ',' ' '); do
        local pane_ref="${session}:${tw}.${wp}"

        # Skip already-ready workers (Claude running at prompt)
        local output
        output=$(tmux capture-pane -t "$pane_ref" -p 2>/dev/null || true)
        if echo "$output" | grep -q "bypass permissions" && echo "$output" | grep -q '❯'; then
          printf "    %s.%s ${DIM}(already ready — skipped)${RESET}\n" "$tw" "$wp"
          continue
        fi

        _kill_pane_child "$pane_ref" 1 || true
        tmux send-keys -t "$pane_ref" "clear" Enter 2>/dev/null || true
        sleep 0.5

        local w_name
        w_name=$(tmux display-message -t "$pane_ref" -p '#{pane_title}' 2>/dev/null || echo "T${tw} W${wp}")
        local worker_cmd="claude --dangerously-skip-permissions --model $DOEY_WORKER_MODEL --name \"${w_name}\""
        local worker_prompt
        worker_prompt=$(grep -rl "pane ${tw}\.${wp} " "${runtime_dir}"/worker-system-prompt-*.md 2>/dev/null | head -1)
        [ -n "$worker_prompt" ] && worker_cmd+=" --append-system-prompt-file \"${worker_prompt}\""
        tmux send-keys -t "$pane_ref" "$worker_cmd" Enter
        printf "    %s.%s ${SUCCESS}✓${RESET}\n" "$tw" "$wp"
        sleep 3
      done
    done
    printf "\n  ${SUCCESS}✓ Workers restarted${RESET}\n"
  fi

  printf "\n  ${SUCCESS}✓ Reload complete${RESET}\n"
  $restart_workers || printf "  ${DIM}Workers kept running. Use 'doey reload --workers' to restart them too.${RESET}\n"
}

# ── Uninstall ──────────────────────────────────────────────────────
uninstall_system() {
  printf '\n  %bDoey — Uninstall%b\n\n' "$BRAND" "$RESET"
  printf "  This will remove:\n"
  printf "    ${DIM}• ~/.local/bin/doey, tmux-statusbar.sh, pane-border-status.sh${RESET}\n"
  printf "    ${DIM}• ~/.claude/agents/doey-*.md${RESET}\n"
  printf "    ${DIM}• ~/.claude/doey/ (config & state)${RESET}\n"
  printf "\n  ${DIM}Will NOT remove: git repo, /tmp/doey, or agent-memory${RESET}\n\n"

  read -rp "  Continue? [y/N] " confirm
  [[ "$confirm" == [yY] ]] || { printf "  ${DIM}Cancelled.${RESET}\n\n"; return 0; }

  rm -f ~/.local/bin/doey ~/.local/bin/tmux-statusbar.sh ~/.local/bin/pane-border-status.sh
  rm -f ~/.claude/agents/doey-*.md
  rm -rf ~/.claude/doey

  printf "\n  ${SUCCESS}✓ Uninstalled.${RESET} Reinstall: ${DIM}cd <repo> && ./install.sh${RESET}\n\n"
}

# ── Doctor — check installation health ────────────────────────────────
check_doctor() {
  PROJECT_DIR="$(pwd)"
  printf '\n  %bDoey — System Check%b\n\n' "$BRAND" "$RESET"

  # Required commands — offer install if missing
  if command -v tmux >/dev/null 2>&1; then
    _doc_check ok "tmux" "$(tmux -V)"
  else
    _doc_check fail "tmux not installed"
    case "$(uname -s)" in
      Darwin) printf "\n         ${DIM}Fix: ${RESET}${BRAND}brew install tmux${RESET}\n" ;;
      Linux)  printf "\n         ${DIM}Fix: ${RESET}${BRAND}sudo apt-get install -y tmux${RESET}\n" ;;
    esac
  fi
  if command -v claude >/dev/null 2>&1; then
    local _claude_ver _claude_latest
    _claude_ver=$(claude --version 2>/dev/null || echo "unknown")
    _claude_latest=$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "")
    if [ -n "$_claude_latest" ] && [ "$_claude_ver" != "$_claude_latest" ]; then
      _doc_check warn "claude CLI" "$_claude_ver → $_claude_latest available"
      printf "\n         ${DIM}Update: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code@latest${RESET}\n"
    else
      _doc_check ok "claude CLI" "$_claude_ver${_claude_latest:+ (latest)}"
    fi
  else
    _doc_check fail "claude CLI not found"
    if command -v node >/dev/null 2>&1; then
      printf "\n         ${DIM}Fix: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n"
    else
      printf "\n         ${DIM}Fix: Install Node.js 18+ first, then: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n"
    fi
  fi

  # Auth check
  local auth_json
  auth_json=$(claude auth status 2>&1) || auth_json=""
  if echo "$auth_json" | grep -q '"loggedIn": true'; then
    local _auth_method _auth_email _auth_sub
    _auth_method=$(echo "$auth_json" | grep '"authMethod"' | sed 's/.*: *"//;s/".*//')
    _auth_email=$(echo "$auth_json" | grep '"email"' | sed 's/.*: *"//;s/".*//')
    _auth_sub=$(echo "$auth_json" | grep '"subscriptionType"' | sed 's/.*: *"//;s/".*//')
    _doc_check ok "Claude auth" "${_auth_method} · ${_auth_email} · ${_auth_sub}"
  else
    _doc_check fail "Claude auth" "Not logged in — run 'claude' to authenticate"
  fi

  # PATH check
  if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then _doc_check ok "~/.local/bin in PATH"
  else _doc_check warn "~/.local/bin not in PATH"; fi

  # Installed files
  local _f _label
  for _f in "$HOME/.claude/agents/doey-manager.md:Agents" \
            "$PROJECT_DIR/.claude/skills/doey-dispatch/SKILL.md:Skills" \
            "$HOME/.local/bin/doey:CLI"; do
    _label="${_f##*:}"; _f="${_f%:*}"
    if [[ -f "$_f" ]]; then _doc_check ok "$_label installed" "${_f/#$HOME/~}"
    else _doc_check fail "$_label missing" "${_f/#$HOME/~}"; fi
  done

  # Repo path
  local repo_dir=""
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
  if [[ -n "$repo_dir" ]]; then
    if [[ -d "$repo_dir" ]]; then _doc_check ok "Repo registered" "$repo_dir"
    else _doc_check fail "Repo dir missing" "$repo_dir"; fi
  else
    _doc_check fail "Repo not registered" "~/.claude/doey/repo-path missing"
  fi

  # Optional: jq
  if command -v jq >/dev/null 2>&1; then _doc_check ok "jq" "$(jq --version 2>/dev/null || echo 'unknown')"
  else _doc_check warn "jq not found — auto-trust skipped"; fi

  # Version
  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    _doc_check ok "Version" "$(_env_val "$version_file" version) ($(_env_val "$version_file" date))"
  else
    _doc_check warn "No version file" "Run 'doey update'"
  fi

  # Context audit
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/context-audit.sh" ]]; then
    local audit_output
    if audit_output=$(bash "$repo_dir/shell/context-audit.sh" --installed --no-color 2>&1); then
      _doc_check ok "Context audit clean"
    else
      _doc_check warn "Context audit issues:"
      printf '%s\n' "$audit_output"
    fi
  else
    _doc_check skip "Context audit" "(script not found)"
  fi

  printf '\n'
}

# ── Remove — unregister a project ────────────────────────────────────
remove_project() {
  local name="${1:-}"
  [[ -z "$name" ]] && name="$(find_project "$(pwd)")"

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

  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { printf "  ${ERROR}Invalid project name: %s${RESET}\n" "$name"; return 1; }
  grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null || { printf "  ${ERROR}No project '%s' in registry${RESET}\n" "$name"; return 1; }

  grep -v "^${name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
  printf "  ${SUCCESS}Removed '%s' from registry${RESET}\n" "$name"
  session_exists "doey-${name}" && \
    printf "  ${WARN}Session doey-%s still running — use 'doey stop' to stop it${RESET}\n" "$name"
}

# ── Version — show installation info ─────────────────────────────────
show_version() {
  printf '\n  %bDoey%b\n\n' "$BRAND" "$RESET"

  local version_file="$HOME/.claude/doey/version"
  local repo_dir=""

  if [[ -f "$version_file" ]]; then
    repo_dir="$(_env_val "$version_file" repo)"
    printf "  ${DIM}Version${RESET}    ${BOLD}%s${RESET}  ${DIM}(installed %s)${RESET}\n" \
      "$(_env_val "$version_file" version)" "$(_env_val "$version_file" date)"
  else
    repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
    if [[ -d "${repo_dir:-}" ]]; then
      printf "  ${DIM}Version${RESET}    ${BOLD}%s${RESET}  ${DIM}(no version file — reinstall to track)${RESET}\n" \
        "$(git -C "$repo_dir" log -1 --format="%h (%ci)" 2>/dev/null || echo 'unknown')"
    fi
  fi

  if [[ -n "$repo_dir" ]] && [[ -d "$repo_dir/.git" ]]; then
    printf "  ${DIM}Status${RESET}     "
    if ! git -C "$repo_dir" fetch origin main --quiet 2>/dev/null; then
      printf "${DIM}Could not reach remote${RESET}\n"
    else
      local behind_count ahead_count
      behind_count=$(git -C "$repo_dir" rev-list --count HEAD..origin/main 2>/dev/null || echo '0')
      ahead_count=$(git -C "$repo_dir" rev-list --count origin/main..HEAD 2>/dev/null || echo '0')
      if [[ "$behind_count" -gt 0 ]] 2>/dev/null; then
        printf "${WARN}⚠ %s commit(s) behind${RESET}  ${DIM}(run: doey update)${RESET}\n" "$behind_count"
      elif [[ "$ahead_count" -gt 0 ]] 2>/dev/null; then
        printf "${SUCCESS}✓ Up to date${RESET}  ${DIM}(%s local commit(s) ahead)${RESET}\n" "$ahead_count"
      else
        printf "${SUCCESS}✓ Up to date${RESET}\n"
      fi
    fi
  fi

  printf "  ${DIM}Agents${RESET}     ${BOLD}~/.claude/agents/${RESET}\n"
  printf "  ${DIM}Skills${RESET}     ${BOLD}.claude/skills/${RESET}\n"
  printf "  ${DIM}CLI${RESET}        ${BOLD}~/.local/bin/doey${RESET}\n"
  local project_count=0
  [[ -f "$PROJECTS_FILE" ]] && project_count="$(grep -c '.' "$PROJECTS_FILE" 2>/dev/null || echo 0)"
  printf "  ${DIM}Projects${RESET}   ${BOLD}%s registered${RESET}\n" "$project_count"

  printf '\n'
}

# ── Auto-update check ─────────────────────────────────────────────
check_for_updates() {
  local state_dir="$HOME/.claude/doey"
  local cache_file="$state_dir/last-update-check.available"

  [[ -f "$state_dir/repo-path" ]] || return 0
  local repo_dir
  repo_dir="$(cat "$state_dir/repo-path")"
  [[ -d "$repo_dir/.git" ]] || return 0

  local now
  now=$(date +%s)

  # Show cached result
  if [[ -f "$cache_file" ]]; then
    local behind
    behind=$(cat "$cache_file")
    [[ "$behind" -gt 0 ]] 2>/dev/null && \
      printf "  ${WARN}⚠ Update available${RESET} ${DIM}(%s commit(s) behind — run: doey update)${RESET}\n" "$behind"
  fi

  # Skip if checked within 24h
  local last_check_file="$state_dir/last-update-check"
  if [[ -f "$last_check_file" ]]; then
    local last_ts
    last_ts=$(cat "$last_check_file")
    (( now - last_ts < 86400 )) && return 0
  fi

  # Background fetch (non-blocking)
  (
    echo "$now" > "$last_check_file"
    if git -C "$repo_dir" fetch origin main --quiet 2>/dev/null; then
      git -C "$repo_dir" rev-list --count HEAD..origin/main 2>/dev/null > "$cache_file" || echo 0 > "$cache_file"
    fi
  ) &
  disown 2>/dev/null
}

# Shared session bootstrap: cleanup, worker prompt, tmux session, team window
# NOTE: Does NOT call setup_dashboard — caller must write session.env first, then call setup_dashboard
_init_doey_session() {
  local session="$1" runtime_dir="$2" dir="$3" name="$4"
  _cleanup_old_session "$session" "$runtime_dir"
  write_worker_system_prompt "$runtime_dir" "$name" "$dir"
  tmux new-session -d -s "$session" -x 250 -y 80 -c "$dir" >/dev/null
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}"
  # Export config values so hooks (running in subshells) can read them
  tmux set-environment -t "$session" DOEY_WATCHDOG_SCAN_INTERVAL "$DOEY_WATCHDOG_SCAN_INTERVAL"
  tmux set-environment -t "$session" DOEY_WATCHDOG_LOOP_DELAY "$DOEY_WATCHDOG_LOOP_DELAY"
  tmux set-environment -t "$session" DOEY_INFO_PANEL_REFRESH "$DOEY_INFO_PANEL_REFRESH"
}

launch_session_headless() {
  local name="$1" dir="$2" grid="${3:-6x2}"
  local session="doey-${name}"
  local worker_count=$(( ${grid%x*} * ${grid#*x} - 1 ))

  _launch_session_core "$name" "$dir" "$grid" 1

  printf "  ${SUCCESS}Team launched${RESET} — session ${BOLD}%s${RESET} with %s workers\n" "$session" "$worker_count"
}

launch_session_dynamic() {
  local name="$1" dir="$2"
  local session="doey-${name}" runtime_dir="/tmp/doey/${name}"
  local short_dir="${dir/#$HOME/~}" max_workers=20
  local team_window=1

  cd "$dir"

  _print_full_banner "Let Doey do it for you"
  local initial_workers=$(( INITIAL_WORKER_COLS * 2 ))
  printf "   ${DIM}Project${RESET} ${BOLD}${name}${RESET}  ${DIM}Grid${RESET} ${BOLD}dynamic${RESET}  ${DIM}Workers${RESET} ${BOLD}${initial_workers} (auto-expands)${RESET}\n"
  printf "   ${DIM}Dir${RESET} ${BOLD}${short_dir}${RESET}  ${DIM}Session${RESET} ${BOLD}${session}${RESET}\n"
  printf '\n'

  ensure_project_trusted "$dir"
  install_doey_hooks "$dir" "   "

  STEP_TOTAL=7
  step_start 1 "Creating session for ${name}..."
  _init_doey_session "$session" "$runtime_dir" "$dir" "$name"

  step_done

  step_start 2 "Applying theme..."
  local border_fmt=' #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#{pane_title} #[default]'
  apply_doey_theme "$session" "$name" "$border_fmt" 5
  step_done

  step_start 3 "Setting up grid..."

  local acronym
  acronym=$(project_acronym "$name")

  cat > "${runtime_dir}/session.env" << MANIFEST
PROJECT_DIR="$dir"
PROJECT_NAME="$name"
PROJECT_ACRONYM="$acronym"
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
SM_PANE="0.1"
MANIFEST

  local _si
  for (( _si=1; _si<=INITIAL_TEAMS; _si++ )); do
    echo "WDG_SLOT_${_si}=\"0.$((_si + 1))\"" >> "${runtime_dir}/session.env"
  done
  write_team_env "$runtime_dir" "1" "dynamic" "0.2" "" "0" "0" "" ""

  # Dashboard launches after session.env exists (info-panel + Session Manager need it)
  setup_dashboard "$session" "$dir" "$runtime_dir" "$INITIAL_TEAMS"
  tmux new-window -t "$session" -c "$dir"
  tmux select-pane -t "$session:${team_window}.0" -T "T${team_window} Window Manager"
  tmux rename-window -t "$session:${team_window}" "Local Team"

  step_done

  step_start 4 "Launching Window Manager & Watchdog..."
  _launch_team_manager "$session" "$runtime_dir" "$team_window"
  _launch_team_watchdog "$session" "${WDG_SLOT_1}" "$team_window"
  _brief_team "$session" "$team_window" "${WDG_SLOT_1}" "" "0" \
    "Dynamic grid — ${initial_workers} initial workers, auto-expands when all are busy"
  step_done

  step_start 5 "Adding ${INITIAL_WORKER_COLS} worker columns (${initial_workers} workers)..."
  sleep 0.2  # reduced from 0.5s — tmux is fast
  local _col_i
  for (( _col_i=0; _col_i<INITIAL_WORKER_COLS; _col_i++ )); do
    doey_add_column "$session" "$runtime_dir" "$dir"
    (( _col_i < INITIAL_WORKER_COLS - 1 )) && sleep 0.3
  done
  step_done

  # Per-team config mode: when DOEY_TEAM_COUNT is set, use DOEY_TEAM_<N>_* variables
  if [ -n "${DOEY_TEAM_COUNT:-}" ] && [ "${DOEY_TEAM_COUNT:-0}" -gt 0 ]; then
    local _ptc_total="${DOEY_TEAM_COUNT}"
    local _ptc_remaining=$((_ptc_total - 1))  # Team 1 already created above
    if [ "$_ptc_remaining" -gt 0 ]; then
      step_start 6 "Adding ${_ptc_remaining} configured teams..."
      local TEAM_LAUNCH_DELAY=$DOEY_TEAM_LAUNCH_DELAY
      local _ptc_i _ptc_fail=0
      for (( _ptc_i=2; _ptc_i<=_ptc_total; _ptc_i++ )); do
        local _ptc_type _ptc_workers _ptc_name _ptc_role _ptc_wm _ptc_mm _ptc_cols _ptc_wt_spec
        _ptc_type=$(_read_team_config "$_ptc_i" "TYPE" "")
        _ptc_workers=$(_read_team_config "$_ptc_i" "WORKERS" "")
        _ptc_name=$(_read_team_config "$_ptc_i" "NAME" "")
        _ptc_role=$(_read_team_config "$_ptc_i" "ROLE" "")
        _ptc_wm=$(_read_team_config "$_ptc_i" "WORKER_MODEL" "")
        _ptc_mm=$(_read_team_config "$_ptc_i" "MANAGER_MODEL" "")

        # Default type based on position
        if [ -z "$_ptc_type" ]; then
          if [ "$_ptc_i" -le "${DOEY_INITIAL_TEAMS:-2}" ]; then _ptc_type="local"; else _ptc_type="worktree"; fi
        fi
        # Default worker count from grid
        [ -z "$_ptc_workers" ] && _ptc_workers=$(( ${DOEY_INITIAL_WORKER_COLS:-2} * 2 ))
        # Convert workers to cols: cols = ceil(workers/2) — dynamic grid uses 2 rows
        _ptc_cols=$(( (_ptc_workers + 1) / 2 ))
        [ "$_ptc_cols" -lt 1 ] && _ptc_cols=1

        _ptc_wt_spec=""
        [ "$_ptc_type" = "worktree" ] && _ptc_wt_spec="auto"

        if ! ( add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$_ptc_cols" "$_ptc_wt_spec" "$_ptc_name" "$_ptc_role" "$_ptc_wm" "$_ptc_mm" ); then
          _ptc_fail=$((_ptc_fail + 1))
        fi
        (( _ptc_i < _ptc_total )) && sleep $TEAM_LAUNCH_DELAY
      done
      [ "$_ptc_fail" -gt 0 ] && printf "${WARN}${_ptc_fail} team(s) failed${RESET}\n"
      step_done
    fi
    # Update team 1's env with per-team config if specified
    local _ptc1_name _ptc1_role _ptc1_wm _ptc1_mm
    _ptc1_name=$(_read_team_config "1" "NAME" "")
    _ptc1_role=$(_read_team_config "1" "ROLE" "")
    _ptc1_wm=$(_read_team_config "1" "WORKER_MODEL" "")
    _ptc1_mm=$(_read_team_config "1" "MANAGER_MODEL" "")
    if [ -n "$_ptc1_name" ] || [ -n "$_ptc1_role" ] || [ -n "$_ptc1_wm" ] || [ -n "$_ptc1_mm" ]; then
      local _ptc1_wp _ptc1_wc
      _ptc1_wp=$(_env_val "${runtime_dir}/team_1.env" WORKER_PANES)
      _ptc1_wc=$(_env_val "${runtime_dir}/team_1.env" WORKER_COUNT)
      write_team_env "$runtime_dir" "1" "dynamic" "0.2" "$_ptc1_wp" "$_ptc1_wc" "0" "" "" "$_ptc1_name" "$_ptc1_role" "$_ptc1_wm" "$_ptc1_mm"
      [ -n "$_ptc1_name" ] && tmux rename-window -t "$session:1" "$_ptc1_name"
    fi
  else
    local _extra_teams=$((INITIAL_TEAMS - 1))
    if [ "$_extra_teams" -gt 0 ]; then
      step_start 6 "Adding ${_extra_teams} more team windows..."
      # Serialize team launches to prevent concurrent OAuth token requests
      local TEAM_LAUNCH_DELAY=$DOEY_TEAM_LAUNCH_DELAY
      local _team_i _team_fail=0
      for (( _team_i=0; _team_i<_extra_teams; _team_i++ )); do
        if ! ( add_dynamic_team_window "$session" "$runtime_dir" "$dir" ); then
          _team_fail=$((_team_fail + 1))
        fi
        (( _team_i < _extra_teams - 1 )) && sleep $TEAM_LAUNCH_DELAY
      done
      [ "$_team_fail" -gt 0 ] && printf "${WARN}${_team_fail} team(s) failed${RESET}\n"
      step_done
    fi

    local INITIAL_WORKTREE_TEAMS=$DOEY_INITIAL_WORKTREE_TEAMS
    step_start 7 "Adding ${INITIAL_WORKTREE_TEAMS} isolated worktree teams..."
    # Serialize worktree team launches to prevent concurrent OAuth token requests
    local TEAM_LAUNCH_DELAY=$DOEY_TEAM_LAUNCH_DELAY
    local _wt_i _wt_ok=0
    for (( _wt_i=0; _wt_i<INITIAL_WORKTREE_TEAMS; _wt_i++ )); do
      if ( add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$INITIAL_WORKER_COLS" "auto" ); then
        _wt_ok=$((_wt_ok + 1))
      fi
      (( _wt_i < INITIAL_WORKTREE_TEAMS - 1 )) && sleep $TEAM_LAUNCH_DELAY
    done
    if [ "$_wt_ok" -gt 0 ]; then
      step_done
    else
      printf "${WARN}skipped${RESET}\n"
    fi
  fi  # end of DOEY_TEAM_COUNT check

  local final_team_windows team_count=0 _tw
  final_team_windows=$(read_team_windows "$runtime_dir")
  for _tw in $(echo "$final_team_windows" | tr ',' ' '); do
    team_count=$((team_count + 1))
  done

  (
    sleep 20
    tmux send-keys -t "$session:${SM_PANE}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. ${team_count} team windows (${final_team_windows}). Team 1 has ${initial_workers} workers (dynamic grid, auto-expands). Use /doey-add-window to create new team windows and /doey-list-windows to see all teams. Awaiting instructions." Enter
  ) &

  printf '\n'
  printf "   ${SUCCESS}Doey is ready${RESET}  ${DIM}(dynamic grid)${RESET}\n"
  printf "   ${DIM}──────────────────────────────────────────────────${RESET}\n"
  printf "\n"
  printf "   ${BOLD}Dashboard${RESET}  ${DIM}win 0  Info panel + Session Manager${RESET}\n"
  printf "   ${BOLD}Teams${RESET}      ${DIM}%-4s windows (${final_team_windows})${RESET}\n" "$team_count"
  printf "   ${BOLD}Watchdogs${RESET}  ${DIM}0.2-0.7  Online (Dashboard)${RESET}\n"
  printf "   ${BOLD}Workers${RESET}    ${DIM}T1: %-4s (auto-expands, doey add)${RESET}\n" "$initial_workers"
  printf "\n"
  printf "   ${DIM}Project${RESET}   ${BOLD}%s${RESET}\n" "$name"
  printf "   ${DIM}Grid${RESET}      ${BOLD}dynamic${RESET}  ${DIM}Max workers${RESET}  ${BOLD}%s${RESET}\n" "$max_workers"
  printf "   ${DIM}Session${RESET}   ${BOLD}%s${RESET}\n" "$session"
  printf "   ${DIM}Manifest${RESET}  ${BOLD}%s${RESET}\n" "${runtime_dir}/session.env"
  printf "\n"
  printf "   ${DIM}Tip: doey add — adds 2 more workers${RESET}\n"
  printf "   ${DIM}──────────────────────────────────────────────────${RESET}\n"
  printf '\n'

  tmux select-window -t "$session:0"
  attach_or_switch "$session"
}

_layout_checksum() {
  local s="$1" csum=0 i c
  for ((i=0; i<${#s}; i++)); do
    c=$(printf '%d' "'${s:$i:1}")
    csum=$(( ((csum >> 1) + ((csum & 1) << 15) + c) & 0xffff ))
  done
  printf '%04x' "$csum"
}

rebalance_grid_layout() {
  local session="$1" team_window="${2:-1}" mgr_width=60

  local win_w win_h
  win_w="$(tmux display-message -t "$session:${team_window}" -p '#{window_width}')"
  win_h="$(tmux display-message -t "$session:${team_window}" -p '#{window_height}')"

  local pane_ids=()
  while IFS=$'\t' read -r _idx _pid; do
    pane_ids+=("${_pid#%}")
  done < <(tmux list-panes -t "$session:${team_window}" -F '#{pane_index}	#{pane_id}')

  local num_panes=${#pane_ids[@]}
  if (( num_panes < 3 )); then return 0; fi

  local num_workers=$((num_panes - 1))
  local worker_cols=$(( (num_workers + 1) / 2 ))

  # Cap manager width at 25% of window
  local max_mgr=$((win_w / 4))
  (( mgr_width > max_mgr )) && mgr_width=$max_mgr

  local worker_area=$((win_w - mgr_width - 1))
  local top_h=$((win_h / 2)) bot_h=$((win_h - win_h / 2 - 1))

  # Manager column (full height), then worker columns (2 rows each)
  local body="" x=0
  body="${mgr_width}x${win_h},${x},0,${pane_ids[0]}"
  x=$((mgr_width + 1))

  local c w wi
  for ((c=0; c<worker_cols; c++)); do
    if ((c == worker_cols - 1)); then
      w=$((win_w - x))
    else
      w=$((worker_area / worker_cols))
    fi

    wi=$((c * 2 + 1))
    local tp="${pane_ids[$wi]}"
    body+=","
    if (( wi + 1 < num_panes )); then
      local bp="${pane_ids[$((wi + 1))]}"
      body+="${w}x${win_h},${x},0[${w}x${top_h},${x},0,${tp},${w}x${bot_h},${x},$((top_h+1)),${bp}]"
    else
      body+="${w}x${win_h},${x},0,${tp}"
    fi
    x=$((x + w + 1))
  done

  local layout_str="${win_w}x${win_h},0,0{${body}}"
  tmux select-layout -t "$session:${team_window}" "$(_layout_checksum "$layout_str"),${layout_str}" 2>/dev/null || true
}

rebuild_pane_state() {
  local session="$1"
  _worker_panes=""
  local pidx
  while IFS='' read -r pidx; do
    [ "$pidx" = "0" ] && continue
    [ -n "$_worker_panes" ] && _worker_panes+=","
    _worker_panes+="$pidx"
  done < <(tmux list-panes -t "$session" -F '#{pane_index}')
}

_read_team_state() {
  local session="$1" runtime_dir="$2" dir="$3" team_window="$4"
  local team_env="${runtime_dir}/team_${team_window}.env"

  _ts_dir="$dir" _ts_wt_dir="" _ts_wt_branch=""

  if [ ! -f "$team_env" ]; then
    _ts_worker_count=0 _ts_watchdog_pane="${WATCHDOG_PANE}"
    _ts_grid="${GRID:-dynamic}" _ts_cols=1 _ts_worker_panes=""
    return 0
  fi

  _ts_worker_count=$(_env_val "$team_env" WORKER_COUNT); _ts_worker_count="${_ts_worker_count:-0}"
  _ts_watchdog_pane=$(_env_val "$team_env" WATCHDOG_PANE)
  _ts_grid=$(_env_val "$team_env" GRID); _ts_grid="${_ts_grid:-dynamic}"
  _ts_worker_panes=$(_env_val "$team_env" WORKER_PANES)
  _ts_wt_dir=$(_env_val "$team_env" WORKTREE_DIR)
  _ts_wt_branch=$(_env_val "$team_env" WORKTREE_BRANCH)

  local _pane_count
  _pane_count=$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l | tr -d ' ')
  _ts_cols=$(( (_pane_count - 1) / 2 ))
  [ "$_ts_cols" -lt 1 ] && _ts_cols=1

  [ -n "$_ts_wt_dir" ] && [ -d "$_ts_wt_dir" ] && _ts_dir="$_ts_wt_dir"
  return 0
}

# Boot multiple workers in parallel: send all launch commands, then wait once.
# Usage: _batch_boot_workers <session> <runtime_dir> <team_window> <pane_idx:worker_num> ...
# Each trailing arg is a pane_idx:worker_num pair (e.g. "1:1" "2:2" "5:3").
_batch_boot_workers() {
  local session="$1" runtime_dir="$2" team_window="$3"
  shift 3

  # Stagger launches to prevent concurrent OAuth token requests that exhaust auth sessions
  local WORKER_LAUNCH_DELAY=$DOEY_WORKER_LAUNCH_DELAY

  local _bbw_acronym=""
  [ -f "${runtime_dir}/session.env" ] && _bbw_acronym=$(_env_val "${runtime_dir}/session.env" PROJECT_ACRONYM)

  local _bbw_worker_model
  _bbw_worker_model=$(_env_val "${runtime_dir}/team_${team_window}.env" WORKER_MODEL)
  [ -z "$_bbw_worker_model" ] && _bbw_worker_model="$DOEY_WORKER_MODEL"

  local pair pane_idx worker_num
  for pair in "$@"; do
    pane_idx="${pair%%:*}"
    worker_num="${pair##*:}"
    local prompt_suffix="w${team_window}-${worker_num}"
    local prompt_file="${runtime_dir}/worker-system-prompt-${prompt_suffix}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$prompt_file"
    local _bbw_pane_id="t${team_window}-w${worker_num}"
    [ -n "$_bbw_acronym" ] && _bbw_pane_id="${_bbw_acronym}-${_bbw_pane_id}"
    printf '\n\n## Identity\nYou are Worker %s (%s) in pane %s.%s of session %s.\n' \
      "$worker_num" "$_bbw_pane_id" "$team_window" "$pane_idx" "$session" >> "$prompt_file"

    local cmd="claude --dangerously-skip-permissions --model $_bbw_worker_model --name \"T${team_window} W${worker_num}\""
    cmd+=" --append-system-prompt-file \"${prompt_file}\""
    tmux send-keys -t "$session:${team_window}.${pane_idx}" "$cmd" Enter
    sleep $WORKER_LAUNCH_DELAY  # Auth stagger between worker launches

    write_pane_status "$runtime_dir" "${session}:${team_window}.${pane_idx}" "READY"
  done

  sleep 3
}

doey_add_column() {
  local session="$1" runtime_dir="$2" dir="$3" team_window="${4:-1}"

  safe_source_session_env "${runtime_dir}/session.env"
  _read_team_state "$session" "$runtime_dir" "$dir" "$team_window"

  local max_workers="${MAX_WORKERS:-20}"
  if [[ "$_ts_grid" != "dynamic" ]]; then
    printf "  ${ERROR}Team window %s is not using dynamic grid mode${RESET}\n" "$team_window"
    return 1
  fi
  if (( _ts_worker_count >= max_workers )); then
    printf "  ${ERROR}Max workers reached (%s)${RESET}\n" "$max_workers"
    return 1
  fi

  printf "  ${DIM}Adding worker column to team %s...${RESET}\n" "$team_window"

  local last_pane new_pane_top new_pane_bottom
  last_pane="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"
  tmux split-window -h -t "$session:$team_window.${last_pane}" -c "$_ts_dir"
  sleep 0.1
  new_pane_top="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"
  tmux split-window -v -t "$session:$team_window.${new_pane_top}" -c "$_ts_dir"
  sleep 0.1
  new_pane_bottom="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"

  local w1_num=$(( _ts_worker_count + 1 )) w2_num=$(( _ts_worker_count + 2 ))
  tmux select-pane -t "$session:$team_window.${new_pane_top}" -T "T${team_window} W${w1_num}"
  tmux select-pane -t "$session:$team_window.${new_pane_bottom}" -T "T${team_window} W${w2_num}"

  rebuild_pane_state "$session:$team_window"

  local new_worker_count=$(( _ts_worker_count + 2 ))
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$_ts_watchdog_pane" "$_worker_panes" "$new_worker_count" "" "$_ts_wt_dir" "$_ts_wt_branch"

  _batch_boot_workers "$session" "$runtime_dir" "$team_window" "${new_pane_top}:${w1_num}" "${new_pane_bottom}:${w2_num}"
  rebalance_grid_layout "$session" "$team_window"

  printf "  ${SUCCESS}Added${RESET} W${BOLD}${w1_num}${RESET} and W${BOLD}${w2_num}${RESET} — ${new_worker_count} workers in $((_ts_cols + 1)) columns\n"
}

doey_remove_column() {
  local session="$1" runtime_dir="$2" col_index="${3:-}" team_window="${4:-1}"

  safe_source_session_env "${runtime_dir}/session.env"
  _read_team_state "$session" "$runtime_dir" "${PROJECT_DIR}" "$team_window"

  if [[ "$_ts_grid" != "dynamic" ]]; then
    printf "  ${ERROR}Team window %s is not using dynamic grid mode${RESET}\n" "$team_window"
    return 1
  fi
  if (( _ts_worker_count == 0 )); then
    printf "  ${ERROR}No worker columns to remove${RESET}\n"
    return 1
  fi

  [[ -z "$col_index" ]] && col_index="last"

  # Parse worker panes into positional params (bash 3.2 safe)
  local _old_ifs="$IFS"; IFS=','; set -- $_ts_worker_panes; IFS="$_old_ifs"
  if [ "$#" -lt 2 ]; then
    printf "  ${ERROR}Not enough worker panes to remove a column${RESET}\n"
    return 1
  fi

  local remove_top remove_bottom
  if [ "$col_index" = "last" ]; then
    eval "remove_top=\${$(( $# - 1 ))}"
    eval "remove_bottom=\${$#}"
  else
    local ci=$(( col_index ))
    if [ "$ci" -lt 1 ] || [ "$ci" -gt $(( _ts_worker_count / 2 )) ]; then
      printf "  ${ERROR}Invalid column: %s (valid: 1-%s)${RESET}\n" "$col_index" "$(( _ts_worker_count / 2 ))"
      return 1
    fi
    local pair_start=$(( (ci - 1) * 2 + 1 ))
    eval "remove_top=\${${pair_start}}"
    eval "remove_bottom=\${$(( pair_start + 1 ))}"
  fi

  printf "  ${DIM}Removing panes ${team_window}.${remove_top} and ${team_window}.${remove_bottom}...${RESET}\n"

  # Stop processes in both panes
  local pane_idx pane_pid
  for pane_idx in "$remove_top" "$remove_bottom"; do
    pane_pid=$(tmux display-message -t "$session:$team_window.${pane_idx}" -p '#{pane_pid}' 2>/dev/null || true)
    [ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null || true
  done
  sleep 0.5  # reduced from 1s — tmux is fast

  # Kill higher index first to avoid index shift
  if (( remove_top > remove_bottom )); then
    tmux kill-pane -t "$session:$team_window.${remove_top}" 2>/dev/null || true
    tmux kill-pane -t "$session:$team_window.${remove_bottom}" 2>/dev/null || true
  else
    tmux kill-pane -t "$session:$team_window.${remove_bottom}" 2>/dev/null || true
    tmux kill-pane -t "$session:$team_window.${remove_top}" 2>/dev/null || true
  fi
  sleep 0.5

  rebuild_pane_state "$session:$team_window"

  local new_worker_count=$(( _ts_worker_count - 2 ))
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$_ts_watchdog_pane" "$_worker_panes" "$new_worker_count" "" "$_ts_wt_dir" "$_ts_wt_branch"
  rebalance_grid_layout "$session" "$team_window"

  printf "  ${SUCCESS}Removed${RESET} worker column — ${BOLD}${new_worker_count}${RESET} workers remaining\n"
}

add_dashboard_watchdog_slot() {
  local session="$1" runtime_dir="$2" dir="$3"

  local slot_count=0 last_slot="" _line _sv
  while IFS= read -r _line; do
    _sv="${_line#*=}"; _sv="${_sv//\"/}"
    [ -n "$_sv" ] || continue
    slot_count=$((slot_count + 1))
    last_slot="$_sv"
  done < <(grep '^WDG_SLOT_[0-9]*=' "${runtime_dir}/session.env" 2>/dev/null)

  if [ "$slot_count" -ge "$MAX_WATCHDOG_SLOTS" ]; then
    WDG_NEW_SLOT=""
    return 1
  fi

  tmux split-window -h -t "${session}:${last_slot}" -c "$dir"
  sleep 0.3

  # Defensive re-count: re-read session.env for true slot count after split
  local _recount=0 _rl
  while IFS= read -r _rl; do
    _recount=$((_recount + 1))
  done < <(grep '^WDG_SLOT_[0-9]*=' "${runtime_dir}/session.env" 2>/dev/null)
  if [ "$_recount" -gt "$slot_count" ]; then
    slot_count="$_recount"
  fi

  local new_slot_num=$((slot_count + 1))
  local new_slot="0.$((new_slot_num + 1))"

  tmux select-pane -t "${session}:${new_slot}" -T "T${new_slot_num} Watchdog"
  _balance_watchdog_panes "$session" "$new_slot_num"
  echo "WDG_SLOT_${new_slot_num}=\"${new_slot}\"" >> "${runtime_dir}/session.env"
  tmux send-keys -t "${session}:${new_slot}" "echo 'Watchdog slot — awaiting team assignment...'" Enter

  WDG_NEW_SLOT="$new_slot"
  return 0
}

_apply_team_border_theme() {
  local session="$1" window_index="$2"
  local target="${session}:${window_index}"
  local border_fmt=" #{?pane_active,#[fg=cyan,bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  tmux set-window-option -t "$target" pane-border-status top
  tmux set-window-option -t "$target" pane-border-format "$border_fmt"
  tmux set-window-option -t "$target" pane-border-style 'fg=colour238'
  tmux set-window-option -t "$target" pane-active-border-style 'fg=cyan'
  tmux set-window-option -t "$target" pane-border-lines heavy
}

# Atomically update a field in session.env
_set_session_env() {
  local runtime_dir="$1" field="$2" value="$3"
  local _lock="${runtime_dir}/.session_env_lock"
  local _retries=0
  while ! mkdir "$_lock" 2>/dev/null; do
    _retries=$((_retries + 1))
    if [ "$_retries" -gt 20 ]; then
      rmdir "$_lock" 2>/dev/null
      break
    fi
    sleep 0.1
  done
  local _tmp="${runtime_dir}/session.env.tmp.$$"
  # Escape sed metacharacters in value to prevent injection (/, &, \)
  local _escaped_value
  _escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
  sed "s/^${field}=.*/${field}=\"${_escaped_value}\"/" "${runtime_dir}/session.env" > "$_tmp"
  mv "$_tmp" "${runtime_dir}/session.env"
  rmdir "$_lock" 2>/dev/null || true
}

_register_team_window() {
  local runtime_dir="$1" window_index="$2"
  _set_session_env "$runtime_dir" TEAM_WINDOWS "$(read_team_windows "$runtime_dir"),${window_index}"
}

_unregister_team_window() {
  local runtime_dir="$1" window="$2"
  local current new_windows="" w
  current=$(read_team_windows "$runtime_dir")
  local _old_ifs="$IFS"; IFS=','
  for w in $current; do
    [ "$w" = "$window" ] && continue
    [ -n "$new_windows" ] && new_windows="${new_windows},"
    new_windows="${new_windows}${w}"
  done
  IFS="$_old_ifs"
  _set_session_env "$runtime_dir" TEAM_WINDOWS "$new_windows"
}

_ensure_worker_prompt() {
  local runtime_dir="$1" team_dir="$2"
  [ -f "${runtime_dir}/worker-system-prompt.md" ] && return 0
  local project_name
  project_name=$(_env_val "${runtime_dir}/session.env" PROJECT_NAME)
  write_worker_system_prompt "$runtime_dir" "$project_name" "$team_dir"
}

_launch_team_manager() {
  local session="$1" runtime_dir="$2" window_index="$3"
  local mgr_model="${4:-}"
  [ -z "$mgr_model" ] && mgr_model=$(_env_val "${runtime_dir}/team_${window_index}.env" MANAGER_MODEL)
  [ -z "$mgr_model" ] && mgr_model="$DOEY_MANAGER_MODEL"
  local mgr_agent
  mgr_agent=$(generate_team_agent "doey-manager" "$window_index")
  tmux send-keys -t "${session}:${window_index}.0" \
    "claude --dangerously-skip-permissions --model $mgr_model --name \"T${window_index} Window Manager\" --agent \"$mgr_agent\"" Enter
  tmux select-pane -t "${session}:${window_index}.0" -T "T${window_index} Window Manager"
  sleep 0.2  # reduced from 0.5s — tmux is fast
  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"
}

_launch_team_watchdog() {
  local session="$1" wdg_slot="$2" window_index="$3"
  local wdg_model="${4:-$DOEY_WATCHDOG_MODEL}"
  [ -n "$wdg_slot" ] || return 0
  tmux send-keys -t "${session}:${wdg_slot}" C-c
  sleep 0.3
  local wdg_agent
  wdg_agent=$(generate_team_agent "doey-watchdog" "$window_index")
  tmux send-keys -t "${session}:${wdg_slot}" \
    "claude --dangerously-skip-permissions --model $wdg_model --name \"T${window_index} Watchdog\" --agent \"$wdg_agent\"" Enter
  tmux select-pane -t "${session}:${wdg_slot}" -T "T${window_index} Watchdog"
  sleep 0.2  # reduced from 0.5s — tmux is fast
}

_brief_team() {
  local session="$1" window_index="$2" wdg_slot="$3" wp_list="$4"
  local worker_count="$5" grid_desc="$6" wt_brief="${7:-}"
  local team_name="${8:-}" team_role="${9:-}"
  local _role_brief=""
  [ -n "$team_role" ] && _role_brief=" Team role: ${team_role}."
  local wdg_brief="No Watchdog assigned (all Dashboard slots occupied)."
  [ -z "$wdg_slot" ] || wdg_brief="Watchdog is in Dashboard pane ${wdg_slot}."
  (
    sleep 8
    tmux send-keys -t "${session}:${window_index}.0" \
      "Team is online in window ${window_index}. ${grid_desc} — ${worker_count} workers. Your workers are in panes ${wp_list}. ${wdg_brief} Session: ${session}.${wt_brief}${_role_brief} All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &
  [ -n "$wdg_slot" ] || return 0
  (
    sleep 12
    tmux send-keys -t "${session}:${wdg_slot}" \
      "Start monitoring session ${session} window ${window_index}. ${grid_desc}. Skip pane ${wdg_slot} (yourself, in Dashboard). Manager is in team window pane ${window_index}.0. Monitor panes ${wp_list}." Enter
    sleep 20
    tmux send-keys -t "${session}:${wdg_slot}" \
      '/loop 30s "Run a scan cycle: bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/watchdog-scan.sh\" — then act on results. Read watchdog_pane_states.json from RUNTIME_DIR/status/ if your pane state tracking is empty."' Enter
  ) &
}

_build_worker_pane_list() {
  local session="$1" window_index="$2"
  _WPL_RESULT=""
  local _pi
  for _pi in $(tmux list-panes -t "${session}:${window_index}" -F '#{pane_index}'); do
    [ "$_pi" = "0" ] && continue
    [ -n "$_WPL_RESULT" ] && _WPL_RESULT="${_WPL_RESULT}, "
    _WPL_RESULT="${_WPL_RESULT}${window_index}.${_pi}"
  done
}

_acquire_watchdog_slot() {
  local session="$1" runtime_dir="$2" dir="$3" required="${4:-false}"
  _AWS_SLOT=""

  # mkdir-based lock to prevent parallel slot allocation races.
  # Lock acquisition and the critical section run inside a lockfile guard
  # with explicit cleanup — no EXIT trap needed (avoids overwriting the
  # caller's EXIT trap, which caused a CRITICAL bug).
  local _lock="${runtime_dir}/.watchdog_slot_lock"
  local _retries=0
  while ! mkdir "$_lock" 2>/dev/null; do
    _retries=$((_retries + 1))
    if [ "$_retries" -gt 40 ]; then
      rmdir "$_lock" 2>/dev/null
      break
    fi
    sleep 0.2
  done

  local _aws_rc=0
  if _find_free_watchdog_slot "$runtime_dir"; then
    _AWS_SLOT="$_FWS_SLOT"
  elif add_dashboard_watchdog_slot "$session" "$runtime_dir" "$dir"; then
    _AWS_SLOT="$WDG_NEW_SLOT"
  elif [ "$required" = "true" ]; then
    _aws_rc=1
  fi

  rmdir "$_lock" 2>/dev/null || true
  return "$_aws_rc"
}

_name_team_window() {
  local session="$1" window_index="$2" wt_dir="$3"
  local runtime_dir="${4:-}"
  _apply_team_border_theme "$session" "$window_index"
  tmux select-pane -t "${session}:${window_index}.0" -T "T${window_index} Window Manager"
  local label=""
  if [ -n "$runtime_dir" ] && [ -f "${runtime_dir}/team_${window_index}.env" ]; then
    label=$(_env_val "${runtime_dir}/team_${window_index}.env" TEAM_NAME)
  fi
  if [ -z "$label" ]; then
    label="Local Team"
    [ -z "$wt_dir" ] || label="Worktree Team"
  fi
  tmux rename-window -t "${session}:${window_index}" "$label"
}

_worktree_brief() {
  [ -n "$1" ] || return 0
  echo " ISOLATED WORKTREE: branch ${2}, dir ${1}. Workers operate on this isolated copy — changes do NOT affect the main repo until merged."
}

_print_team_created() {
  local window_index="$1" grid_desc="$2" worker_count="$3" wdg_slot="$4"
  local wt_dir="${5:-}" wt_branch="${6:-}"
  if [ -n "$wt_dir" ]; then
    printf "  ${SUCCESS}Team window %s created${RESET} — %s, %s workers, ${BOLD}worktree${RESET} (%s)\n" "$window_index" "$grid_desc" "$worker_count" "$wt_branch"
  else
    printf "  ${SUCCESS}Team window %s created${RESET} — %s, %s workers, watchdog in Dashboard slot %s\n" "$window_index" "$grid_desc" "$worker_count" "$wdg_slot"
  fi
}

add_dynamic_team_window() {
  local session="$1" runtime_dir="$2" dir="$3" initial_cols="${4:-$INITIAL_WORKER_COLS}"
  local worktree_spec="${5:-}"
  local team_name="${6:-}" team_role="${7:-}" worker_model="${8:-}" manager_model="${9:-}"
  local team_dir="$dir" worktree_branch="" wt_dir_for_env=""

  local window_index
  window_index=$(tmux new-window -t "$session" -c "$dir" -P -F '#{window_index}')

  if [ -n "$worktree_spec" ]; then
    local _wt_branch_arg=""
    [ "$worktree_spec" = "auto" ] || _wt_branch_arg="$worktree_spec"
    team_dir=$(create_team_worktree "$dir" "$window_index" "$_wt_branch_arg") || {
      printf "  ${WARN}Worktree creation failed for team %s — falling back to shared repo${RESET}\n" "$window_index"
      team_dir="$dir"; worktree_spec=""
    }
    if [ -n "$worktree_spec" ]; then
      worktree_branch=$(git -C "$team_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "doey/team-${window_index}")
      wt_dir_for_env="$team_dir"
    fi
  fi

  # Install hooks + skills in worktree dir (main project already has them from session launch)
  [ -n "$wt_dir_for_env" ] && [ -d "$wt_dir_for_env" ] && install_doey_hooks "$wt_dir_for_env" "  "

  printf "  ${DIM}Creating dynamic team window %s...${RESET}\n" "$window_index"
  _name_team_window "$session" "$window_index" "$wt_dir_for_env" "$runtime_dir"

  _acquire_watchdog_slot "$session" "$runtime_dir" "$team_dir" "false"
  local wdg_slot="$_AWS_SLOT"
  [ -n "$wdg_slot" ] || printf "  ${WARN}All %s Dashboard watchdog slots occupied — team %s has no Watchdog${RESET}\n" "$MAX_WATCHDOG_SLOTS" "$window_index"

  write_team_env "$runtime_dir" "$window_index" "dynamic" "${wdg_slot:-}" "" "0" "0" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$team_dir"
  _launch_team_manager "$session" "$runtime_dir" "$window_index"
  _launch_team_watchdog "$session" "$wdg_slot" "$window_index"

  local _col_i
  for (( _col_i=0; _col_i<initial_cols; _col_i++ )); do
    doey_add_column "$session" "$runtime_dir" "$team_dir" "$window_index"
    (( _col_i < initial_cols - 1 )) && sleep 0.3
  done

  _build_worker_pane_list "$session" "$window_index"
  local worker_count wt_brief
  worker_count=$(_env_val "${runtime_dir}/team_${window_index}.env" WORKER_COUNT)
  wt_brief=$(_worktree_brief "$wt_dir_for_env" "$worktree_branch")
  _brief_team "$session" "$window_index" "$wdg_slot" "$_WPL_RESULT" "$worker_count" "Dynamic grid, auto-expands when all are busy" "$wt_brief" "$team_name" "$team_role"
  _print_team_created "$window_index" "dynamic grid" "$worker_count" "$wdg_slot" "$wt_dir_for_env" "$worktree_branch"
}

add_team_window() {
  local session="$1" runtime_dir="$2" dir="$3" grid="${4:-4x2}"
  local worktree_spec="${5:-}"
  local team_name="${6:-}" team_role="${7:-}" worker_model="${8:-}" manager_model="${9:-}"
  local cols rows total_panes
  cols="${grid%x*}"; rows="${grid#*x}"; total_panes=$((cols * rows))

  if [ "$total_panes" -lt 3 ]; then
    printf "  ${ERROR}Grid %s too small — need at least 3 panes${RESET}\n" "$grid"
    return 1
  fi

  local window_index
  window_index=$(tmux new-window -t "$session" -c "$dir" -P -F '#{window_index}')

  local team_dir="$dir" worktree_branch="" wt_dir_for_env=""
  if [ -n "$worktree_spec" ]; then
    team_dir=$(create_team_worktree "$dir" "$window_index" "$worktree_spec") || {
      printf "  ${ERROR}Failed to create worktree for team %s${RESET}\n" "$window_index" >&2
      tmux kill-window -t "${session}:${window_index}" 2>/dev/null
      return 1
    }
    worktree_branch=$(git -C "$team_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$worktree_spec")
    wt_dir_for_env="$team_dir"
    install_doey_hooks "$team_dir" "  "
  fi

  printf "  ${DIM}Creating team window %s (%s grid, %s panes)...${RESET}\n" "$window_index" "$grid" "$total_panes"
  _name_team_window "$session" "$window_index" "$wt_dir_for_env" "$runtime_dir"

  local r c
  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "${session}:${window_index}.0" -c "$team_dir"
  done
  [ "$rows" -le 1 ] || tmux select-layout -t "${session}:${window_index}" even-vertical
  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "${session}:${window_index}.$((r * cols))" -c "$team_dir"
    done
  done
  sleep 0.3

  local actual
  actual=$(tmux list-panes -t "${session}:${window_index}" 2>/dev/null | wc -l | tr -d ' ')
  [ "$actual" -eq "$total_panes" ] || printf "  ${WARN}Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total_panes" "$actual"

  local worker_panes worker_count
  worker_panes=$(_build_worker_csv "$total_panes")
  worker_count=$((total_panes - 1))

  if ! _acquire_watchdog_slot "$session" "$runtime_dir" "$dir" "true"; then
    printf "  ${ERROR}All %s Dashboard watchdog slots occupied — cannot add more teams${RESET}\n" "$MAX_WATCHDOG_SLOTS"
    tmux kill-window -t "${session}:${window_index}" 2>/dev/null
    return 1
  fi
  local wdg_slot="$_AWS_SLOT"

  local i
  for (( i=1; i<total_panes; i++ )); do
    tmux select-pane -t "${session}:${window_index}.${i}" -T "T${window_index} W${i}"
  done

  write_team_env "$runtime_dir" "$window_index" "$grid" "$wdg_slot" "$worker_panes" "$worker_count" "0" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$team_dir"
  _launch_team_manager "$session" "$runtime_dir" "$window_index"
  _launch_team_watchdog "$session" "$wdg_slot" "$window_index"

  local _aw_pairs=()
  for (( i=1; i<total_panes; i++ )); do
    _aw_pairs+=("${i}:${i}")
  done
  _batch_boot_workers "$session" "$runtime_dir" "$window_index" "${_aw_pairs[@]}"

  _build_worker_pane_list "$session" "$window_index"
  _brief_team "$session" "$window_index" "$wdg_slot" "$_WPL_RESULT" "$worker_count" "Grid ${grid}" "" "$team_name" "$team_role"
  _print_team_created "$window_index" "grid ${grid}" "$worker_count" "$wdg_slot" "$wt_dir_for_env" "$worktree_branch"
}

kill_team_window() {
  local session="$1" runtime_dir="$2" window="$3"
  local team_env="${runtime_dir}/team_${window}.env"

  [ -f "$team_env" ] || { printf "  ${ERROR}No team env for window %s${RESET}\n" "$window"; return 1; }
  [ "$window" != "0" ] || { printf "  ${ERROR}Cannot kill window 0 — use 'doey stop'${RESET}\n"; return 1; }

  local watchdog_pane
  watchdog_pane=$(_env_val "$team_env" WATCHDOG_PANE)

  printf "  ${DIM}Killing team window %s...${RESET}\n" "$window"

  local pane_id pane_pid
  for pane_id in $(tmux list-panes -t "${session}:${window}" -F '#{pane_id}' 2>/dev/null); do
    pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null) || continue
    [ -n "$pane_pid" ] || continue
    pkill -P "$pane_pid" 2>/dev/null || true
    kill -- -"$pane_pid" 2>/dev/null || true
  done
  sleep 1
  tmux kill-window -t "${session}:${window}" 2>/dev/null || true

  if [ -n "$watchdog_pane" ]; then
    local _wdg_pid
    _wdg_pid=$(tmux display-message -t "${session}:${watchdog_pane}" -p '#{pane_pid}' 2>/dev/null) || true
    if [ -n "$_wdg_pid" ]; then
      pkill -P "$_wdg_pid" 2>/dev/null || true
      kill -- -"$_wdg_pid" 2>/dev/null || true
    fi
    sleep 0.5
    tmux kill-pane -t "${session}:${watchdog_pane}" 2>/dev/null || true

    # Rebuild WDG_SLOT entries (pane indices shift after kill)
    local _ktw_tmp="${runtime_dir}/session.env.tmp.$$"
    sed '/^WDG_SLOT_[0-9]*=/d' "${runtime_dir}/session.env" > "$_ktw_tmp"
    mv "$_ktw_tmp" "${runtime_dir}/session.env"

    local _new_idx=1 _pane_idx _pane_title
    while IFS=' ' read -r _pane_idx _pane_title; do
      [ "$_pane_idx" = "0" ] || [ "$_pane_idx" = "1" ] && continue
      local _new_wdg="0.${_pane_idx}"
      echo "WDG_SLOT_${_new_idx}=\"${_new_wdg}\"" >> "${runtime_dir}/session.env"
      _new_idx=$((_new_idx + 1))
      local _team_num
      _team_num=$(echo "$_pane_title" | sed -n 's/^T\([0-9]*\) Watchdog$/\1/p')
      if [ -n "$_team_num" ] && [ -f "${runtime_dir}/team_${_team_num}.env" ]; then
        local _te_tmp="${runtime_dir}/team_${_team_num}.env.tmp.$$"
        sed "s/^WATCHDOG_PANE=.*/WATCHDOG_PANE=\"${_new_wdg}\"/" "${runtime_dir}/team_${_team_num}.env" > "$_te_tmp"
        mv "$_te_tmp" "${runtime_dir}/team_${_team_num}.env"
      fi
    done < <(tmux list-panes -t "${session}:0" -F '#{pane_index} #{pane_title}' 2>/dev/null)
  fi

  local _wt_dir
  _wt_dir=$(_env_val "$team_env" WORKTREE_DIR)
  if [ -n "$_wt_dir" ]; then
    local _proj_dir
    _proj_dir=$(_env_val "${runtime_dir}/session.env" PROJECT_DIR)
    [ -z "$_proj_dir" ] || _worktree_safe_remove "$_proj_dir" "$_wt_dir"
  fi

  rm -f "$team_env"
  rm -f "$HOME/.claude/agents/t${window}-watchdog.md" "$HOME/.claude/agents/t${window}-manager.md" 2>/dev/null || true
  local safe_prefix="${session//[:.]/_}_${window}_"
  rm -f "${runtime_dir}/status/${safe_prefix}"* 2>/dev/null || true
  rm -f "${runtime_dir}/results/"*"_${window}_"* 2>/dev/null || true
  _unregister_team_window "$runtime_dir" "$window"

  printf "  ${SUCCESS}Team window %s killed and cleaned up${RESET}\n" "$window"
}

list_team_windows() {
  local session="$1" runtime_dir="$2"

  printf '\n  %sDoey — Team Windows%s\n\n' "$BRAND" "$RESET"

  local team_windows
  team_windows=$(read_team_windows "$runtime_dir")

  if [ "$team_windows" = "0" ] && [ ! -f "${runtime_dir}/team_0.env" ]; then
    printf "  ${DIM}(no team windows — single-window mode)${RESET}\n\n"
    return 0
  fi

  printf "  ${BOLD}%-8s %-8s %-10s %-8s %-20s${RESET}\n" "Window" "Grid" "Workers" "Status" "Team Env"
  printf "  ${DIM}%-8s %-8s %-10s %-8s %-20s${RESET}\n" "------" "----" "-------" "------" "--------"

  local _saved_ifs="$IFS" w
  IFS=','
  for w in $team_windows; do
    local team_env="${runtime_dir}/team_${w}.env"
    if [ -f "$team_env" ]; then
      local t_grid t_workers status="active"
      t_grid=$(_env_val "$team_env" GRID)
      t_workers=$(_env_val "$team_env" WORKER_COUNT)
      tmux list-panes -t "${session}:${w}" >/dev/null 2>&1 || status="dead"
      printf "  %-8s %-8s %-10s %-8s %-20s\n" "$w" "$t_grid" "$t_workers" "$status" "team_${w}.env"
    else
      printf "  %-8s ${DIM}(no env file)${RESET}\n" "$w"
    fi
  done
  IFS="$_saved_ifs"

  printf '\n'
}

# ── E2E Test Runner ───────────────────────────────────────────────────

run_test() {
  local keep=false open=false grid="3x2"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) keep=true; shift ;;
      --open) open=true; shift ;;
      --grid) grid="$2"; shift 2 ;;
      [0-9]*x[0-9]*) grid="$1"; shift ;;
      *) printf "  ${ERROR}Unknown test flag: %s${RESET}\n" "$1"; return 1 ;;
    esac
  done

  local test_id="e2e-test-$(date +%s)"
  local test_root="/tmp/doey-test/${test_id}"
  local project_dir="${test_root}/project"
  local report_file="${test_root}/report.md"
  local last8="${test_id: -8}"
  local test_project_name="e2e-test-${last8}"
  local session="doey-${test_project_name}"

  printf '\n  %sDoey — E2E Test%s\n\n' "$BRAND" "$RESET"
  printf "  ${DIM}Test ID${RESET}    ${BOLD}${test_id}${RESET}\n"
  printf "  ${DIM}Grid${RESET}       ${BOLD}${grid}${RESET}\n"
  printf "  ${DIM}Sandbox${RESET}    ${BOLD}${project_dir}${RESET}\n"
  printf "  ${DIM}Report${RESET}     ${BOLD}${report_file}${RESET}\n\n"

  printf "  ${DIM}[1/6]${RESET} Creating sandbox project...\n"
  mkdir -p "${project_dir}/.claude/hooks"
  cd "$project_dir"
  git init -q
  printf '# E2E Test Sandbox\n\nThis project was created by `doey test` for automated testing.\n' > README.md
  printf 'E2E Test Sandbox - build whatever is requested\n' > CLAUDE.md
  install_doey_hooks "$project_dir" "  "
  git add -A && git commit -q -m "Initial sandbox commit"
  printf "  ${SUCCESS}Sandbox created${RESET}\n"

  printf "  ${DIM}[2/6]${RESET} Registering sandbox...\n"
  echo "${test_project_name}:${project_dir}" >> "$PROJECTS_FILE"
  printf "  ${SUCCESS}Registered${RESET} ${BOLD}${test_project_name}${RESET}\n"

  printf "  ${DIM}[3/6]${RESET} Launching team...\n"
  launch_session_headless "$test_project_name" "$project_dir" "$grid"
  printf "  ${DIM}[4/6]${RESET} Waiting for boot (30s)...\n"
  sleep 30
  printf "  ${SUCCESS}Boot complete${RESET}\n"

  printf "  ${DIM}[5/6]${RESET} Launching test driver...\n"
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  local journey_file="${repo_dir}/tests/e2e/journey.md"
  if [[ ! -f "$journey_file" ]]; then
    printf "  ${ERROR}Journey file not found: %s${RESET}\n" "$journey_file"
    return 1
  fi
  mkdir -p "${test_root}/observations"
  printf "  ${DIM}Watch live:${RESET} tmux attach -t ${session}\n\n"

  claude --dangerously-skip-permissions --agent test-driver --model opus \
    "Run the E2E test. Session: ${session}. Project name: ${test_project_name}. Project dir: ${project_dir}. Runtime dir: /tmp/doey/${test_project_name}. Journey file: ${journey_file}. Observations dir: ${test_root}/observations. Report file: ${report_file}. Test ID: ${test_id}"

  printf '\n  %s[6/6]%s Results\n' "${DIM}" "${RESET}"
  if [[ -f "$report_file" ]]; then
    local result_color="$ERROR" result_text="TEST FAILED"
    grep -q "Result: PASS" "$report_file" 2>/dev/null && { result_color="$SUCCESS"; result_text="TEST PASSED"; }
    printf '\n  %s══════ %s ══════%s\n\n' "$result_color" "$result_text" "$RESET"
    printf "  ${DIM}Report:${RESET} ${BOLD}${report_file}${RESET}\n"
  else
    printf "  ${WARN}No report generated${RESET}\n"
  fi

  if [[ "$open" == true ]]; then open "${project_dir}/index.html" 2>/dev/null || true; fi

  if [[ "$keep" == false ]]; then
    printf "  ${DIM}Cleaning up...${RESET}\n"
    tmux kill-session -t "$session" 2>/dev/null || true
    grep -v "^${test_project_name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
    rm -rf "$test_root"
    printf "  ${SUCCESS}Cleaned up${RESET}\n"
  else
    printf '\n  %sKept for inspection:%s\n' "$BOLD" "$RESET"
    printf "    ${DIM}Session${RESET}   tmux attach -t ${session}\n"
    printf "    ${DIM}Sandbox${RESET}   ${project_dir}\n"
    printf "    ${DIM}Runtime${RESET}   /tmp/doey/${test_project_name}\n"
    printf "    ${DIM}Report${RESET}    ${report_file}\n\n"
  fi
}

# Sets: dir, name, session, runtime_dir
require_running_session() {
  dir="$(pwd)"
  name="$(find_project "$dir")"
  [[ -z "$name" ]] && { printf "  ${ERROR}No project registered for %s${RESET}\n" "$dir"; exit 1; }
  session="doey-${name}"
  session_exists "$session" || { printf "  ${ERROR}Session %s not running${RESET}\n" "$session"; exit 1; }
  runtime_dir="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
}

# ── Config Management ────────────────────────────────────────────────
doey_config() {
  local global_dir="${HOME}/.config/doey"
  local global_config="${DOEY_CONFIG:-${global_dir}/config.sh}"
  local template="${SCRIPT_DIR}/doey-config-default.sh"

  # Find project config by walking up from cwd
  local project_config="" search_dir
  search_dir="$(pwd)"
  while [ "$search_dir" != "/" ]; do
    if [ -f "${search_dir}/.doey/config.sh" ]; then
      project_config="${search_dir}/.doey/config.sh"
      break
    fi
    search_dir="$(dirname "$search_dir")"
  done

  case "${1:-}" in
    --show)
      printf "  ${BRAND}Doey Configuration${RESET}\n\n"
      printf "  ${DIM}Global:${RESET}  %s" "$global_config"
      [ -f "$global_config" ] && printf " ${SUCCESS}(loaded)${RESET}\n" || printf " ${DIM}(not found)${RESET}\n"
      printf "  ${DIM}Project:${RESET} "
      if [ -n "$project_config" ]; then
        printf "%s ${SUCCESS}(loaded — overrides global)${RESET}\n" "$project_config"
      else
        printf "${DIM}(no .doey/config.sh found)${RESET}\n"
      fi
      printf "\n  ${BOLD}Current values:${RESET}\n"
      printf "    DOEY_INITIAL_WORKER_COLS  = %s\n" "${DOEY_INITIAL_WORKER_COLS}"
      printf "    DOEY_INITIAL_TEAMS        = %s\n" "${DOEY_INITIAL_TEAMS}"
      printf "    DOEY_INITIAL_WORKTREE_TEAMS = %s\n" "${DOEY_INITIAL_WORKTREE_TEAMS}"
      printf "    DOEY_MAX_WORKERS          = %s\n" "${DOEY_MAX_WORKERS}"
      printf "    DOEY_MANAGER_MODEL        = %s\n" "${DOEY_MANAGER_MODEL}"
      printf "    DOEY_WORKER_MODEL         = %s\n" "${DOEY_WORKER_MODEL}"
      printf "    DOEY_WATCHDOG_MODEL       = %s\n" "${DOEY_WATCHDOG_MODEL}"
      printf "    DOEY_WORKER_LAUNCH_DELAY  = %s\n" "${DOEY_WORKER_LAUNCH_DELAY}"
      printf "    DOEY_TEAM_LAUNCH_DELAY    = %s\n" "${DOEY_TEAM_LAUNCH_DELAY}"
      printf "\n"
      ;;
    --global)
      mkdir -p "$global_dir"
      if [ ! -f "$global_config" ] && [ -f "$template" ]; then
        cp "$template" "$global_config"
        printf "  ${SUCCESS}Created${RESET} %s from template\n" "$global_config"
      fi
      "${EDITOR:-vim}" "$global_config"
      ;;
    --reset)
      if [ ! -f "$template" ]; then
        printf "  ${ERROR}Template not found: %s${RESET}\n" "$template"
        return 1
      fi
      if [ -n "$project_config" ]; then
        cp "$template" "$project_config"
        printf "  ${SUCCESS}Reset${RESET} %s to defaults\n" "$project_config"
      else
        mkdir -p "$global_dir"
        cp "$template" "$global_config"
        printf "  ${SUCCESS}Reset${RESET} %s to defaults\n" "$global_config"
      fi
      ;;
    *)
      # Default: edit project config if available, else global
      if [ -n "$project_config" ]; then
        "${EDITOR:-vim}" "$project_config"
      else
        mkdir -p "$global_dir"
        if [ ! -f "$global_config" ] && [ -f "$template" ]; then
          cp "$template" "$global_config"
          printf "  ${SUCCESS}Created${RESET} %s from template\n" "$global_config"
        fi
        "${EDITOR:-vim}" "$global_config"
      fi
      ;;
  esac
}

# ── Settings Window ───────────────────────────────────────────────────

doey_settings() {
  require_running_session
  local project_dir
  project_dir=$(grep '^PROJECT_DIR=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
  [[ -z "$project_dir" ]] && { printf "  ${ERROR}Could not determine PROJECT_DIR from %s${RESET}\n" "${runtime_dir}/session.env"; exit 1; }

  # Check if Settings window already exists
  local settings_win
  settings_win=$(tmux list-windows -t "$session" -F '#{window_index} #{window_name}' 2>/dev/null | grep ' Settings$' | head -1 | awk '{print $1}')
  if [ -n "$settings_win" ]; then
    tmux select-window -t "$session:$settings_win"
    attach_or_switch "$session"
    return 0
  fi

  # Create new window named "Settings"
  tmux new-window -t "$session" -n "Settings"
  settings_win=$(tmux display-message -t "$session" -p '#{window_index}')

  # Split into left (editor) and right (panel) — 50/50 vertical split
  tmux split-window -h -t "$session:$settings_win"

  # Right pane (pane 1): run settings panel with live refresh
  tmux send-keys -t "$session:${settings_win}.1" "DOEY_SETTINGS_LIVE=1 bash \"${project_dir}/shell/settings-panel.sh\"" Enter

  # Left pane (pane 0): launch Claude with settings-editor agent
  tmux send-keys -t "$session:${settings_win}.0" "claude --agent settings-editor" Enter

  # Focus the left pane (editor)
  tmux select-pane -t "$session:${settings_win}.0"
  attach_or_switch "$session"
}

# ── Main Dispatch ─────────────────────────────────────────────────────

_attach_session() {
  local session="$1"
  printf "  ${SUCCESS}Attaching to${RESET} ${BOLD}%s${RESET}...\n" "$session"
  tmux select-window -t "$session:0"
  attach_or_switch "$session"
}

# Allow sourcing for tests: `source doey.sh __doey_source_only` loads functions only
[[ "${1:-}" == "__doey_source_only" ]] && return 0 2>/dev/null || true
[[ "${1:-}" == "__doey_source_only" ]] && exit 0

# ── Prerequisite gate ─────────────────────────────────────────────────
# Catch missing tmux/claude early with helpful install guidance.
# Runs before any command except --help, doctor, version, uninstall.
_check_prereqs() {
  local missing=false

  if ! command -v tmux >/dev/null 2>&1; then
    missing=true
    echo ""
    printf "  ${ERROR}✗ tmux is not installed${RESET}\n"
    printf "  ${DIM}Doey needs tmux to run parallel Claude Code agents.${RESET}\n\n"
    case "$(uname -s)" in
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          printf "  ${BOLD}Install now:${RESET}\n"
          printf "    ${BRAND}brew install tmux${RESET}\n\n"
          if [ -t 0 ]; then
            printf "  Run this command? ${DIM}[Y/n]${RESET} "
            read -r reply
            case "$reply" in
              [Nn]*) ;;
              *)
                printf "\n  ${DIM}Installing tmux...${RESET}\n"
                if brew install tmux; then
                  printf "  ${SUCCESS}✓ tmux installed${RESET}\n\n"
                  missing=false
                else
                  printf "  ${ERROR}✗ Install failed${RESET} — try manually: brew install tmux\n\n"
                fi
                ;;
            esac
          fi
        else
          printf "  ${BOLD}Option 1 — Install Homebrew first (recommended):${RESET}\n"
          printf "    ${BRAND}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${RESET}\n"
          printf "    ${BRAND}brew install tmux${RESET}\n\n"
          printf "  ${BOLD}Option 2 — MacPorts:${RESET}\n"
          printf "    ${BRAND}sudo port install tmux${RESET}\n\n"
        fi
        ;;
      Linux)
        printf "  ${BOLD}Install now:${RESET}\n"
        if command -v apt-get >/dev/null 2>&1; then
          printf "    ${BRAND}sudo apt-get install -y tmux${RESET}\n\n"
          if [ -t 0 ]; then
            printf "  Run this command? ${DIM}[Y/n]${RESET} "
            read -r reply
            case "$reply" in
              [Nn]*) ;;
              *)
                printf "\n  ${DIM}Installing tmux...${RESET}\n"
                if sudo apt-get update -qq && sudo apt-get install -y tmux; then
                  printf "  ${SUCCESS}✓ tmux installed${RESET}\n\n"
                  missing=false
                else
                  printf "  ${ERROR}✗ Install failed${RESET}\n\n"
                fi
                ;;
            esac
          fi
        elif command -v dnf >/dev/null 2>&1; then
          printf "    ${BRAND}sudo dnf install -y tmux${RESET}\n\n"
        elif command -v pacman >/dev/null 2>&1; then
          printf "    ${BRAND}sudo pacman -S tmux${RESET}\n\n"
        else
          printf "    ${BRAND}sudo apt-get install tmux${RESET}  ${DIM}(Debian/Ubuntu)${RESET}\n"
          printf "    ${BRAND}sudo dnf install tmux${RESET}      ${DIM}(Fedora/RHEL)${RESET}\n"
          printf "    ${BRAND}sudo pacman -S tmux${RESET}        ${DIM}(Arch)${RESET}\n\n"
        fi
        ;;
      *)
        printf "  ${DIM}Install tmux for your platform: https://github.com/tmux/tmux/wiki/Installing${RESET}\n\n"
        ;;
    esac
  fi

  if ! command -v claude >/dev/null 2>&1; then
    missing=true
    printf "  ${ERROR}✗ Claude Code CLI is not installed${RESET}\n"
    printf "  ${DIM}Doey orchestrates Claude Code instances — the CLI is required.${RESET}\n\n"
    if command -v node >/dev/null 2>&1; then
      printf "  ${BOLD}Install now:${RESET}\n"
      printf "    ${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n\n"
      if [ -t 0 ]; then
        printf "  Run this command? ${DIM}[Y/n]${RESET} "
        read -r reply
        case "$reply" in
          [Nn]*) ;;
          *)
            printf "\n  ${DIM}Installing Claude Code...${RESET}\n"
            if npm install -g @anthropic-ai/claude-code; then
              printf "  ${SUCCESS}✓ Claude Code installed${RESET}\n"
              printf "  ${DIM}Run ${RESET}${BOLD}claude${RESET}${DIM} once to authenticate, then re-run ${RESET}${BOLD}doey${RESET}\n\n"
              missing=false
            else
              printf "  ${ERROR}✗ Install failed${RESET} — try: sudo npm install -g @anthropic-ai/claude-code\n\n"
            fi
            ;;
        esac
      fi
    else
      printf "  ${BOLD}Step 1 — Install Node.js 18+:${RESET}\n"
      case "$(uname -s)" in
        Darwin)
          if command -v brew >/dev/null 2>&1; then
            printf "    ${BRAND}brew install node${RESET}\n"
          else
            printf "    ${BRAND}https://nodejs.org${RESET}  ${DIM}(or: brew install node)${RESET}\n"
          fi
          ;;
        *) printf "    ${BRAND}https://nodejs.org${RESET}  ${DIM}(or: curl -fsSL https://fnm.vercel.app/install | bash && fnm install 22)${RESET}\n" ;;
      esac
      printf "\n  ${BOLD}Step 2 — Install Claude Code:${RESET}\n"
      printf "    ${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n\n"
      printf "  ${BOLD}Step 3 — Authenticate:${RESET}\n"
      printf "    ${BRAND}claude${RESET}  ${DIM}(follow the prompts)${RESET}\n\n"
    fi
  fi

  if [ "$missing" = true ]; then
    printf "  ${DIM}After installing, re-run: ${RESET}${BOLD}doey${RESET}\n"
    exit 1
  fi
}

grid="dynamic"

case "${1:-}" in
  --help|-h)
    printf '\n  %sDoey%s\n\n' "$BRAND" "$RESET"
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
    settings   Open interactive settings editor window
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
    doey config       # edit config (project if .doey/ exists, else global)
    doey config --show   # show current config values
    doey config --global # edit global config
    doey config --reset  # reset config to defaults
    doey add-team 3x2 # add a team window (3x2 grid)
    doey kill-team 1  # kill team window 1
    doey list-teams   # show all team windows
HELP
    printf '\n'
    exit 0
    ;;
  # Commands that don't need tmux/claude running:
  list)         list_projects; exit 0 ;;
  doctor)       check_doctor; exit 0 ;;
  version|--version|-v) show_version; exit 0 ;;
  uninstall)    uninstall_system; exit 0 ;;
  update|reinstall) update_system; exit 0 ;;
  config)       shift; doey_config "$@"; exit 0 ;;
  # Everything below requires tmux + claude — check prerequisites:
  init)
    _check_prereqs
    register_project "$(pwd)"
    dir="$(pwd)"; name="$(find_project "$dir")"
    [[ -n "$name" ]] && launch_with_grid "$name" "$dir" "$grid"
    exit 0
    ;;
  purge)        shift; doey_purge "$@"; exit $? ;;
  stop)         stop_project; exit $? ;;
  reload)       shift; reload_session "$@"; exit 0 ;;
  test)         shift; run_test "$@"; exit $? ;;
  settings)     doey_settings; exit 0 ;;
  dynamic|d)
    _check_prereqs
    register_project "$(pwd)"
    dir="$(pwd)"; name="$(find_project "$dir")"
    if [[ -n "$name" ]]; then
      session="doey-${name}"
      if session_exists "$session"; then
        _attach_session "$session"
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
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
      require_running_session
      doey_remove_column "$session" "$runtime_dir" "$2"
    elif [ -z "${2:-}" ]; then
      dir="$(pwd)"; name="$(find_project "$dir")"
      if [[ -n "$name" ]] && session_exists "doey-${name}"; then
        session="doey-${name}"
        runtime_dir="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
        safe_source_session_env "${runtime_dir}/session.env"
        if [[ "${GRID:-}" == "dynamic" ]]; then
          doey_remove_column "$session" "$runtime_dir"
          exit 0
        fi
      fi
      remove_project ""
    else
      remove_project "${2:-}"
    fi
    exit 0
    ;;
  add-window|add-team)
    require_running_session
    wt_spec="" grid_arg="4x2"
    shift
    for _arg in "$@"; do
      case "$_arg" in
        --worktree) wt_spec="auto" ;;
        *x*) grid_arg="$_arg" ;;
      esac
    done
    if [ -n "$wt_spec" ]; then
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$INITIAL_WORKER_COLS" "$wt_spec"
    else
      add_team_window "$session" "$runtime_dir" "$dir" "$grid_arg"
    fi
    exit 0
    ;;
  kill-window|kill-team)
    [ -n "${2:-}" ] || { printf "  ${ERROR}Usage: doey kill-team <window-index>${RESET}\n"; exit 1; }
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
    _check_prereqs
    grid="$1"
    ;;
  "") ;;
  *)
    printf "  ${ERROR}Unknown command: %s${RESET}\n" "$1"
    printf "  Run ${BOLD}doey --help${RESET} for usage\n"
    exit 1
    ;;
esac

# ── Smart Launch ──────────────────────────────────────────────────────

_check_prereqs
check_for_updates

dir="$(pwd)"
name="$(find_project "$dir")"

if [[ -n "$name" ]]; then
  session="doey-${name}"
  if session_exists "$session"; then
    _attach_session "$session"
  else
    launch_with_grid "$name" "$dir" "$grid"
  fi
else
  show_menu "${grid}"
fi
