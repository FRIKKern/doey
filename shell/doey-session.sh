#!/usr/bin/env bash
# doey-session.sh — Session launch and lifecycle functions for Doey.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_session_sourced:-}" = "1" ] && return 0
__doey_session_sourced=1

# shellcheck source=doey-helpers.sh
SESSION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SESSION_SCRIPT_DIR}/doey-helpers.sh"
source "${SESSION_SCRIPT_DIR}/doey-ui.sh"
source "${SESSION_SCRIPT_DIR}/doey-roles.sh"
source "${SESSION_SCRIPT_DIR}/doey-send.sh"
source "${SESSION_SCRIPT_DIR}/doey-grid.sh"
source "${SESSION_SCRIPT_DIR}/doey-team-mgmt.sh"
[ -f "${SESSION_SCRIPT_DIR}/doey-mcp.sh" ] && source "${SESSION_SCRIPT_DIR}/doey-mcp.sh"

# project_name_from_dir, project_acronym, find_project → doey-helpers.sh

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
  local safe="${pane_id//[-:.]/_}"
  local target="${rt_dir}/status/${safe}.status"
  local tmp="${target}.tmp.$$"
  cat > "$tmp" <<EOF
PANE: ${pane_id}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: ${status}
TASK: ${task}
EOF
  mv -f "$tmp" "$target"
}

# Detect project language/type from marker files and write to session.env
_detect_project_type() {
  local dir="$1"
  local lang="unknown" build_cmd="" test_cmd="" lint_cmd=""

  if [ -f "$dir/go.mod" ]; then
    lang="Go"; build_cmd="go build ./..."; test_cmd="go test ./..."; lint_cmd="golangci-lint run"
  elif [ -f "$dir/package.json" ]; then
    lang="Node"; build_cmd="npm run build"; test_cmd="npm test"; lint_cmd="npm run lint"
  elif [ -f "$dir/Cargo.toml" ]; then
    lang="Rust"; build_cmd="cargo build"; test_cmd="cargo test"; lint_cmd="cargo clippy"
  elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
    lang="Python"; build_cmd="python -m build"; test_cmd="pytest"; lint_cmd="ruff check ."
  elif [ -f "$dir/Gemfile" ]; then
    lang="Ruby"; build_cmd=""; test_cmd="bundle exec rspec"; lint_cmd="bundle exec rubocop"
  elif [ -f "$dir/Makefile" ]; then
    lang="Make"; build_cmd="make"; test_cmd="make test"; lint_cmd="make lint"
  fi

  # Export for current shell
  PROJECT_LANGUAGE="$lang"
  BUILD_CMD="$build_cmd"
  TEST_CMD="$test_cmd"
  LINT_CMD="$lint_cmd"

  printf '%b Detected: %s project\n' "$BRAND" "$lang"
}

# Write project type fields to session.env (call after session.env exists)
_write_project_type_env() {
  local runtime_dir="$1"
  [ -f "${runtime_dir}/session.env" ] || return 0
  printf 'PROJECT_LANGUAGE="%s"\nBUILD_CMD="%s"\nTEST_CMD="%s"\nLINT_CMD="%s"\n' \
    "${PROJECT_LANGUAGE:-unknown}" "${BUILD_CMD:-}" "${TEST_CMD:-}" "${LINT_CMD:-}" \
    >> "${runtime_dir}/session.env"
}

# session_exists, read_team_windows → doey-helpers.sh

# ── Team env, agent, def, worktree functions moved to doey-team-mgmt.sh ──
# Dashboard layout: Info Panel (left) | Boss (right)
# Taskmaster launches in Core Team window (see Phase 3)
# Sets: BOSS_PANE
setup_dashboard() {
  local session="$1" dir="$2" runtime_dir="$3"

  # Start: single pane 0.0 (will become Info Panel)
  # Split left/right — right column gets 60%
  tmux split-window -h -t "$session:0.0" -l 150 -c "$dir"
  # Indices: 0.0=info(left), 0.1=Boss

  local _proj="${session#doey-}"
  tmux select-pane -t "$session:0.0" -T "" \; \
       select-pane -t "$session:0.1" -T "${_proj} ${DOEY_ROLE_BOSS}"
  BOSS_PANE="0.1"

  # Go helpers (build pipeline + advisory check)
  if [ -f "${SCRIPT_DIR}/doey-go-helpers.sh" ]; then
    source "${SCRIPT_DIR}/doey-go-helpers.sh"
  elif [ -f "${SCRIPT_DIR}/doey-go-check.sh" ]; then
    source "${SCRIPT_DIR}/doey-go-check.sh"
  fi
  if type is_doey_repo >/dev/null 2>&1 && is_doey_repo "${SCRIPT_DIR}/.."; then
    type check_go_install >/dev/null 2>&1 && check_go_install "${SCRIPT_DIR}/.."
  fi

  # Info Panel
  if command -v doey-tui >/dev/null 2>&1; then
    doey_send_command "$session:0.0" "clear && doey-tui '${runtime_dir}'"
  else
    doey_send_command "$session:0.0" "clear && info-panel.sh '${runtime_dir}'"
  fi

  # Boss (pane 0.1)
  local _boss_cmd="claude --dangerously-skip-permissions --model ${DOEY_BOSS_MODEL:-$DOEY_TASKMASTER_MODEL} --name \"${DOEY_ROLE_BOSS}\" --agent ${DOEY_ROLE_FILE_BOSS}"
  _append_settings _boss_cmd "$runtime_dir"
  doey_send_command "$session:0.1" "${_DRAIN_STDIN}${_boss_cmd}"

  tmux rename-window -t "$session:0" "Dashboard"
  write_pane_status "$runtime_dir" "${session}:0.1" "READY"
}

