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
#   doey reload       # Hot-reload running session (Manager)
#   doey doctor       # Check installation health & prerequisites
#   doey remove NAME  # Unregister a project from the registry
#   doey uninstall    # Remove all Doey files
#   doey test         # Run E2E integration test
#   doey version      # Show version and install info
#   doey 4x3          # Launch/reattach with specific grid
#   doey dynamic      # Launch with dynamic grid (add workers on demand)
#   doey add          # Add a worker column (2 workers) to dynamic session
#   doey remove 2     # Remove worker column 2 from dynamic session
#   doey deploy       # Deploy validation pipeline
#   doey remote       # Manage remote Hetzner servers
#   doey --help       # Show usage
#
# CLI command: "doey" is installed to ~/.local/bin/doey.
# ──────────────────────────────────────────────────────────────────────

# Color palette, gum detection, and all UI/display functions → doey-ui.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_FILE="$HOME/.claude/doey/projects"
mkdir -p "$(dirname "$PROJECTS_FILE")"
touch "$PROJECTS_FILE"

# Go build helpers (used by: doey build, doctor, reload, uninstall)
# Guard: doey-go-helpers.sh may not exist on older installs
_go_helpers="${SCRIPT_DIR}/doey-go-helpers.sh"
if [ -f "$_go_helpers" ]; then
  # shellcheck source=doey-go-helpers.sh
  source "$_go_helpers"
fi

# shellcheck source=doey-roles.sh
source "${SCRIPT_DIR}/doey-roles.sh"

# shellcheck source=doey-send.sh
source "${SCRIPT_DIR}/doey-send.sh"

# shellcheck source=doey-helpers.sh
source "${SCRIPT_DIR}/doey-helpers.sh"

# shellcheck source=doey-ui.sh
source "${SCRIPT_DIR}/doey-ui.sh"

# shellcheck source=doey-remote.sh
source "${SCRIPT_DIR}/doey-remote.sh"

# shellcheck source=doey-purge.sh
source "${SCRIPT_DIR}/doey-purge.sh"

# shellcheck source=doey-update.sh
source "${SCRIPT_DIR}/doey-update.sh"

# shellcheck source=doey-doctor.sh
source "${SCRIPT_DIR}/doey-doctor.sh"

# shellcheck source=doey-agents.sh
source "${SCRIPT_DIR}/doey-agents.sh"

# shellcheck source=doey-task-cli.sh
source "${SCRIPT_DIR}/doey-task-cli.sh"

# shellcheck source=doey-test-runner.sh
source "${SCRIPT_DIR}/doey-test-runner.sh"

# shellcheck source=doey-grid.sh
source "${SCRIPT_DIR}/doey-grid.sh"

# shellcheck source=doey-menu.sh
source "${SCRIPT_DIR}/doey-menu.sh"
# shellcheck source=doey-team-mgmt.sh
source "${SCRIPT_DIR}/doey-team-mgmt.sh"
# shellcheck source=doey-session.sh
source "${SCRIPT_DIR}/doey-session.sh"

# shellcheck source=doey-headless.sh
source "${SCRIPT_DIR}/doey-headless.sh"

# shellcheck source=doey-new.sh
source "${SCRIPT_DIR}/doey-new.sh"

# ── Configuration ───────────────────────────────────────────────────
_doey_load_config

# Grid & Teams — default: no worker teams at startup, spawn on-demand via Dashboard
DOEY_INITIAL_WORKER_COLS="${DOEY_INITIAL_WORKER_COLS:-1}"
DOEY_INITIAL_TEAMS="${DOEY_INITIAL_TEAMS:-0}"
DOEY_INITIAL_WORKTREE_TEAMS="${DOEY_INITIAL_WORKTREE_TEAMS:-0}"
DOEY_INITIAL_FREELANCER_TEAMS="${DOEY_INITIAL_FREELANCER_TEAMS:-0}"
DOEY_MAX_WORKERS="${DOEY_MAX_WORKERS:-20}"
# Auth & Launch Timing
# Defaults are conservative to avoid Claude API rate-limit errors on session start.
# Lower only if your account has high rate limits and you need faster boots.
DOEY_WORKER_LAUNCH_DELAY="${DOEY_WORKER_LAUNCH_DELAY:-0.5}"
DOEY_TEAM_LAUNCH_DELAY="${DOEY_TEAM_LAUNCH_DELAY:-1}"
DOEY_MANAGER_LAUNCH_DELAY="${DOEY_MANAGER_LAUNCH_DELAY:-1}"
DOEY_MANAGER_BRIEF_DELAY="${DOEY_MANAGER_BRIEF_DELAY:-0.5}"

# Dynamic Grid Behavior
DOEY_IDLE_COLLAPSE_AFTER="${DOEY_IDLE_COLLAPSE_AFTER:-60}"
DOEY_IDLE_REMOVE_AFTER="${DOEY_IDLE_REMOVE_AFTER:-300}"
DOEY_PASTE_SETTLE_MS="${DOEY_PASTE_SETTLE_MS:-800}"
DOEY_BOOT_TIMEOUT="${DOEY_BOOT_TIMEOUT:-60}"

# Drain pending terminal escape responses (OSC 11, CPR) from pane stdin before Claude launch.
# With allow-passthrough on, the outer terminal may respond to escape queries from other panes,
# and those responses land on the active pane's stdin. This flushes them.
_DRAIN_STDIN='read -t 1 -n 10000 _ 2>/dev/null || true; '

# Panel & Monitoring
DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"
# Models
DOEY_MANAGER_MODEL="${DOEY_MANAGER_MODEL:-opus}"
DOEY_WORKER_MODEL="${DOEY_WORKER_MODEL:-opus}"
DOEY_TASKMASTER_MODEL="${DOEY_TASKMASTER_MODEL:-opus}"

# ── Remote/tunnel functions moved to doey-remote.sh ──

# ── Functions moved to doey-session.sh ──
# install_doey_hooks, write_pane_status, safe_source_session_env,
# write_worker_system_prompt, _append_settings

# Allow sourcing for tests: `source doey.sh __doey_source_only` loads functions only
[ "${1:-}" = "__doey_source_only" ] && return 0 2>/dev/null || true

grid="dynamic"

# Parse global flags
DOEY_QUICK="${DOEY_QUICK:-false}"
DOEY_SKIP_WIZARD="${DOEY_SKIP_WIZARD:-true}"
_doey_parsed_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --quick|-q) DOEY_QUICK=true; DOEY_SKIP_WIZARD=true; shift ;;
    --no-wizard) DOEY_SKIP_WIZARD=true; shift ;;
    *) _doey_parsed_args+=("$1"); shift ;;
  esac
done
set -- "${_doey_parsed_args[@]+"${_doey_parsed_args[@]}"}"

# ── Unified CLI routing ──────────────────────────────────────────────
# 'doey' is the user-facing CLI. Subcommands below are handled by the
# doey-ctl binary and forwarded transparently.
# Direct passthrough: msg status health task tmux team agent event error
#                     nudge migrate interaction briefing
# Smart routing (handled in main case block with disambiguation):
#   plan   — subcommands (list/get/create/update/delete) → doey-ctl,
#            bare goal string → masterplan
#   config — subcommands (get/set/list/delete) → doey-ctl,
#            flags (--show/--global/--reset) or bare → local editor
case "${1:-}" in
  msg|status|health|task|tmux|team|agent|event|error|nudge|migrate|interaction|briefing|lifecycle)
    if command -v doey-ctl >/dev/null 2>&1; then
      exec doey-ctl "$@"
    else
      printf 'Error: doey CLI tools not installed. Run "doey doctor" or reinstall.\n' >&2
      exit 1
    fi
    ;;
esac