# Create Core Team window (window 1): Taskmaster + specialists
# Panes: 1.0=Taskmaster, 1.1=Task Reviewer, 1.2=Deployment, 1.3=Terminal
_create_core_team() {
  local session="$1" runtime_dir="$2" dir="$3"

  # Create window 1
  tmux new-window -t "$session" -c "$dir"
  tmux rename-window -t "$session:1" "Core Team"

  # Split into 4 panes (2x2 grid)
  # Start with 1.0
  tmux split-window -v -t "$session:1.0" -c "$dir"   # 1.0=top, 1.1=bottom
  tmux split-window -h -t "$session:1.0" -c "$dir"   # 1.0=top-left, 1.1=top-right, 1.2=bottom
  tmux split-window -h -t "$session:1.2" -c "$dir"   # 1.2=bottom-left(old bottom), 1.3=bottom-right

  # Name panes
  local _proj="${session#doey-}"
  tmux select-pane -t "$session:1.0" -T "${_proj} ${DOEY_ROLE_COORDINATOR}" \;\
       select-pane -t "$session:1.1" -T "Task Reviewer" \;\
       select-pane -t "$session:1.2" -T "Deployment" \;\
       select-pane -t "$session:1.3" -T "Terminal"

  # Apply border theme (same as regular teams)
  _apply_team_border_theme "$session" "1"

  # Write Core Team env
  write_team_env "$runtime_dir" "1" "2x2" "1,2" "2" "0" "" "" \
                 "Core Team" "core" "" ""

  # Set TASKMASTER_PANE in session.env
  _set_session_env "$runtime_dir" "TASKMASTER_PANE" "1.0"

  # Launch Taskmaster in pane 1.0 via shared helper
  _launch_team_manager "$session" "$runtime_dir" "1" \
    "$DOEY_TASKMASTER_MODEL" "$DOEY_ROLE_FILE_COORDINATOR" \
    "$DOEY_ROLE_COORDINATOR" "${_proj} ${DOEY_ROLE_COORDINATOR}"

  # Brief Taskmaster about its Core Team window
  _brief_team "$session" "1" "1.1, 1.2" "2" "2x2 grid" "" "Core Team" "core"

  # Launch specialist agents in panes 1.1-1.2
  local _spec_cmd

  # Task Reviewer (pane 1.1)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Task Reviewer\" --agent doey-task-reviewer"
  _append_settings _spec_cmd "$runtime_dir"
  doey_send_command "${session}:1.1" "${_DRAIN_STDIN}${_spec_cmd}"
  write_pane_status "$runtime_dir" "${session}:1.1" "READY"

  # Deployment (pane 1.2)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Deployment\" --agent doey-deployment"
  _append_settings _spec_cmd "$runtime_dir"
  doey_send_command "${session}:1.2" "${_DRAIN_STDIN}${_spec_cmd}"
  write_pane_status "$runtime_dir" "${session}:1.2" "READY"

  # Terminal (pane 1.3) — doey-term Bubble Tea container, not a Claude agent
  doey_send_command "${session}:1.3" "${_DRAIN_STDIN}doey-term"
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
    doey_ok "Already registered as '$(find_project "$dir")'"
    return 0
  fi

  # Handle name collision
  if grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null; then
    local i=2
    while grep -q "^${name}-${i}:" "$PROJECTS_FILE" 2>/dev/null; do i=$((i + 1)); done
    name="${name}-${i}"
  fi

  echo "${name}:${dir}" >> "$PROJECTS_FILE"
  doey_ok "Registered ${name} → ${dir}"

  # Create .doey/ project config directory with template
  if [ ! -d "${dir}/.doey" ]; then
    mkdir -p "${dir}/.doey"
    local template="${SCRIPT_DIR}/doey-config-default.sh"
    if [ -f "$template" ]; then
      cp "$template" "${dir}/.doey/config.sh"
    fi
    doey_ok "Created .doey/config.sh"
  fi
}