case "${1:-}" in
  help|--help|-h)
    doey_header "Doey"
    printf '\n'
    cat << 'HELP'
  Usage: doey [command] [grid]

  Commands:
    (none)     Smart launch — auto-attach or show project picker
    new NAME   Create a new project, init git, and launch Doey
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
    test dispatch  Test dispatch chain reliability (requires running session)
    dynamic    Launch with dynamic grid (add workers on demand)
    add        Add a worker column (2 workers) to a dynamic grid session
    add-team   Add a team window with its own ${DOEY_ROLE_TEAM_LEAD}+Workers
    kill-team  Kill a team window by window index
    list-teams Show all team windows and their status
    teams      List available premade and project team definitions
    masterplan Start a masterplan team for a goal (alias: plan)
    plan to-tasks   Convert a CONSENSUS masterplan file into tasks+subtasks
    deploy     Deploy validation pipeline (start/status/gate)
    remote     Manage remote Hetzner servers (list/provision/stop/status)
    scaffy     Run scaffy template engine subcommands
    settings   Open interactive settings editor window
    version    Show version and installation info
    --help     Show this help

  Grid:
    NxM        Grid layout (e.g., 6x2, 4x3, 3x2)
    dynamic|d  Dynamic grid — start minimal, add workers with 'doey add'
               Only used when launching a new session

  Examples:
    doey              # smart launch
    doey new my-app   # create ~/projects/my-app and launch
    doey init         # register current dir
    doey 4x3          # launch with 4x3 grid
    doey dynamic      # launch with dynamic grid
    doey add          # add 2 workers to dynamic session
    doey remove 2     # remove worker column 2 from dynamic session
    doey list         # show all projects
    doey stop         # stop current project session
    doey update       # pull latest + reinstall
    doey reload       # hot-reload Manager
    doey reload --workers  # also restart workers
    doey doctor       # check system health
    doey remove myapp # unregister a project
    doey uninstall    # remove all installed files
    doey version      # show install info
    doey config       # edit config (project if .doey/ exists, else global)
    doey config show  # show resolved config with source attribution
    doey config --global # edit global config
    doey config --reset  # reset config to defaults
    doey add-team 3x2 # add a team window (3x2 grid)
    doey kill-team 1  # kill team window 1
    doey list-teams   # show all team windows
    doey remote       # list remote servers
    doey remote myapp # provision + attach to remote
    doey remote stop myapp  # destroy remote server
    doey remote status myapp # show server status