# List all projects with running status
# Stop session for current directory's project
stop_project() {
  # 1) If inside a doey tmux session, stop it directly
  if [[ -n "${TMUX:-}" ]]; then
    local current_session
    current_session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [[ "$current_session" == doey-* ]]; then
      doey_info "Stopping doey session: ${current_session}..."
      _kill_doey_session "$current_session"
      doey_ok "Stopped $current_session"
      return 0
    fi
  fi

  # 2) If pwd matches a registered project, stop that
  local name
  name="$(find_project "$(pwd)")"
  if [[ -n "$name" ]]; then
    local session="doey-${name}"
    if session_exists "$session"; then
      doey_info "Stopping doey session: ${session}..."
      _kill_doey_session "$session"
      doey_ok "Stopped $session"
    else
      doey_info "No active session for $name"
    fi
    return 0
  fi

  # 3) Otherwise, find all running doey sessions and show picker
  local running_sessions; running_sessions=()
  while IFS= read -r sess; do
    [[ "$sess" == doey-* ]] && running_sessions+=("$sess")
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)

  if [[ ${#running_sessions[@]} -eq 0 ]]; then
    doey_info "No running Doey sessions found."
    return 0
  fi

  if [[ ${#running_sessions[@]} -eq 1 ]]; then
    printf '\n'
    if doey_confirm "Stop ${running_sessions[0]}?"; then
      _kill_doey_session "${running_sessions[0]}"
      doey_success "Stopped ${running_sessions[0]}"
    else
      doey_info "Cancelled"
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
        doey_ok "Stopped ${sess}"
      done
      ;;
    [0-9]*)
      local idx=$((choice - 1))
      if [[ $idx -ge 0 && $idx -lt ${#running_sessions[@]} ]]; then
        _kill_doey_session "${running_sessions[$idx]}"
        doey_ok "Stopped ${running_sessions[$idx]}"
      else
        doey_error "Invalid selection"
        return 1
      fi
      ;;
    *)
      doey_info "Cancelled"
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
  sleep 0.3
  # Kill the tmux session
  tmux kill-session -t "$session" < /dev/null 2>/dev/null || true
  # Clean up worktrees + runtime dir
  local project_name="${session#doey-}"
  local _rt="${TMPDIR:-/tmp}/doey/${project_name}"
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
  # Stop doey-router
  if [ -f "$_rt/doey-router.pid" ]; then
    kill "$(cat "$_rt/doey-router.pid")" 2>/dev/null || true
    rm -f "$_rt/doey-router.pid"
  fi
  # Stop doey-daemon
  if [ -f "$_rt/doey-daemon.pid" ]; then
    kill "$(cat "$_rt/doey-daemon.pid")" 2>/dev/null || true
    rm -f "$_rt/doey-daemon.pid"
  fi
  # Clean up all MCP servers and configs
  doey_mcp_cleanup_session "$_rt" || true
  rm -rf "$_rt" 2>/dev/null || true
}

# Show interactive project picker menu
# ── Step printer helpers ──────────────────────────────────────────────
STEP_TOTAL=6

step_start() {
  local n="$1"; local label="$2"
  if [ "$HAS_GUM" = true ]; then
    printf "   $(gum style --foreground 240 "[${n}/${STEP_TOTAL}]") %-40s" "$label"
  else
    printf "   ${DIM}[${n}/${STEP_TOTAL}]${RESET} %-40s" "$label"
  fi
}

step_done() {
  if [ "$HAS_GUM" = true ]; then
    printf '%s\n' "$(gum style --foreground 2 '✓')"
  else
    printf "${SUCCESS}done${RESET}\n"
  fi
}

# Print step header — uses step_start in interactive mode, dim printf in headless.
# Usage: _step_msg <n> <label> <headless>
_step_msg() {
  if [[ "$3" -eq 0 ]]; then step_start "$1" "$2"
  else printf "  ${DIM}%s${RESET}\n" "$2"; fi
}

# Parse claude auth status into _AUTH_OK, _AUTH_METHOD, _AUTH_EMAIL, _AUTH_SUB.
# Parse claude auth status. Prints "ok|method|email|sub" on success, "fail" on failure.
_parse_auth_status() {
  local _auth_json
  _auth_json=$(claude auth status 2>&1) || _auth_json=""
  if echo "$_auth_json" | grep -q '"loggedIn": true'; then
    local _method _email _sub
    _method=$(echo "$_auth_json" | grep '"authMethod"' | sed 's/.*: *"//;s/".*//')
    _email=$(echo "$_auth_json" | grep '"email"' | sed 's/.*: *"//;s/".*//')
    _sub=$(echo "$_auth_json" | grep '"subscriptionType"' | sed 's/.*: *"//;s/".*//')
    echo "ok|${_method}|${_email}|${_sub}"
  else
    echo "fail"
    return 1
  fi
}

# ── Shared launch helpers ────────────────────────────────────────────

# Write the shared worker system prompt to <runtime_dir>/worker-system-prompt.md
# Usage: write_worker_system_prompt <runtime_dir> <name> <dir>
write_worker_system_prompt() {
  local runtime_dir="$1" name="$2" dir="$3"
  cat > "${runtime_dir}/worker-system-prompt.md" << 'WORKER_PROMPT'
# Doey Worker

You are a **Worker** on the Doey team, coordinated by a Subtaskmaster in pane 0 of your team window. You receive tasks via this chat and execute them independently.

## Rules
1. **Absolute paths only** — Always use absolute file paths. Never use relative paths.
2. **Stay in scope** — Only make changes within the scope of your assigned task. Do not refactor, clean up, or "improve" code outside your task.
3. **Concurrent awareness** — Other workers are editing other files in this codebase simultaneously. Avoid broad sweeping changes (global renames, config modifications, formatter runs) unless your task explicitly requires it.
4. **When done, stop** — Complete your task and stop. Do not ask follow-up questions unless you are genuinely blocked. The Subtaskmaster will check your output.
5. **If blocked, describe and stop** — If you encounter an unrecoverable error, describe it clearly and stop.
6. **No git commits** — Do not create git commits unless your task explicitly says to. The Subtaskmaster coordinates commits.
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

# Append --settings flag to a command variable if doey-settings.json exists.
# Usage: _append_settings <var_name> <runtime_dir>
_append_settings() {
  [ -f "${2}/doey-settings.json" ] && eval "${1}+=' --settings \"${2}/doey-settings.json\"'"
}

# Run command with gum spinner if available, plain otherwise. Returns exit code.
# Usage: if ! _spin "title" command args...; then handle_error; fi
_spin() {
  local title="$1"; shift
  if [ "$HAS_GUM" = true ]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

# ── Version/update helpers moved to doey-update.sh ──

# ── Purge functions moved to doey-purge.sh ──

check_claude_auth() {
  if ! command -v claude >/dev/null 2>&1; then
    doey_error "claude CLI not found"
    return 1
  fi
  local _auth_result
  if _auth_result=$(_parse_auth_status); then
    local _auth_method _auth_email _auth_sub
    local _old_ifs="$IFS"; IFS='|'
    set -- $_auth_result; IFS="$_old_ifs"
    # $1=ok, $2=method, $3=email, $4=sub
    _auth_method="${2:-}" _auth_email="${3:-}" _auth_sub="${4:-}"
    doey_success "Authenticated (${_auth_method} · ${_auth_email} · ${_auth_sub})"
    return 0
  else
    printf '\n'
    doey_error "Not logged in"
    doey_info "All Claude instances share one auth session."
    doey_info "Run claude and authenticate, then retry."
    printf '\n'
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
  local runtime_dir="${TMPDIR:-/tmp}/doey/${name}"
  local team_window=2

  cd "$dir"
  _doey_reload_config

  local hook_indent="   "
  [[ "$headless" -eq 1 ]] && hook_indent="  "
  install_doey_hooks "$dir" "$hook_indent"

  local worker_panes_csv
  worker_panes_csv="$(_build_worker_csv "$total")"

  # -- Session creation --
  _step_msg 1 "Creating session for ${name}..." "$headless"

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
WORKER_PANES="$worker_panes_csv"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="${DOEY_PASTE_SETTLE_MS:-800}"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
TEAM_WINDOWS="2"
BOSS_PANE="0.1"
TASKMASTER_PANE="1.0"
REMOTE="$(_detect_remote)"
MANIFEST

  _detect_project_type "$dir"
  _write_project_type_env "$runtime_dir"
  _maybe_start_tunnel "$runtime_dir" "$(_detect_remote)"

  # Launch doey-router daemon
  if [ "${DOEY_ROUTER_ENABLED:-true}" != "false" ]; then
    _router_bin=""
    if command -v doey-router >/dev/null 2>&1; then
      _router_bin="doey-router"
    elif [ -x "${HOME}/.local/bin/doey-router" ]; then
      _router_bin="${HOME}/.local/bin/doey-router"
    fi
    if [ -n "$_router_bin" ]; then
      mkdir -p "${runtime_dir}/logs"
      "$_router_bin" --runtime "$runtime_dir" --project-dir "$dir" -log-file "${runtime_dir}/logs/doey-router.log" >/dev/null 2>&1 &
      echo $! > "$runtime_dir/doey-router.pid"
    fi
  fi

  # Launch doey-daemon (observability)
  local _daemon_bin
  _daemon_bin=$(command -v doey-daemon 2>/dev/null || echo "${HOME}/.local/bin/doey-daemon")
  if [ -x "$_daemon_bin" ]; then
    mkdir -p "${runtime_dir}/daemon"
    "$_daemon_bin" --runtime "$runtime_dir" --project-dir "$dir" \
      --log-file "${runtime_dir}/logs/doey-daemon.log" \
      --stats-file "${runtime_dir}/daemon/stats.json" >/dev/null 2>&1 &
    echo $! > "${runtime_dir}/doey-daemon.pid"
  fi

  write_team_env "$runtime_dir" "$team_window" "$grid" "$worker_panes_csv" "$worker_count" "0" "" ""

  setup_dashboard "$session" "$dir" "$runtime_dir" 1
  _create_core_team "$session" "$runtime_dir" "$dir"
  tmux new-window -t "$session" -c "$dir"

  [[ "$headless" -eq 0 ]] && step_done

  # -- Theme --
  _step_msg 2 "Applying theme..." "$headless"
  local border_fmt=" #{?pane_active,#[fg=cyan bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  apply_doey_theme "$session" "$name" "$border_fmt" 2
  [[ "$headless" -eq 0 ]] && step_done

  # -- Grid --
  _step_msg 3 "Building ${cols}x${rows} grid (${total} panes)..." "$headless"

  for (( r=1; r<rows; r++ )); do
    tmux split-window -v -t "$session:${team_window}.0" -c "$dir"
  done
  tmux select-layout -t "$session:${team_window}" even-vertical

  for (( r=0; r<rows; r++ )); do
    for (( c=1; c<cols; c++ )); do
      tmux split-window -h -t "$session:${team_window}.$((r * cols))" -c "$dir"
    done
  done

  sleep 0.1
  local actual
  actual=$(tmux list-panes -t "$session:${team_window}" 2>/dev/null | wc -l)
  actual="${actual// /}"
  [[ "$actual" -ne "$total" ]] && \
    printf "\n   ${WARN}⚠ Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total" "$actual"

  # Apply manager-left layout: pane 0 full-height left, workers in 2-row columns
  rebalance_grid_layout "$session" "$team_window" "$runtime_dir"

  [[ "$headless" -eq 0 ]] && step_done

  # -- Name panes --
  _step_msg 4 "Naming panes..." "$headless"

  local _name_cmd="tmux select-pane -t \"$session:${team_window}.0\" -T \"${name} T${team_window} Mgr\""
  for (( i=1; i<total; i++ )); do
    _name_cmd="${_name_cmd} \\; select-pane -t \"$session:${team_window}.$i\" -T \"T${team_window} W${i}\""
  done
  eval "$_name_cmd"
  tmux rename-window -t "$session:${team_window}" "Local Team"

  [[ "$headless" -eq 0 ]] && step_done

  # -- Manager --
  _step_msg 5 "Launching ${DOEY_ROLE_TEAM_LEAD}..." "$headless"

  _launch_team_manager "$session" "$runtime_dir" "$team_window"

  local _wpl_result
  _wpl_result=$(_build_worker_pane_list "$session" "$team_window")
  _brief_team "$session" "$team_window" "" "$_wpl_result" "$worker_count" "Grid ${grid}"

  (
    sleep "$DOEY_MANAGER_BRIEF_DELAY"
    # Boss briefing (pane 0.1)
    doey_send_verified "$session:0.1" \
      "Session online. You are ${DOEY_ROLE_BOSS}. Project: ${name}, dir: ${dir}, session: ${session}. ${DOEY_ROLE_COORDINATOR} is in the Core Team window. Team window ${team_window} has ${worker_count} workers. Awaiting instructions." || true
    # Taskmaster briefing (Core Team pane 1.0)
    local _tm_pane
    _tm_pane=$(grep '^TASKMASTER_PANE=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    _tm_pane="${_tm_pane:-1.0}"
    doey_send_verified "$session:${_tm_pane}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. You are ${DOEY_ROLE_COORDINATOR} at pane ${_tm_pane} in Core Team window. Worker team windows: ${team_window}. Awaiting ${DOEY_ROLE_BOSS} instructions." || true
  ) &

  trap 'jobs -p | xargs kill 2>/dev/null; git worktree prune 2>/dev/null' EXIT INT TERM

  [[ "$headless" -eq 0 ]] && step_done

  # -- Boot workers --
  _step_msg 6 "Booting ${worker_count} workers..." "$headless"
  [[ "$headless" -eq 0 ]] && printf '\n'

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
  local runtime_dir="${TMPDIR:-/tmp}/doey/${name}"

  doey_splash
  _splash_wait_minimum 6

  ensure_project_trusted "$dir"

  # Redirect step output to log — splash stays visible on terminal
  mkdir -p "${runtime_dir}/logs"
  exec 3>&1 4>&2
  exec 1>>"${runtime_dir}/logs/startup.log" 2>&1

  _launch_session_core "$name" "$dir" "$grid" 0

  # Start loading screen on real terminal (stdout is redirected to log)
  local _loading_pid=""
  if command -v doey-loading >/dev/null 2>&1; then
    doey-loading --session "$session" --runtime "$runtime_dir" --timeout 45 >&3 2>&4 &
    _loading_pid=$!
  elif [ -x "${HOME}/.local/bin/doey-loading" ]; then
    "${HOME}/.local/bin/doey-loading" --session "$session" --runtime "$runtime_dir" --timeout 45 >&3 2>&4 &
    _loading_pid=$!
  fi

  # Restore stdout, wait for loading screen
  exec 1>&3 2>&4 3>&- 4>&-
  if [ -n "$_loading_pid" ]; then
    wait "$_loading_pid" 2>/dev/null || true
  fi

  attach_or_switch "$session"
}

# _print_doey_banner, _print_full_banner → doey-ui.sh

# Clean up old session, runtime dir, and stale worktree branches
_cleanup_old_session() {
  local session="$1" runtime_dir="$2"
  tmux kill-session -t "$session" 2>/dev/null || true
  # Stop doey-router
  if [ -f "$runtime_dir/doey-router.pid" ]; then
    kill "$(cat "$runtime_dir/doey-router.pid")" 2>/dev/null || true
    rm -f "$runtime_dir/doey-router.pid"
  fi
  # Stop doey-daemon
  if [ -f "$runtime_dir/doey-daemon.pid" ]; then
    kill "$(cat "$runtime_dir/doey-daemon.pid")" 2>/dev/null || true
    rm -f "$runtime_dir/doey-daemon.pid"
  fi
  # Clean up all MCP servers and configs
  doey_mcp_cleanup_session "$runtime_dir" || true
  rm -rf "$runtime_dir"
  git worktree prune 2>/dev/null || true
  # Delete doey/team-* branches whose worktrees no longer exist
  git for-each-ref --format='%(refname:short)' 'refs/heads/doey/team-*' | while read -r b; do
    # Keep branches that still have an active worktree
    if git worktree list --porcelain 2>/dev/null | grep -q "branch refs/heads/${b}$"; then
      continue
    fi
    # Check for unmerged commits before deleting
    local unmerged
    unmerged=$(git rev-list --count "HEAD..${b}" 2>/dev/null || echo 0)
    if [ "$unmerged" -gt 0 ] 2>/dev/null; then
      printf 'WARNING: Branch %s has %s unmerged commit(s). Creating safety ref.\n' "$b" "$unmerged" >&2
      git tag "doey/safety/${b}_$(date +%s)" "$b" 2>/dev/null || true
    fi
    git branch -D "$b" 2>/dev/null || true
  done
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status,logs,mcp,mcp/pids}
  : > "${runtime_dir}/logs/doey-router.log" 2>/dev/null
  : > "${runtime_dir}/logs/doey-daemon.log" 2>/dev/null
}

# Build comma-separated worker pane indices "1,2,3,...,N"
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
  sleep 0.5
  for (( attempt=0; attempt<max; attempt++ )); do
    child=$(pgrep -P "$shell_pid" 2>/dev/null || true)
    [ -z "$child" ] && return 0
    kill -9 "$child" 2>/dev/null || true
    sleep 0.1
  done
  return 0
}

# ── Doctor check helper moved to doey-doctor.sh ──

# ── Task CLI functions moved to doey-task-cli.sh ──

# ── Update/reinstall functions moved to doey-update.sh ──

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
  [ -z "$name" ] && { doey_error "No doey project for $dir"; exit 1; }
  session="doey-${name}"
  runtime_dir="${TMPDIR:-/tmp}/doey/${name}"
  session_exists "$session" || { doey_error "No running session: ${session}"; exit 1; }
  [ -f "${runtime_dir}/session.env" ] || { doey_error "session.env not found"; exit 1; }

  doey_header "Reloading ${session}..."

  # Install latest files from repo
  local repo_dir
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
  if [ -n "$repo_dir" ] && [ -d "$repo_dir" ]; then
    doey_info "Installing latest files..."
    bash "$repo_dir/install.sh" 2>&1 | sed 's/^/    /'
    printf '\n'
    doey_success "Files installed"
    printf '\n'
  else
    doey_warn "No repo path — skipping install"
    printf '\n'
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

  write_worker_system_prompt "$runtime_dir" "$name" "$dir"
  doey_success "Worker system prompts updated"

  printf '\n'
  doey_info "Reloading Manager..."

  local team_windows="" tf tw
  for tf in "${runtime_dir}"/team_*.env; do
    [ -f "$tf" ] || continue
    tw=$(_env_val "$tf" WINDOW_INDEX)
    [ -n "$tw" ] && team_windows="$team_windows $tw"
  done

  for tw in $team_windows; do
    local team_env="${runtime_dir}/team_${tw}.env"
    [ -f "$team_env" ] || continue

    local mgr_pane
    mgr_pane=$(_env_val "$team_env" MANAGER_PANE)

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
      tmux copy-mode -q -t "$mgr_ref" 2>/dev/null || true
      doey_send_command "$mgr_ref" "clear"
      sleep 0.2
      mgr_agent=$(generate_team_agent "doey-subtaskmaster" "$tw")
      local _rl_mgr_cmd="claude --dangerously-skip-permissions --model $DOEY_MANAGER_MODEL --name \"T${tw} ${DOEY_ROLE_TEAM_LEAD}\" --agent \"$mgr_agent\""
      _append_settings _rl_mgr_cmd "$runtime_dir"
      doey_send_command "$mgr_ref" "${_DRAIN_STDIN}${_rl_mgr_cmd}"
      printf " ${SUCCESS}✓${RESET}\n"
      (
        sleep "$DOEY_MANAGER_BRIEF_DELAY"
        doey_send_verified "$mgr_ref" \
          "Team is online (project: ${name}, dir: $dir). You have ${worker_count_tw:-0} workers in panes ${wp_list}. Your workers are in window ${tw}. Session: $session. All workers are idle and awaiting tasks. What should we work on?" || true
      ) &
    else
      printf " ${WARN}(not found)${RESET}\n"
    fi

  done

  printf '\n'; doey_success "Manager reloaded"

  # 7. Optionally restart workers
  if $restart_workers; then
    printf '\n'
    doey_info "Restarting workers..."
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
        tmux copy-mode -q -t "$pane_ref" 2>/dev/null || true
        doey_send_command "$pane_ref" "clear"
        sleep 0.2

        local w_name
        w_name=$(tmux display-message -t "$pane_ref" -p '#{pane_title}' 2>/dev/null || echo "T${tw} W${wp}")
        local worker_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"${w_name}\""
        _append_settings worker_cmd "$runtime_dir"
        local worker_prompt
        worker_prompt=$(grep -rl "pane ${tw}\.${wp} " "${runtime_dir}"/worker-system-prompt-*.md 2>/dev/null | head -1)
        [ -n "$worker_prompt" ] && worker_cmd+=" --append-system-prompt-file \"${worker_prompt}\""
        doey_send_command "$pane_ref" "${_DRAIN_STDIN}${worker_cmd}"
        printf "    %s.%s ${SUCCESS}✓${RESET}\n" "$tw" "$wp"
        sleep "$DOEY_WORKER_LAUNCH_DELAY"
      done
    done
    printf '\n'; doey_success "Workers restarted"
  fi

  # Rebuild stale Go binaries if helpers available
  if [ -n "$repo_dir" ] && type _check_go_freshness >/dev/null 2>&1; then
    local _stale_output
    if _stale_output=$(_check_go_freshness "$repo_dir" 2>&1) && [ -z "$_stale_output" ]; then
      : # all fresh, nothing to do
    elif type _build_all_go_binaries >/dev/null 2>&1; then
      doey_info "Rebuilding stale Go binaries..."
      if _build_all_go_binaries "$repo_dir" 2>&1; then
        doey_success "Go binaries rebuilt"
      else
        doey_warn "Go rebuild failed (non-fatal)"
      fi
    fi
  fi

  printf '\n'; doey_success "Reload complete"
  $restart_workers || doey_info "Workers kept running. Use 'doey reload --workers' to restart them too."
}

# ── Uninstall moved to doey-update.sh ──

# ── Doctor functions moved to doey-doctor.sh ──

# ── Remove — unregister a project ────────────────────────────────────
remove_project() {
  local name="${1:-}"
  [[ -z "$name" ]] && name="$(find_project "$(pwd)")"

  if [[ -z "$name" ]]; then
    doey_error "No project specified and no project registered for $(pwd)"
    printf '\n'
    doey_info "Registered projects:"
    while IFS=: read -r pname ppath; do
      [[ -z "$pname" ]] && continue
      printf "    ${BOLD}%s${RESET}  ${DIM}%s${RESET}\n" "$pname" "$ppath"
    done < "$PROJECTS_FILE"
    printf '\n'
    printf "  Usage: ${BOLD}doey remove <name>${RESET}\n"
    return 1
  fi

  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { doey_error "Invalid project name: $name"; return 1; }
  grep -q "^${name}:" "$PROJECTS_FILE" 2>/dev/null || { doey_error "No project '$name' in registry"; return 1; }

  grep -v "^${name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
  doey_ok "Removed '$name' from registry"
  session_exists "doey-${name}" && \
    doey_warn "Session doey-${name} still running — use 'doey stop' to stop it"
}

# ── Version display moved to doey-update.sh ──

# ── Update check moved to doey-update.sh ──

# Shared session bootstrap: cleanup, worker prompt, tmux session, team window
# NOTE: Does NOT call setup_dashboard — caller must write session.env first, then call setup_dashboard
_init_doey_session() {
  local session="$1" runtime_dir="$2" dir="$3" name="$4"
  _cleanup_old_session "$session" "$runtime_dir"
  write_worker_system_prompt "$runtime_dir" "$name" "$dir"
  tmux new-session -d -s "$session" -x 250 -y 80 -c "$dir" >/dev/null

  # Prevent tmux from eating first character after Escape in send-keys
  tmux set-option -s -t "$session" escape-time 0

  # Group rapid keystrokes as paste (50ms threshold) to prevent
  # character-by-character delivery that races with TUI redraws
  tmux set-option -g assume-paste-time 50

  # Sync persistent tasks (.doey/tasks/) → runtime cache for hooks/TUI
  if [ -d "${dir}/.doey/tasks" ]; then
    _task_sync_to_runtime "${dir}/.doey/tasks" "${runtime_dir}/tasks"
  fi

  # Generate settings overlay with Doey statusline (ships with Doey, not user config)
  local _doey_settings=""
  local _statusline_cmd="$HOME/.local/bin/doey-statusline.sh"
  if [ -f "$_statusline_cmd" ]; then
    cat > "${runtime_dir}/doey-settings.json" << SJSON
{"statusLine":{"type":"command","command":"bash ${_statusline_cmd}"}}
SJSON
    _doey_settings="${runtime_dir}/doey-settings.json"
  fi

  # Remote detection — expose to hooks and info-panel
  local is_remote
  is_remote=$(_detect_remote)

  # Batch all tmux set-environment calls (saves 4 forks)
  tmux set-environment -t "$session" DOEY_RUNTIME "${runtime_dir}" \; \
       set-environment -t "$session" DOEY_INFO_PANEL_REFRESH "$DOEY_INFO_PANEL_REFRESH" \; \
       set-environment -t "$session" DOEY_SETTINGS "$_doey_settings" \; \
       set-environment -t "$session" DOEY_REMOTE "$is_remote" \; \
       set-environment -t "$session" DOEY_TUNNEL_URL ""

  # Populate SQLite store from existing files (one-shot, idempotent)
  if command -v doey-ctl >/dev/null 2>&1; then
    doey migrate --project-dir "$dir" 2>/dev/null || true
  fi
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
  local session="doey-${name}" runtime_dir="${TMPDIR:-/tmp}/doey/${name}"
  local short_dir="${dir/#$HOME/~}"
  local team_window=2

  cd "$dir"
  _doey_reload_config

  # Quick mode: minimal defaults, skip wizard
  if [ "$DOEY_QUICK" = "true" ]; then
    : "${DOEY_INITIAL_TEAMS:=0}"
    : "${DOEY_INITIAL_WORKER_COLS:=1}"
    : "${DOEY_INITIAL_FREELANCER_TEAMS:=0}"
  fi

  # Run startup wizard if not skipped (needs TTY — runs before background fork)
  if [ "$DOEY_SKIP_WIZARD" != "true" ] && command -v doey-tui >/dev/null 2>&1; then
    local _wizard_out=""
    local _wizard_tmpfile
    _wizard_tmpfile="$(mktemp "${TMPDIR:-/tmp}/doey-wizard-XXXXXX.json")"
    # Run wizard with direct TTY access — command substitution $() steals
    # stdout and breaks huh's terminal rendering, so capture via temp file.
    if doey-tui setup > "$_wizard_tmpfile" </dev/tty 2>/dev/tty; then
      _wizard_out="$(cat "$_wizard_tmpfile")"
    fi
    rm -f "$_wizard_tmpfile"
    if [ -n "$_wizard_out" ]; then
      # Parse wizard JSON output to set team config
      local _wiz_team_count
      _wiz_team_count="$(printf '%s' "$_wizard_out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('teams',[])))" 2>/dev/null)" || true
      if [ -n "$_wiz_team_count" ] && [ "$_wiz_team_count" -gt 0 ] 2>/dev/null; then
        DOEY_TEAM_COUNT="$_wiz_team_count"
        local _wiz_i=1
        while [ "$_wiz_i" -le "$_wiz_team_count" ]; do
          local _wiz_type _wiz_name _wiz_workers _wiz_def
          _wiz_type="$(printf '%s' "$_wizard_out" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d['teams'][$_wiz_i-1]; print(t.get('type','regular'))" 2>/dev/null)" || true
          _wiz_name="$(printf '%s' "$_wizard_out" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d['teams'][$_wiz_i-1]; print(t.get('name',''))" 2>/dev/null)" || true
          _wiz_workers="$(printf '%s' "$_wizard_out" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d['teams'][$_wiz_i-1]; print(t.get('workers',4))" 2>/dev/null)" || true
          _wiz_def="$(printf '%s' "$_wizard_out" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d['teams'][$_wiz_i-1]; print(t.get('def',''))" 2>/dev/null)" || true

          case "$_wiz_type" in
            freelancer)
              eval "DOEY_TEAM_${_wiz_i}_TYPE=freelancer"
              eval "DOEY_TEAM_${_wiz_i}_NAME=\"${_wiz_name:-Freelancers}\""
              ;;
            premade)
              eval "DOEY_TEAM_${_wiz_i}_TYPE=premade"
              eval "DOEY_TEAM_${_wiz_i}_DEF=\"${_wiz_def}\""
              eval "DOEY_TEAM_${_wiz_i}_NAME=\"${_wiz_name}\""
              ;;
            *)
              eval "DOEY_TEAM_${_wiz_i}_TYPE=local"
              eval "DOEY_TEAM_${_wiz_i}_NAME=\"${_wiz_name:-Team ${_wiz_i}}\""
              eval "DOEY_TEAM_${_wiz_i}_WORKERS=\"${_wiz_workers:-4}\""
              ;;
          esac
          _wiz_i=$((_wiz_i + 1))
        done
        # Disable legacy team/freelancer creation
        DOEY_INITIAL_TEAMS=0
        DOEY_INITIAL_FREELANCER_TEAMS=0
      fi
    fi
  fi

  local initial_workers=$(( DOEY_INITIAL_WORKER_COLS * 2 ))

  ensure_project_trusted "$dir"
  install_doey_hooks "$dir" "   "

  # ── Progress-file startup ────────────────────────────────────────────
  mkdir -p "${runtime_dir}/logs"
  local progress_file="${runtime_dir}/startup-progress"
  rm -f "$progress_file"
  : > "$progress_file"

  # Fork actual setup into background — writes STEP lines to progress file
  (
    exec 1>>"${runtime_dir}/logs/startup.log" 2>&1

    echo "STEP: Creating session" >> "$progress_file"
    STEP_TOTAL=7
    step_start 1 "Creating session for ${name}..."
    _init_doey_session "$session" "$runtime_dir" "$dir" "$name"
    step_done

    echo "STEP: Applying theme" >> "$progress_file"
    step_start 2 "Applying theme..."
    local border_fmt=' #{?pane_active,#[fg=cyan bold],#[fg=colour245]}#{pane_title} #[default]'
    apply_doey_theme "$session" "$name" "$border_fmt" 5
    step_done

    echo "STEP: Setting up grid" >> "$progress_file"
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
MAX_WORKERS="$DOEY_MAX_WORKERS"
WORKER_PANES=""
WORKER_COUNT="0"
CURRENT_COLS="1"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="${DOEY_PASTE_SETTLE_MS:-800}"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
TEAM_WINDOWS=""
BOSS_PANE="0.1"
TASKMASTER_PANE="1.0"
REMOTE="$(_detect_remote)"
MANIFEST

    _detect_project_type "$dir"
    _write_project_type_env "$runtime_dir"

    _maybe_start_tunnel "$runtime_dir" "$(_detect_remote)"

    # Launch doey-router daemon
    if [ "${DOEY_ROUTER_ENABLED:-true}" != "false" ]; then
      _router_bin=""
      if command -v doey-router >/dev/null 2>&1; then
        _router_bin="doey-router"
      elif [ -x "${HOME}/.local/bin/doey-router" ]; then
        _router_bin="${HOME}/.local/bin/doey-router"
      fi
      if [ -n "$_router_bin" ]; then
        mkdir -p "${runtime_dir}/logs"
        "$_router_bin" --runtime "$runtime_dir" --project-dir "$dir" -log-file "${runtime_dir}/logs/doey-router.log" >/dev/null 2>&1 &
        echo $! > "$runtime_dir/doey-router.pid"
      fi
    fi

    # Launch doey-daemon (observability)
    local _daemon_bin
    _daemon_bin=$(command -v doey-daemon 2>/dev/null || echo "${HOME}/.local/bin/doey-daemon")
    if [ -x "$_daemon_bin" ]; then
      mkdir -p "${runtime_dir}/daemon"
      "$_daemon_bin" --runtime "$runtime_dir" --project-dir "$dir" \
        --log-file "${runtime_dir}/logs/doey-daemon.log" \
        --stats-file "${runtime_dir}/daemon/stats.json" >/dev/null 2>&1 &
      echo $! > "${runtime_dir}/doey-daemon.pid"
    fi

    # Check if team 1 has a definition file — if so, use add_team_from_def instead of dynamic grid
    local _team1_def=""
    [ -n "${DOEY_TEAM_COUNT:-}" ] && _team1_def=$(_read_team_config "1" "DEF" "")
    local _team1_type=""
    [ -n "${DOEY_TEAM_COUNT:-}" ] && _team1_type=$(_read_team_config "1" "TYPE" "")

    # Determine if any worker teams should be created
    local _want_first_team="true"
    if [ -z "${DOEY_TEAM_COUNT:-}" ] || [ "${DOEY_TEAM_COUNT:-0}" -eq 0 ]; then
      [ "${DOEY_INITIAL_TEAMS:-0}" -le 0 ] && _want_first_team="false"
    fi

    if [ "$_want_first_team" = "false" ]; then
      # No worker teams — Dashboard + Core Team only
      setup_dashboard "$session" "$dir" "$runtime_dir" "0"
      _create_core_team "$session" "$runtime_dir" "$dir"
      step_done
    elif [ -n "$_team1_def" ]; then
      # First worker team uses a .team.md definition — dashboard + core team first, then spawn from def
      write_team_env "$runtime_dir" "$team_window" "dynamic" "" "0" "0" "" ""
      setup_dashboard "$session" "$dir" "$runtime_dir" "$DOEY_INITIAL_TEAMS"
      _create_core_team "$session" "$runtime_dir" "$dir"
      step_done

      echo "STEP: Launching team from definition" >> "$progress_file"
      step_start 4 "Launching team ${team_window} from definition '${_team1_def}'..."
      if ! ( add_team_from_def "$session" "$runtime_dir" "$dir" "$_team1_def" "$_team1_type" ); then
        doey_error "Failed to launch team ${team_window} from definition '${_team1_def}'"
      fi
      step_done

      STEP_TOTAL=6  # Skip step 5 (worker columns) — add_team_from_def handles workers
    else
      # Default dynamic grid path for first worker team
      write_team_env "$runtime_dir" "$team_window" "dynamic" "" "0" "0" "" ""

      # Dashboard launches after session.env exists (info-panel + Taskmaster need it)
      setup_dashboard "$session" "$dir" "$runtime_dir" "$DOEY_INITIAL_TEAMS"
      _create_core_team "$session" "$runtime_dir" "$dir"
      tmux new-window -t "$session" -c "$dir"
      tmux select-pane -t "$session:${team_window}.0" -T "${name} T${team_window} Mgr"
      tmux rename-window -t "$session:${team_window}" "Local Team"
      _register_team_window "$runtime_dir" "$team_window"

      step_done

      echo "STEP: Launching ${DOEY_ROLE_TEAM_LEAD}" >> "$progress_file"
      step_start 4 "Launching ${DOEY_ROLE_TEAM_LEAD}..."
      _launch_team_manager "$session" "$runtime_dir" "$team_window"
      _brief_team "$session" "$team_window" "" "" "0" \
        "Dynamic grid — ${initial_workers} initial workers, auto-expands when all are busy"
      step_done

      echo "STEP: Adding workers" >> "$progress_file"
      step_start 5 "Adding ${DOEY_INITIAL_WORKER_COLS} worker columns (${initial_workers} workers)..."
      local _col_i
      for (( _col_i=0; _col_i<DOEY_INITIAL_WORKER_COLS; _col_i++ )); do
        doey_add_column "$session" "$runtime_dir" "$dir" "$team_window"
      done
      step_done
    fi

    # Update first worker team's env with per-team config if specified
    if [ -n "${DOEY_TEAM_COUNT:-}" ] && [ "${DOEY_TEAM_COUNT:-0}" -gt 0 ]; then
      if [ -z "$_team1_def" ]; then
        local _ptc1_name _ptc1_role _ptc1_wm _ptc1_mm
        _ptc1_name=$(_read_team_config "1" "NAME" "")
        _ptc1_role=$(_read_team_config "1" "ROLE" "")
        _ptc1_wm=$(_read_team_config "1" "WORKER_MODEL" "")
        _ptc1_mm=$(_read_team_config "1" "MANAGER_MODEL" "")
        if [ -n "$_ptc1_name" ] || [ -n "$_ptc1_role" ] || [ -n "$_ptc1_wm" ] || [ -n "$_ptc1_mm" ]; then
          local _ptc1_wp _ptc1_wc
          _ptc1_wp=$(_env_val "${runtime_dir}/team_${team_window}.env" WORKER_PANES)
          _ptc1_wc=$(_env_val "${runtime_dir}/team_${team_window}.env" WORKER_COUNT)
          write_team_env "$runtime_dir" "$team_window" "dynamic" "$_ptc1_wp" "$_ptc1_wc" "0" "" "" "$_ptc1_name" "$_ptc1_role" "$_ptc1_wm" "$_ptc1_mm"
          [ -n "$_ptc1_name" ] && tmux rename-window -t "$session:${team_window}" "$_ptc1_name"
        fi
      fi
    fi

    # Signal foreground that first team is ready — triggers progress display to exit
    echo "STEP: Ready" >> "$progress_file"

    # ── Spawn remaining teams + briefings (post-attach) ──────────────
    sleep 0.3

    # Spawn remaining teams (T2+)
    if [ -n "${DOEY_TEAM_COUNT:-}" ] && [ "${DOEY_TEAM_COUNT:-0}" -gt 0 ]; then
      local _ptc_total="${DOEY_TEAM_COUNT}"
      local _ptc_remaining=$((_ptc_total - 1))
      if [ "$_ptc_remaining" -gt 0 ]; then
        local _ptc_i _ptc_fail=0
        for (( _ptc_i=2; _ptc_i<=_ptc_total; _ptc_i++ )); do
          local _ptc_type _ptc_workers _ptc_name _ptc_role _ptc_wm _ptc_mm _ptc_cols _ptc_wt_spec
          _ptc_type=$(_read_team_config "$_ptc_i" "TYPE" "")
          _ptc_workers=$(_read_team_config "$_ptc_i" "WORKERS" "")
          _ptc_name=$(_read_team_config "$_ptc_i" "NAME" "")
          _ptc_role=$(_read_team_config "$_ptc_i" "ROLE" "")
          _ptc_wm=$(_read_team_config "$_ptc_i" "WORKER_MODEL" "")
          _ptc_mm=$(_read_team_config "$_ptc_i" "MANAGER_MODEL" "")

          if [ -z "$_ptc_type" ]; then
            if [ "$_ptc_i" -le "${DOEY_INITIAL_TEAMS:-2}" ]; then _ptc_type="local"; else _ptc_type="worktree"; fi
          fi
          [ -z "$_ptc_workers" ] && _ptc_workers=$(( ${DOEY_INITIAL_WORKER_COLS:-1} * 2 ))
          _ptc_cols=$(( (_ptc_workers + 1) / 2 ))
          [ "$_ptc_cols" -lt 1 ] && _ptc_cols=1

          _ptc_wt_spec=""
          [ "$_ptc_type" = "worktree" ] && _ptc_wt_spec="auto"
          local _ptc_team_type=""
          [ "$_ptc_type" = "freelancer" ] && _ptc_team_type="freelancer"

          local _ptc_def
          _ptc_def=$(_read_team_config "$_ptc_i" "DEF" "")
          if [ "$_ptc_type" = "premade" ] || [ -n "$_ptc_def" ]; then
            if [ -n "$_ptc_def" ]; then
              add_team_from_def "$session" "$runtime_dir" "$dir" "$_ptc_def" "$_ptc_type" || true
            fi
            (( _ptc_i < _ptc_total )) && sleep $DOEY_TEAM_LAUNCH_DELAY
            continue
          fi

          add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$_ptc_cols" "$_ptc_wt_spec" "$_ptc_name" "$_ptc_role" "$_ptc_wm" "$_ptc_mm" "$_ptc_team_type" || true
          (( _ptc_i < _ptc_total )) && sleep $DOEY_TEAM_LAUNCH_DELAY
        done
      fi
    else
      # Legacy mode: extra teams, worktrees, freelancers
      local _extra_teams=$((DOEY_INITIAL_TEAMS - 1))
      if [ "$_extra_teams" -gt 0 ]; then
        local _team_i
        for (( _team_i=0; _team_i<_extra_teams; _team_i++ )); do
          add_dynamic_team_window "$session" "$runtime_dir" "$dir" || true
          (( _team_i < _extra_teams - 1 )) && sleep $DOEY_TEAM_LAUNCH_DELAY
        done
      fi

      local _wt_i
      for (( _wt_i=0; _wt_i<DOEY_INITIAL_WORKTREE_TEAMS; _wt_i++ )); do
        add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$DOEY_INITIAL_WORKER_COLS" "auto" || true
        (( _wt_i < DOEY_INITIAL_WORKTREE_TEAMS - 1 )) && sleep $DOEY_TEAM_LAUNCH_DELAY
      done

      if [ "$DOEY_INITIAL_FREELANCER_TEAMS" -gt 0 ]; then
        local _fl_i
        for (( _fl_i=0; _fl_i<DOEY_INITIAL_FREELANCER_TEAMS; _fl_i++ )); do
          add_dynamic_team_window "$session" "$runtime_dir" "$dir" "$DOEY_INITIAL_WORKER_COLS" "" "Freelancers" "" "" "" "freelancer" || true
          (( _fl_i < DOEY_INITIAL_FREELANCER_TEAMS - 1 )) && sleep $DOEY_TEAM_LAUNCH_DELAY
        done
      fi
    fi

    # ── Briefings (after all teams are up) ──
    sleep "$DOEY_MANAGER_BRIEF_DELAY"
    local final_team_windows final_team_count=0 _ftw
    final_team_windows=$(read_team_windows "$runtime_dir")
    for _ftw in $(echo "$final_team_windows" | tr ',' ' '); do
      final_team_count=$((final_team_count + 1))
    done

    doey_send_verified "$session:0.1" \
      "Session online. You are ${DOEY_ROLE_BOSS}. Project: ${name}, dir: ${dir}, session: ${session}. ${DOEY_ROLE_COORDINATOR} is in the Core Team window. ${final_team_count} team windows (${final_team_windows}). Awaiting instructions." || true
    local _tm_pane
    _tm_pane=$(grep '^TASKMASTER_PANE=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    _tm_pane="${_tm_pane:-1.0}"
    doey_send_verified "$session:${_tm_pane}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. You are ${DOEY_ROLE_COORDINATOR} at pane ${_tm_pane} in Core Team window. Worker team windows: ${final_team_windows}. Awaiting ${DOEY_ROLE_BOSS} instructions." || true
  ) &
  local _bg_setup_pid=$!

  # Foreground: display startup progress (doey-tui or text fallback)
  _show_startup_progress "$progress_file" 60

  # Attach — session and first team are ready
  tmux select-window -t "$session:0"
  attach_or_switch "$session"

  # After detach, wait for background spawner to finish
  wait "$_bg_setup_pid" 2>/dev/null || true
}