HELP
    printf '\n'
    exit 0
    ;;
  # Commands that don't need tmux/claude running:
  list)         list_projects; exit 0 ;;
  doctor)
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill doctor_run &) 2>/dev/null || true
    shift
    check_doctor "$@"
    exit 0
    ;;
  agents)
    shift
    doey_agents "$@"
    exit $?
    ;;
  version|--version|-v) show_version; exit 0 ;;
  uninstall)
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill uninstall_run &) 2>/dev/null || true
    uninstall_system
    exit 0
    ;;
  --post-update) _post_update "$2"; exit 0 ;;
  update|reinstall)
    _doey_stats_ver=""
    [ -f "$HOME/.claude/doey/version" ] && _doey_stats_ver=$(sed -n 's/^version=//p' "$HOME/.claude/doey/version" 2>/dev/null | head -1)
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill update_run "version=${_doey_stats_ver}" &) 2>/dev/null || true
    unset _doey_stats_ver
    update_system
    exit 0
    ;;
  build)
    printf "  %bBuilding Go binaries...%b\n" "$BRAND" "$RESET"
    if type _build_all_go_binaries >/dev/null 2>&1; then
      repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
      if _build_all_go_binaries "$repo_dir"; then
        printf "  %b✓ Go binaries built%b\n" "$SUCCESS" "$RESET"
      else
        printf "  %b✗ Build failed%b\n" "$ERROR" "$RESET"; exit 1
      fi
    else
      printf "  %b✗ Go helpers not loaded%b\n" "$ERROR" "$RESET"; exit 1
    fi
    ;;
  remote)
    _remote_sub="${2:-list}"
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill "remote_${_remote_sub}" &) 2>/dev/null || true
    unset _remote_sub
    shift
    doey_remote "$@"
    exit 0
    ;;
  scaffy)
    shift
    if command -v doey-scaffy >/dev/null 2>&1; then
      exec doey-scaffy "$@"
    else
      printf 'Error: doey-scaffy not installed. Run "doey doctor" or reinstall.\n' >&2
      exit 1
    fi
    ;;
  # Everything below requires tmux + claude — check prerequisites:
  init)
    _check_prereqs
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill project_registered &) 2>/dev/null || true
    register_project "$(pwd)"
    dir="$(pwd)"; name="$(find_project "$dir")"
    [[ -n "$name" ]] && launch_with_grid "$name" "$dir" "$grid"
    exit 0
    ;;
  new)
    _check_prereqs
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill project_new &) 2>/dev/null || true
    shift
    _doey_new "$@"
    exit 0
    ;;
  purge)
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill purge_run &) 2>/dev/null || true
    shift
    doey_purge "$@"
    exit $?
    ;;
  stop)
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh session session_stopped &) 2>/dev/null || true
    stop_project
    exit $?
    ;;
  reload)       shift; reload_session "$@"; exit 0 ;;
  test)
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill test_run &) 2>/dev/null || true
    shift
    run_test "$@"
    exit $?
    ;;
  settings)     doey_settings; exit 0 ;;
  config)
    _cfg_sub="${2:-bare}"
    case "$_cfg_sub" in
      --*|"") _cfg_sub="${_cfg_sub#--}" ;;
    esac
    [ -z "$_cfg_sub" ] && _cfg_sub="bare"
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill config_edited "cmd=${_cfg_sub}" &) 2>/dev/null || true
    unset _cfg_sub
    # 'doey config <subcommand>' routes to doey-ctl for DB config management;
    # bare 'doey config' or flags (--show/--global/--reset) → local editor
    # 'doey config show' → resolved config with source attribution
    case "${2:-}" in
      get|set|list|delete)
        if command -v doey-ctl >/dev/null 2>&1; then
          exec doey-ctl "$@"
        else
          printf 'Error: doey CLI tools not installed. Run "doey doctor" or reinstall.\n' >&2
          exit 1
        fi
        ;;
      show)
        shift
        doey_config "$@"
        exit 0
        ;;
      *)
        shift
        doey_config "$@"
        exit 0
        ;;
    esac
    ;;
  deploy)
    require_running_session
    shift
    _deploy_sub="${1:-start}"
    case "$_deploy_sub" in
      start) (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill deploy_start &) 2>/dev/null || true ;;
      gate)  (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill deploy_gate  &) 2>/dev/null || true ;;
    esac
    unset _deploy_sub
    doey_deploy "$session" "$runtime_dir" "$dir" "$@"
    exit 0
    ;;
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
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh session session_launched mode=dynamic &) 2>/dev/null || true
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
  add-team)
    require_running_session
    shift
    _at_name="${1:-}"
    if [ -z "$_at_name" ]; then
      doey_error "Usage: doey add-team <name>"
      printf "  Example: doey add-team rd\n"
      exit 1
    fi
    add_team_from_def "$session" "$runtime_dir" "$dir" "$_at_name"
    exit 0
    ;;
  masterplan|plan)
    # 'doey plan <subcommand>' routes to doey-ctl for plan management;
    # 'doey plan "goal text"' keeps masterplan behavior
    if [ "${1:-}" = "plan" ]; then
      case "${2:-}" in
        list|get|create|update|delete)
          if command -v doey-ctl >/dev/null 2>&1; then
            exec doey-ctl "$@"
          else
            printf 'Error: doey CLI tools not installed. Run "doey doctor" or reinstall.\n' >&2
            exit 1
          fi
          ;;
        to-tasks)
          (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill plan_to_tasks_run &) 2>/dev/null || true
          shift 2
          _p2t=""
          if [ -x "${DOEY_LIB_DIR:-}/plan-to-tasks.sh" ]; then
            _p2t="${DOEY_LIB_DIR}/plan-to-tasks.sh"
          elif [ -x "${SCRIPT_DIR:-}/plan-to-tasks.sh" ]; then
            _p2t="${SCRIPT_DIR}/plan-to-tasks.sh"
          elif [ -x "$HOME/.local/bin/doey-plan-to-tasks" ]; then
            _p2t="$HOME/.local/bin/doey-plan-to-tasks"
          elif [ -x "$(dirname "$0")/plan-to-tasks.sh" ]; then
            _p2t="$(dirname "$0")/plan-to-tasks.sh"
          fi
          if [ -z "$_p2t" ]; then
            printf 'Error: plan-to-tasks helper not found. Reinstall doey.\n' >&2
            exit 1
          fi
          exec "$_p2t" "$@"
          ;;
      esac
    fi
    goal="${2:-}"
    [ -z "$goal" ] && { doey_error "Usage: doey masterplan \"goal text\""; exit 1; }
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill masterplan_started &) 2>/dev/null || true
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill skill_invoked cmd=masterplan &) 2>/dev/null || true
    require_running_session
    plan_id="masterplan-$(date +%Y%m%d-%H%M%S)"
    plan_dir="${runtime_dir}/${plan_id}"
    mkdir -p "$plan_dir"
    plan_file="${plan_dir}/plan.md"
    touch "$plan_file"
    printf '%s\n' "$goal" > "${plan_dir}/goal.md"

    # Create task
    task_id=$(doey task create --title "Masterplan: ${goal}" --type feature --description "$goal" --project-dir "$dir" 2>/dev/null) || true

    # Export for add_team_from_def (shell scope) and tmux (pane scope)
    export PLAN_FILE="$plan_file"
    export GOAL_FILE="${plan_dir}/goal.md"
    export MASTERPLAN_ID="$plan_id"
    export DOEY_TASK_ID="${task_id:-}"

    # Set tmux session env so spawned panes inherit these vars
    tmux set-environment -t "$session" PLAN_FILE "$plan_file"
    tmux set-environment -t "$session" GOAL_FILE "${plan_dir}/goal.md"
    tmux set-environment -t "$session" MASTERPLAN_ID "$plan_id"
    [ -n "${task_id:-}" ] && tmux set-environment -t "$session" DOEY_TASK_ID "$task_id"

    # Write masterplan env (persistent reference for hooks/scripts)
    cat > "${runtime_dir}/${plan_id}.env" << MPEOF