# ── Team management functions moved to doey-team-mgmt.sh ──
# ── E2E Test Runner moved to doey-test-runner.sh ──

# ── Deploy Pipeline ───────────────────────────────────────────────────

doey_deploy() {
  local session="$1" runtime_dir="$2" dir="$3"
  shift 3
  local subcmd="${1:-start}"
  case "$subcmd" in
    start)
      printf '%b Starting deploy validation pipeline...\n' "$BRAND"
      # Run project detection if not already done
      if [ -z "${PROJECT_LANGUAGE:-}" ]; then
        _detect_project_type "$dir"
        [ -f "$runtime_dir/session.env" ] && . "$runtime_dir/session.env"
      fi
      # Spawn deploy team via add_team_from_def
      add_team_from_def "$session" "$runtime_dir" "$dir" "deploy"
      printf '%b Deploy team spawned. Monitor with: doey deploy status\n' "$SUCCESS"
      ;;
    status)
      printf '%b Deploy Pipeline Status\n' "$BRAND"
      printf '%b─────────────────────%b\n' "$BRAND" "$RESET"
      if [ -f "$runtime_dir/deploy_status" ]; then
        cat "$runtime_dir/deploy_status"
      else
        printf '  No active deploy pipeline. Run: doey deploy start\n'
      fi
      ;;
    gate)
      local gate_script="${dir}/shell/pre-push-gate.sh"
      if [ -f "$gate_script" ]; then
        bash "$gate_script" "$dir" "$runtime_dir"
      else
        printf '%b pre-push-gate.sh not found\n' "$ERROR"
        return 1
      fi
      ;;
    *)
      printf '%b Usage: doey deploy [start|status|gate]\n' "$BRAND"
      printf '  start  — Spawn deploy validation team\n'
      printf '  status — Show pipeline status\n'
      printf '  gate   — Run pre-push quality gate\n'
      ;;
  esac
}

# Sets: dir, name, session, runtime_dir
require_running_session() {
  dir="$(pwd)"
  name="$(find_project "$dir")"
  [[ -z "$name" ]] && { doey_error "No project registered for $dir"; exit 1; }
  session="doey-${name}"
  session_exists "$session" || { doey_error "Session $session not running"; exit 1; }
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
      doey_header "Doey Configuration"
      printf '\n'
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
      printf "    DOEY_WORKER_LAUNCH_DELAY  = %s\n" "${DOEY_WORKER_LAUNCH_DELAY}"
      printf "    DOEY_TEAM_LAUNCH_DELAY    = %s\n" "${DOEY_TEAM_LAUNCH_DELAY}"
      printf "    DOEY_BOOT_TIMEOUT         = %s\n" "${DOEY_BOOT_TIMEOUT}"
      printf "\n"
      ;;
    --global|"")
      # Edit project config if available (and no --global flag), else global
      if [ "${1:-}" != "--global" ] && [ -n "$project_config" ]; then
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
    --reset)
      if [ ! -f "$template" ]; then
        printf "  ${ERROR}Template not found: %s${RESET}\n" "$template"
        return 1
      fi
      local target="$global_config"
      [ -n "$project_config" ] && target="$project_config" || mkdir -p "$global_dir"
      cp "$template" "$target"
      printf "  ${SUCCESS}Reset${RESET} %s to defaults\n" "$target"
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

  # Left pane (pane 0): run settings panel with live refresh
  doey_send_command "$session:${settings_win}.0" "DOEY_SETTINGS_LIVE=1 bash \"\$HOME/.local/bin/settings-panel.sh\""

  # Split right — pane 1 becomes the Claude config editor
  tmux split-window -h -t "$session:${settings_win}.0"
  doey_send_command "$session:${settings_win}.1" "claude --agent settings-editor"

  # Focus the right pane (editor)
  tmux select-pane -t "$session:${settings_win}.1"
  attach_or_switch "$session"
}