PLAN_FILE=${plan_file}
MASTERPLAN_ID=${plan_id}
TASK_ID=${task_id:-}
GOAL_FILE=${plan_dir}/goal.md
MPEOF

    # Spawn team via team definition (teams/masterplan.team.md)
    add_team_from_def "$session" "$runtime_dir" "$dir" "masterplan"

    printf '  %bMasterplan window created for:%b %s\n' "$SUCCESS" "$RESET" "$goal"
    ;;
  add-window)
    require_running_session
    _aw_wt_spec="" _aw_team_type="" _aw_reserved="" _aw_grid_cols="" _aw_grid_rows=""
    _aw_workers="" _aw_name="" _aw_task_id=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --worktree) _aw_wt_spec="auto" ;;
        --type) shift; _aw_team_type="${1:-}" ;;
        --grid) shift; _aw_grid_cols="${1%%x*}"; _aw_grid_rows="${1#*x}" ;;
        --reserved) _aw_reserved="true" ;;
        --workers) shift; _aw_workers="${1:-}" ;;
        --name) shift; _aw_name="${1:-}" ;;
        --task-id) shift; _aw_task_id="${1:-}" ;;
        *) ;; # ignore unknown
      esac
      shift
    done
    # --workers N → compute column count (ceil(N/2))
    if [ -n "$_aw_workers" ]; then
      _aw_grid_cols="$(( (_aw_workers + 1) / 2 ))"
      [ "$_aw_grid_cols" -lt 1 ] && _aw_grid_cols=1
    fi
    if [ "$_aw_team_type" = "freelancer" ]; then
      _aw_cols="${_aw_grid_cols:-$DOEY_INITIAL_WORKER_COLS}"
      # Pass grid rows to add_dynamic_team_window and doey_add_column via env var
      export _DOEY_GRID_ROWS="${_aw_grid_rows:-2}"
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" \
        "$_aw_cols" "$_aw_wt_spec" "${_aw_name:-Freelancers}" "" "" "" "freelancer" "$_aw_reserved" "$_aw_task_id"
    elif [ -n "$_aw_wt_spec" ] || [ -n "$_aw_grid_cols" ]; then
      _aw_cols="${_aw_grid_cols:-$DOEY_INITIAL_WORKER_COLS}"
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" \
        "$_aw_cols" "$_aw_wt_spec" "$_aw_name" "" "" "" "$_aw_team_type" "$_aw_reserved" "$_aw_task_id"
    else
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" \
        "" "" "$_aw_name" "" "" "" "$_aw_team_type" "$_aw_reserved" "$_aw_task_id"
    fi
    exit 0
    ;;
  kill-window|kill-team)
    [ -n "${2:-}" ] || { doey_error "Usage: doey kill-team <window-index>"; exit 1; }
    require_running_session
    kill_team_window "$session" "$runtime_dir" "$2"
    exit 0
    ;;
  list-windows|list-teams)
    require_running_session
    list_team_windows "$session" "$runtime_dir"
    exit 0
    ;;
  teams)
    # List team defs from a set of directories; prints names+descriptions
    _list_team_defs() {
      local _ltd_found=false _f _tname _tdesc
      for _ltd_dir in "$@"; do
        [ -d "$_ltd_dir" ] || continue
        for _f in "$_ltd_dir"/*.team.md; do
          [ -f "$_f" ] || continue
          _ltd_found=true
          _tname="$(grep '^name:' "$_f" | head -1 | sed 's/^name: *//' | tr -d '"')"
          _tdesc="$(grep '^description:' "$_f" | head -1 | sed 's/^description: *//' | tr -d '"')"
          [ -n "$_tname" ] || _tname="$(basename "$_f" .team.md)"
          printf "    %-14s %s\n" "$_tname" "$_tdesc"
        done
      done
      [ "$_ltd_found" = false ] && printf "    ${DIM}(none found)${RESET}\n"
    }
    printf "\n  ${BOLD}Premade teams (shipped with Doey):${RESET}\n"
    _list_team_defs "$HOME/.local/share/doey/teams"
    printf "\n  ${BOLD}Project teams (.doey/teams/ and teams/):${RESET}\n"
    _list_team_defs "$(pwd)/.doey/teams" "$(pwd)/teams"
    printf "\n  Usage: ${BOLD}doey add-team <name>${RESET}\n\n"
    exit 0
    ;;
  tunnel)
    require_running_session
    shift
    _tunnel_state="${1:-help}"
    (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh skill "tunnel_${_tunnel_state}" &) 2>/dev/null || true
    unset _tunnel_state
    _tunnel_env="${runtime_dir}/tunnel.env"
    case "${1:-}" in
      up|start)
        bash "${SCRIPT_DIR}/doey-tunnel.sh" "$runtime_dir" &
        printf '  %bTunnel starting in background...%b\n' "$SUCCESS" "$RESET"
        ;;
      down|stop)
        if [ -f "$_tunnel_env" ]; then
          _tpid="$(grep '^TUNNEL_PID=' "$_tunnel_env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
          if [ -n "$_tpid" ] && kill -0 "$_tpid" 2>/dev/null; then
            kill "$_tpid" 2>/dev/null || true
            rm -f "$_tunnel_env"
            printf '  %bTunnel stopped.%b\n' "$SUCCESS" "$RESET"
          else
            rm -f "$_tunnel_env"
            printf '  Tunnel was not running (stale env cleaned).\n'
          fi
        else
          printf '  No tunnel running.\n'
        fi
        ;;
      status)
        if [ -f "$_tunnel_env" ]; then
          printf '  %bTunnel active:%b\n' "$SUCCESS" "$RESET"
          sed 's/^/    /' "$_tunnel_env"
        else
          printf '  No tunnel running.\n'
        fi
        ;;
      detect)
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/doey-tunnel-detect.sh"
        doey_tunnel_detect_pwd "$(pwd)"
        ;;
      *)
        printf '  Usage: doey tunnel <up|down|status|detect>\n'
        printf '\n'
        printf '  Commands:\n'
        printf '    up       Start a tunnel for the current session\n'
        printf '    down     Stop the running tunnel\n'
        printf '    status   Show tunnel status\n'
        printf '    detect   Auto-detect project ports\n'
        ;;
    esac
    exit 0
    ;;
  [0-9]*x[0-9]*)
    _check_prereqs
    grid="$1"
    _doey_launch_mode="grid"
    ;;
  "") ;;
  open|switch)
    _doey_open_verb="$1"
    shift
    if [ $# -eq 0 ]; then
      show_menu "${grid}"
      exit 0
    fi
    _open_query="$*"
    _open_match=""
    _open_match="$(find_project_by_name "$_open_query")" || true
    if [ -n "$_open_match" ]; then
      _open_pname="${_open_match%%:*}"
      _open_ppath="${_open_match#*:}"
      if session_exists "doey-${_open_pname}"; then
        _attach_session "doey-${_open_pname}"
      else
        cd "$_open_ppath" && launch_with_grid "$_open_pname" "$_open_ppath" "${grid}"
      fi
      (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh session session_launched "mode=${_doey_open_verb}" &) 2>/dev/null || true
    else
      printf '  \033[31m✗\033[0m No project matching "%s"\n' "$_open_query" >&2
      printf '  Registered projects:\n' >&2
      list_projects
    fi
    exit 0
    ;;
  *)
    # Intent fallback — maps unknown commands to the closest doey command
    # using a Claude-powered command expert (Haiku, ~2s).
    # shellcheck source=doey-intent-dispatch.sh
    source "${SCRIPT_DIR}/doey-intent-dispatch.sh"
    _doey_intent_dispatch "$@"
    exit $?
    ;;
esac

# ── Smart Launch ──────────────────────────────────────────────────────

_check_prereqs
check_for_updates
check_agent_freshness

dir="$(pwd)"
name="$(find_project "$dir")"

if [[ -n "$name" ]]; then
  session="doey-${name}"
  if session_exists "$session"; then
    _attach_session "$session"
  else
    launch_with_grid "$name" "$dir" "$grid"
  fi
  (command -v doey-stats-emit.sh >/dev/null 2>&1 && doey-stats-emit.sh session session_launched "mode=${_doey_launch_mode:-bare}" &) 2>/dev/null || true
else
  show_menu "${grid}"
fi