# ── Remote functions moved to doey-remote.sh ──

# ── Main Dispatch ─────────────────────────────────────────────────────

_attach_session() {
  local session="$1"
  doey_ok "Attaching to ${session}..."
  tmux select-window -t "$session:0"
  attach_or_switch "$session"
}

# ── Prerequisite gate ─────────────────────────────────────────────────
# Catch missing tmux/claude early with helpful install guidance.
# Runs before any command except --help, doctor, version, uninstall.
_check_prereqs() {
  local missing=false

  if ! command -v tmux >/dev/null 2>&1; then
    missing=true
    echo ""
    doey_error "tmux is not installed"
    doey_info "Doey needs tmux to run parallel Claude Code agents."
    printf '\n'
    case "$(uname -s)" in
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          printf "  ${BOLD}Install now:${RESET}\n"
          printf "    ${BRAND}brew install tmux${RESET}\n\n"
          if [ -t 0 ]; then
            if doey_confirm_default_yes "Run this command?"; then
              printf '\n'
              doey_info "Installing tmux..."
              if brew install tmux; then
                doey_success "tmux installed"
                printf '\n'
                missing=false
              else
                doey_error "Install failed — try manually: brew install tmux"
                printf '\n'
              fi
            fi
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
            if doey_confirm_default_yes "Run this command?"; then
              printf '\n'
              doey_info "Installing tmux..."
              if sudo apt-get update -qq && sudo apt-get install -y tmux; then
                doey_success "tmux installed"
                printf '\n'
                missing=false
              else
                doey_error "Install failed"
                printf '\n'
              fi
            fi
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
        doey_info "Install tmux for your platform: https://github.com/tmux/tmux/wiki/Installing"
        printf '\n'
        ;;
    esac
  fi

  if ! command -v claude >/dev/null 2>&1; then
    missing=true
    doey_error "Claude Code CLI is not installed"
    doey_info "Doey orchestrates Claude Code instances — the CLI is required."
    printf '\n'
    if command -v node >/dev/null 2>&1; then
      printf "  ${BOLD}Install now:${RESET}\n"
      printf "    ${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n\n"
      if [ -t 0 ]; then
        if doey_confirm_default_yes "Run this command?"; then
          printf '\n'
          doey_info "Installing Claude Code..."
          if npm install -g @anthropic-ai/claude-code; then
            doey_success "Claude Code installed"
            doey_info "Run claude once to authenticate, then re-run doey"
            printf '\n'
            missing=false
          else
            doey_error "Install failed — try: sudo npm install -g @anthropic-ai/claude-code"
            printf '\n'
          fi
        fi
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
    doey_info "After installing, re-run: doey"
    exit 1
  fi
}
