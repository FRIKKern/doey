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
DOEY_INITIAL_WORKER_COLS="${DOEY_INITIAL_WORKER_COLS:-3}"
DOEY_INITIAL_TEAMS="${DOEY_INITIAL_TEAMS:-2}"
DOEY_INITIAL_WORKTREE_TEAMS="${DOEY_INITIAL_WORKTREE_TEAMS:-0}"
DOEY_INITIAL_FREELANCER_TEAMS="${DOEY_INITIAL_FREELANCER_TEAMS:-1}"
DOEY_MAX_WORKERS="${DOEY_MAX_WORKERS:-20}"
# Auth & Launch Timing
# Defaults are conservative to avoid Claude API rate-limit errors on session start.
# Lower only if your account has high rate limits and you need faster boots.
DOEY_WORKER_LAUNCH_DELAY="${DOEY_WORKER_LAUNCH_DELAY:-1}"
DOEY_TEAM_LAUNCH_DELAY="${DOEY_TEAM_LAUNCH_DELAY:-2}"
DOEY_MANAGER_LAUNCH_DELAY="${DOEY_MANAGER_LAUNCH_DELAY:-1}"
DOEY_MANAGER_BRIEF_DELAY="${DOEY_MANAGER_BRIEF_DELAY:-2}"

# Dynamic Grid Behavior
DOEY_IDLE_COLLAPSE_AFTER="${DOEY_IDLE_COLLAPSE_AFTER:-60}"
DOEY_IDLE_REMOVE_AFTER="${DOEY_IDLE_REMOVE_AFTER:-300}"
DOEY_PASTE_SETTLE_MS="${DOEY_PASTE_SETTLE_MS:-500}"

# Panel & Monitoring
DOEY_INFO_PANEL_REFRESH="${DOEY_INFO_PANEL_REFRESH:-300}"
# Models
DOEY_MANAGER_MODEL="${DOEY_MANAGER_MODEL:-opus}"
DOEY_WORKER_MODEL="${DOEY_WORKER_MODEL:-opus}"
DOEY_TASKMASTER_MODEL="${DOEY_TASKMASTER_MODEL:-opus}"

# Remote Access & Tunneling
DOEY_TUNNEL_ENABLED="${DOEY_TUNNEL_ENABLED:-false}"
DOEY_TUNNEL_PROVIDER="${DOEY_TUNNEL_PROVIDER:-auto}"
DOEY_TUNNEL_PORTS="${DOEY_TUNNEL_PORTS:-}"
DOEY_TUNNEL_DOMAIN="${DOEY_TUNNEL_DOMAIN:-}"

# Detect whether the current session is running remotely (SSH, container, etc.)
_detect_remote() {
  if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    echo "true"
  elif [ -f "/.dockerenv" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# Start tunnel if enabled and running remotely
_maybe_start_tunnel() {
  local runtime_dir="$1" is_remote="$2"
  [ "$DOEY_TUNNEL_ENABLED" = "true" ] && [ "$is_remote" = "true" ] || return 0
  local tunnel_script="${DOEY_DIR}/shell/doey-tunnel.sh"
  [ -f "$tunnel_script" ] && bash "$tunnel_script" "$runtime_dir" >> "${runtime_dir}/tunnel.log" 2>&1 &
}

# ── Helpers ───────────────────────────────────────────────────────────

# Read a key=value from an env file, stripping quotes.  Pure bash — no forks.
# Usage: _env_val <file> <KEY> [default]
_env_val() {
  local _ev_file="$1" _ev_key="$2" _ev_default="${3:-}" _ev_line
  if [ ! -f "$_ev_file" ]; then
    [ -n "$_ev_default" ] && printf '%s\n' "$_ev_default"
    return 0
  fi
  while IFS= read -r _ev_line || [ -n "$_ev_line" ]; do
    case "$_ev_line" in
      "${_ev_key}="*)
        _ev_line="${_ev_line#*=}"
        _ev_line="${_ev_line//\"/}"
        printf '%s\n' "$_ev_line"
        return 0
        ;;
    esac
  done < "$_ev_file"
  [ -n "$_ev_default" ] && printf '%s\n' "$_ev_default"
  return 0
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
  local safe="${pane_id//[-:.]/_}"
  cat > "${rt_dir}/status/${safe}.status" <<EOF
PANE: ${pane_id}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: ${status}
TASK: ${task}
EOF
}

project_name_from_dir() {
  local raw
  if [ -f "$1/.doey-name" ]; then raw=$(head -1 "$1/.doey-name"); else raw="${1##*/}"; fi
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
  local worker_panes="$4" worker_count="$5"
  local manager_pane="${6:-0}"
  local worktree_dir="${7:-}"
  local worktree_branch="${8:-}"
  local team_name="${9:-}"
  local team_role="${10:-}"
  local worker_model="${11:-}"
  local manager_model="${12:-}"
  local session_name
  session_name=$(_env_val "${runtime_dir}/session.env" SESSION_NAME)
  local team_type="${13:-}"
  local team_def="${14:-}"
  local _tmp="${runtime_dir}/team_${window_index}.env.tmp.$$"
  cat > "$_tmp" << TEAMEOF
WINDOW_INDEX="${window_index}"
GRID="${grid}"
MANAGER_PANE="${manager_pane}"
WORKER_PANES="${worker_panes}"
WORKER_COUNT="${worker_count}"
SESSION_NAME="${session_name}"
WORKTREE_DIR="${worktree_dir}"
WORKTREE_BRANCH="${worktree_branch}"
TEAM_NAME="${team_name}"
TEAM_ROLE="${team_role}"
WORKER_MODEL="${worker_model}"
MANAGER_MODEL="${manager_model}"
TEAM_TYPE="${team_type}"
TEAM_DEF="${team_def}"
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

# Search hierarchy for team definition file
# Returns path via _FTD_RESULT, empty if not found
_find_team_def() {
  local name="$1"
  _FTD_RESULT=""
  local fname="${name}.team.md"

  # 1. Project-level teams/ (repo-shipped definitions)
  if [ -f "teams/${fname}" ]; then
    _FTD_RESULT="teams/${fname}"; return 0
  fi
  # 2. Project-level .doey/teams/
  if [ -f ".doey/teams/${fname}" ]; then
    _FTD_RESULT=".doey/teams/${fname}"; return 0
  fi
  # 3. Installed premade teams
  if [ -f "$HOME/.local/share/doey/teams/${fname}" ]; then
    _FTD_RESULT="$HOME/.local/share/doey/teams/${fname}"; return 0
  fi
  # 4. Legacy user config
  if [ -f "$HOME/.config/doey/teams/${fname}" ]; then
    _FTD_RESULT="$HOME/.config/doey/teams/${fname}"; return 0
  fi
  # 5. Doey repo shipped defaults (for non-doey projects using doey)
  local repo_path=""
  [ -f "$HOME/.claude/doey/repo-path" ] && repo_path=$(<"$HOME/.claude/doey/repo-path")
  if [ -n "$repo_path" ] && [ -f "${repo_path}/teams/${fname}" ]; then
    _FTD_RESULT="${repo_path}/teams/${fname}"; return 0
  fi
  return 1
}

# Parse a .team.md file into a flat env file at ${runtime_dir}/teamdef_<name>.env
# Also extracts markdown body to ${runtime_dir}/teamdef_<name>_briefing.md
_parse_team_def() {
  local file="$1" runtime_dir="$2"
  local in_frontmatter=0 frontmatter_count=0 in_panes=0 in_workflow=0
  local name="" line_num=0 body_started=0
  local workflow_idx=0
  local env_file="" briefing_file=""

  # First pass: extract name from frontmatter
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      frontmatter_count=$((frontmatter_count + 1))
      [ "$frontmatter_count" -ge 2 ] && break
      continue
    fi
    if [ "$frontmatter_count" -eq 1 ]; then
      case "$line" in
        name:*) name=$(echo "$line" | sed 's/^name:[[:space:]]*//' | tr -d '"') ;;
      esac
    fi
  done < "$file"

  [ -z "$name" ] && { echo "ERROR: no name in team def $file" >&2; return 1; }
  env_file="${runtime_dir}/teamdef_${name}.env"
  briefing_file="${runtime_dir}/teamdef_${name}_briefing.md"

  # Reset for second pass
  frontmatter_count=0; in_panes=0; in_workflow=0; body_started=0; workflow_idx=0
  : > "$env_file"
  : > "$briefing_file"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      frontmatter_count=$((frontmatter_count + 1))
      if [ "$frontmatter_count" -ge 2 ]; then
        body_started=1
        continue
      fi
      continue
    fi

    # Markdown body (after second ---)
    if [ "$body_started" -eq 1 ]; then
      # Detect section headers in markdown body for table-format team defs
      case "$line" in
        "## Panes"*) in_panes=1; in_workflow=0; continue ;;
        "## Workflows"*) in_workflow=1; in_panes=0; continue ;;
        "## Team Briefing"*) in_panes=0; in_workflow=0; continue ;;
        "## "*) in_panes=0; in_workflow=0 ;;
      esac

      # Parse markdown pane table: | Pane | Role | Agent | Name | Model |
      if [ "$in_panes" -eq 1 ]; then
        case "$line" in
          "|"*)
            echo "$line" | grep -q '^|[[:space:]]*Pane' && continue
            echo "$line" | grep -q '^|[[:space:]]*-' && continue
            local _tp_pane _tp_role _tp_agent _tp_name _tp_model
            _tp_pane=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_role=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_agent=$(echo "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_name=$(echo "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_model=$(echo "$line" | cut -d'|' -f6 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_tp_pane" ] && continue
            [ -n "$_tp_role" ] && printf 'PANE_%s_ROLE=%s\n' "$_tp_pane" "$_tp_role" >> "$env_file"
            [ -n "$_tp_agent" ] && printf 'PANE_%s_AGENT=%s\n' "$_tp_pane" "$_tp_agent" >> "$env_file"
            [ -n "$_tp_name" ] && printf 'PANE_%s_NAME=%s\n' "$_tp_pane" "$_tp_name" >> "$env_file"
            [ -n "$_tp_model" ] && printf 'PANE_%s_MODEL=%s\n' "$_tp_pane" "$_tp_model" >> "$env_file"
            ;;
        esac
        continue
      fi

      # Parse markdown workflow table: | Trigger | From | To | Subject |
      if [ "$in_workflow" -eq 1 ]; then
        case "$line" in
          "|"*)
            echo "$line" | grep -q '^|[[:space:]]*Trigger' && continue
            echo "$line" | grep -q '^|[[:space:]]*-' && continue
            local _tw_trigger _tw_from _tw_to _tw_subject
            _tw_trigger=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tw_from=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tw_to=$(echo "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tw_subject=$(echo "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_tw_trigger" ] && continue
            printf 'WORKFLOW_%s=%s|%s|%s|%s\n' "$workflow_idx" "$_tw_trigger" "$_tw_from" "$_tw_to" "$_tw_subject" >> "$env_file"
            workflow_idx=$((workflow_idx + 1))
            ;;
        esac
        continue
      fi

      # Everything else in body goes to briefing file
      printf '%s\n' "$line" >> "$briefing_file"
      continue
    fi

    # Inside frontmatter
    if [ "$frontmatter_count" -eq 1 ]; then
      # Detect section starts
      case "$line" in
        "panes:") in_panes=1; in_workflow=0; continue ;;
        "workflow:") in_workflow=1; in_panes=0; continue ;;
      esac

      # Pane entries:  N: { role: X, agent: Y, name: "Z" }
      if [ "$in_panes" -eq 1 ]; then
        case "$line" in
          *"{"*"}"*)
            local pane_num role="" agent="" pane_name=""
            pane_num=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            role=$(echo "$line" | sed -n 's/.*role:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' ')
            agent=$(echo "$line" | sed -n 's/.*agent:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' ')
            pane_name=$(echo "$line" | sed -n 's/.*name:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$role" ] && printf 'PANE_%s_ROLE=%s\n' "$pane_num" "$role" >> "$env_file"
            [ -n "$agent" ] && printf 'PANE_%s_AGENT=%s\n' "$pane_num" "$agent" >> "$env_file"
            [ -n "$pane_name" ] && printf 'PANE_%s_NAME=%s\n' "$pane_num" "$pane_name" >> "$env_file"
            ;;
          *) [ -z "$(echo "$line" | tr -d '[:space:]')" ] || { in_panes=0; } ;;
        esac
        [ "$in_panes" -eq 1 ] && continue
      fi

      # Workflow entries:  - on: X, from: Y, to: Z, subject: W
      if [ "$in_workflow" -eq 1 ]; then
        case "$line" in
          *"- on:"*)
            local wf_on="" wf_from="" wf_to="" wf_subject=""
            wf_on=$(echo "$line" | sed -n 's/.*on:[[:space:]]*\([^,]*\).*/\1/p' | tr -d ' ')
            wf_from=$(echo "$line" | sed -n 's/.*from:[[:space:]]*\([^,]*\).*/\1/p' | tr -d ' ')
            wf_to=$(echo "$line" | sed -n 's/.*to:[[:space:]]*\([^,]*\).*/\1/p' | tr -d ' ')
            wf_subject=$(echo "$line" | sed -n 's/.*subject:[[:space:]]*\([^,}[:space:]]*\).*/\1/p')
            printf 'WORKFLOW_%s=%s|%s|%s|%s\n' "$workflow_idx" "$wf_on" "$wf_from" "$wf_to" "$wf_subject" >> "$env_file"
            workflow_idx=$((workflow_idx + 1))
            ;;
          *) [ -z "$(echo "$line" | tr -d '[:space:]')" ] || { in_workflow=0; } ;;
        esac
        [ "$in_workflow" -eq 1 ] && continue
      fi

      # Simple key: value lines
      case "$line" in
        *:*)
          local key val
          key=$(echo "$line" | cut -d: -f1 | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
          val=$(echo "$line" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '"')
          [ -n "$key" ] && [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$env_file"
          ;;
      esac
    fi
  done < "$file"

  printf 'BRIEFING_FILE=%s\n' "$briefing_file" >> "$env_file"
  echo "$env_file"
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
    tmux send-keys -t "$session:0.0" "clear && doey-tui '${runtime_dir}'" Enter
  else
    tmux send-keys -t "$session:0.0" "clear && info-panel.sh '${runtime_dir}'" Enter
  fi

  # Boss (pane 0.1)
  local _boss_cmd="claude --dangerously-skip-permissions --model ${DOEY_BOSS_MODEL:-$DOEY_TASKMASTER_MODEL} --name \"${DOEY_ROLE_BOSS}\" --agent ${DOEY_ROLE_FILE_BOSS}"
  _append_settings _boss_cmd "$runtime_dir"
  tmux send-keys -t "$session:0.1" "$_boss_cmd" Enter

  tmux rename-window -t "$session:0" "Dashboard"
  write_pane_status "$runtime_dir" "${session}:0.1" "READY"
}

# Create Core Team window (window 1): Taskmaster + specialists
# Panes: 1.0=Taskmaster, 1.1=Task Reviewer, 1.2=Deployment, 1.3=Doey Expert
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
       select-pane -t "$session:1.3" -T "Doey Expert"

  # Apply border theme (same as regular teams)
  _apply_team_border_theme "$session" "1"

  # Write Core Team env
  write_team_env "$runtime_dir" "1" "2x2" "1,2,3" "3" "0" "" "" \
                 "Core Team" "core" "" ""

  # Set TASKMASTER_PANE in session.env
  _set_session_env "$runtime_dir" "TASKMASTER_PANE" "1.0"

  # Launch Taskmaster in pane 1.0 via shared helper
  _launch_team_manager "$session" "$runtime_dir" "1" \
    "$DOEY_TASKMASTER_MODEL" "$DOEY_ROLE_FILE_COORDINATOR" \
    "$DOEY_ROLE_COORDINATOR" "${_proj} ${DOEY_ROLE_COORDINATOR}"

  # Brief Taskmaster about its Core Team window
  _brief_team "$session" "1" "1.1, 1.2, 1.3" "3" "2x2 grid" "" "Core Team" "core"

  # Launch specialist agents in panes 1.1-1.3
  local _spec_cmd

  # Task Reviewer (pane 1.1)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Task Reviewer\" --agent doey-task-reviewer"
  _append_settings _spec_cmd "$runtime_dir"
  tmux send-keys -t "${session}:1.1" "$_spec_cmd" Enter
  write_pane_status "$runtime_dir" "${session}:1.1" "READY"

  # Deployment (pane 1.2)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Deployment\" --agent doey-deployment"
  _append_settings _spec_cmd "$runtime_dir"
  tmux send-keys -t "${session}:1.2" "$_spec_cmd" Enter
  write_pane_status "$runtime_dir" "${session}:1.2" "READY"

  # Doey Expert (pane 1.3)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Doey Expert\" --agent doey-doey-expert"
  _append_settings _spec_cmd "$runtime_dir"
  tmux send-keys -t "${session}:1.3" "$_spec_cmd" Enter
  write_pane_status "$runtime_dir" "${session}:1.3" "READY"
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
list_projects() {
  doey_header "Doey — Projects"
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
    doey_info "(no projects registered)"
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
  # Stop doey-router
  if [ -f "$_rt/doey-router.pid" ]; then
    kill "$(cat "$_rt/doey-router.pid")" 2>/dev/null || true
    rm -f "$_rt/doey-router.pid"
  fi
  rm -rf "$_rt" 2>/dev/null || true
}

# Show interactive project picker menu
show_menu() {
  local grid="$1"

  doey_header "Doey"
  doey_warn "No project registered for $(pwd)"
  printf '\n'

  # Read projects into arrays
  local names paths statuses status_plain; names=() paths=() statuses=() status_plain=()
  while IFS=: read -r name path; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    paths+=("$path")
    if session_exists "doey-${name}"; then
      statuses+=("${SUCCESS}● running${RESET}")
      status_plain+=("running")
    else
      statuses+=("${DIM}○ stopped${RESET}")
      status_plain+=("stopped")
    fi
  done < "$PROJECTS_FILE"

  # Count running sessions for the kill-all option
  local running_count=0
  for i in "${!names[@]}"; do
    session_exists "doey-${names[$i]}" && running_count=$((running_count + 1))
  done

  if [[ ${#names[@]} -gt 0 ]]; then
    # ── Interactive picker (works with or without gum) ──
    local _cursor=0
    local _total=${#names[@]}
    local _msg=""
    local _old_tty_settings

    # Refresh status arrays (after kill/restart)
    _picker_refresh() {
      statuses=(); status_plain=()
      running_count=0
      for i in "${!names[@]}"; do
        if session_exists "doey-${names[$i]}"; then
          statuses+=("running")
          status_plain+=("running")
          running_count=$((running_count + 1))
        else
          statuses+=("stopped")
          status_plain+=("stopped")
        fi
      done
    }

    # Render the picker list
    _picker_render() {
      # Move to top of picker area and clear below
      printf '\033[%dA' $((_total + 4))  # move up past list + hints + msg + blank
      printf '\033[J'                     # clear from cursor to end

      local i
      for i in "${!names[@]}"; do
        local _sp="${paths[$i]/#$HOME/\~}"
        local _icon="○"
        [ "${status_plain[$i]}" = "running" ] && _icon="●"

        if [ "$i" -eq "$_cursor" ]; then
          # Focused: bold cyan with cursor
          printf '  \033[1;36m▸ %s %-18s\033[0;90m %s\033[0m\n' "$_icon" "${names[$i]}" "$_sp"
        else
          # Unfocused: dim
          printf '    \033[0;90m%s %-18s %s\033[0m\n' "$_icon" "${names[$i]}" "$_sp"
        fi
      done

      printf '\n'
      printf '  \033[0;90menter\033[0m open  \033[0;90m·\033[0m  \033[0;90mr\033[0m restart  \033[0;90m·\033[0m  \033[0;90mx\033[0m kill  \033[0;90m·\033[0m  \033[0;90mi\033[0m init  \033[0;90m·\033[0m  \033[0;90mq\033[0m quit\n'

      # Status message line (or blank)
      if [ -n "$_msg" ]; then
        printf '  %b\n' "$_msg"
      else
        printf '\n'
      fi
    }

    # Print initial blank lines to reserve space, then render
    local _line
    for _line in $(seq 1 $((_total + 4))); do
      printf '\n'
    done
    _picker_render

    # Save terminal state & hide cursor
    _old_tty_settings=$(stty -g 2>/dev/null || true)
    tput civis 2>/dev/null || true

    _picker_cleanup() {
      tput cnorm 2>/dev/null || true
      [ -n "$_old_tty_settings" ] && stty "$_old_tty_settings" 2>/dev/null || true
    }
    trap '_picker_cleanup' INT TERM EXIT

    # ── Input loop ──
    local _done=false
    while [ "$_done" = false ]; do
      _msg=""
      local _key
      IFS= read -rsn1 _key 2>/dev/null || true

      case "$_key" in
        # Enter key
        "")
          _picker_cleanup
          trap - INT TERM EXIT
          local _sel_name="${names[$_cursor]}"
          local _sel_path="${paths[$_cursor]}"
          local _sel_session="doey-${_sel_name}"
          if session_exists "$_sel_session"; then
            attach_or_switch "$_sel_session"
          else
            launch_with_grid "$_sel_name" "$_sel_path" "$grid"
          fi
          return 0
          ;;
        # Escape sequence (arrow keys)
        $'\033')
          local _seq
          IFS= read -rsn2 -t 0.1 _seq 2>/dev/null || true
          case "$_seq" in
            '[A') [ "$_cursor" -gt 0 ] && _cursor=$((_cursor - 1)) ;;   # Up
            '[B') [ "$_cursor" -lt $((_total - 1)) ] && _cursor=$((_cursor + 1)) ;; # Down
          esac
          ;;
        j|J) [ "$_cursor" -lt $((_total - 1)) ] && _cursor=$((_cursor + 1)) ;;
        k|K) [ "$_cursor" -gt 0 ] && _cursor=$((_cursor - 1)) ;;
        r|R)
          local _rname="${names[$_cursor]}"
          local _rpath="${paths[$_cursor]}"
          local _rsess="doey-${_rname}"
          if session_exists "$_rsess"; then
            _msg="${WARN}Restarting ${_rname}...${RESET}"
            _picker_render
            _kill_doey_session "$_rsess"
          fi
          _picker_cleanup
          trap - INT TERM EXIT
          launch_with_grid "$_rname" "$_rpath" "$grid"
          return 0
          ;;
        x|X|d|D)
          local _xname="${names[$_cursor]}"
          local _xsess="doey-${_xname}"
          if session_exists "$_xsess"; then
            _msg="${WARN}Killing ${_xname}...${RESET}"
            _picker_render
            _kill_doey_session "$_xsess"
            _picker_refresh
            _msg="${SUCCESS}Killed ${_xname}${RESET}"
          else
            _msg="${DIM}${_xname} is not running${RESET}"
          fi
          ;;
        i|I)
          _picker_cleanup
          trap - INT TERM EXIT
          register_project "$(pwd)"
          local init_name
          init_name="$(find_project "$(pwd)")"
          if [[ -n "$init_name" ]]; then
            launch_with_grid "$init_name" "$(pwd)" "$grid"
          fi
          return 0
          ;;
        q|Q)
          _done=true
          ;;
      esac

      [ "$_done" = false ] && _picker_render
    done

    _picker_cleanup
    trap - INT TERM EXIT
    return 0
  fi

  # ── Non-gum fallback (no projects registered) ──
  printf "  ${DIM}No projects registered.${RESET}\n\n"
  printf "  ${BOLD}i${RESET})  Init current directory as new project\n"
  printf "  ${BOLD}q${RESET})  Quit\n"
  printf '\n'

  read -rp "  > " choice
  case "$choice" in
    i|I|init)
      register_project "$(pwd)"
      local init_name
      init_name="$(find_project "$(pwd)")"
      if [[ -n "$init_name" ]]; then
        launch_with_grid "$init_name" "$(pwd)" "$grid"
      fi
      ;;
    q|Q) return 0 ;;
    *) doey_error "Invalid option"; return 1 ;;
  esac
}

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
_parse_auth_status() {
  _AUTH_JSON=$(claude auth status 2>&1) || _AUTH_JSON=""
  _AUTH_OK=false
  if echo "$_AUTH_JSON" | grep -q '"loggedIn": true'; then
    _AUTH_OK=true
    _AUTH_METHOD=$(echo "$_AUTH_JSON" | grep '"authMethod"' | sed 's/.*: *"//;s/".*//')
    _AUTH_EMAIL=$(echo "$_AUTH_JSON" | grep '"email"' | sed 's/.*: *"//;s/".*//')
    _AUTH_SUB=$(echo "$_AUTH_JSON" | grep '"subscriptionType"' | sed 's/.*: *"//;s/".*//')
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

# Print version update summary.
# Usage: _version_summary "old_ver" "new_ver"
_version_summary() {
  if [ "$1" != "$2" ]; then
    doey_ok "Updated: $1 → $2"
  else
    doey_ok "Version: $2 (already latest)"
  fi
}

# Verify doey installation via doctor --quiet.
_verify_install_step() {
  if bash "$HOME/.local/bin/doey" doctor --quiet 2>/dev/null; then
    doey_success "All checks pass"
  else
    doey_warn "Some doctor checks have warnings (run: doey doctor)"
  fi
}

# Build Go binaries during update flows.
# Usage: _update_go_build_step <source_dir>
_update_go_build_step() {
  local helpers_file="${1}/shell/doey-go-helpers.sh"
  if [ ! -f "$helpers_file" ]; then
    doey_info "Go helpers not found — skipped"
    return 0
  fi
  local go_rc=0
  _spin "Building Go binaries..." \
    bash -c "source '${helpers_file}' 2>/dev/null && _build_all_go_binaries" 2>/dev/null || go_rc=$?
  if [ "$go_rc" -eq 0 ]; then
    doey_success "Go binaries built"
  else
    doey_warn "Go build failed — doey-tui will use shell fallback"
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
             "$rt"/status/pane_hash_*; do
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
      *)          doey_error "Unknown purge flag: $1"; return 1 ;;
    esac
    shift
  done

  # Validate scope
  case "$scope" in
    runtime|context|hooks|all) ;;
    *) doey_error "Invalid scope: $scope (use: runtime, context, hooks, all)"; return 1 ;;
  esac

  # Resolve project
  local dir name session runtime_dir session_active
  dir="$(pwd)"
  PROJECT_DIR="$dir"
  name="$(find_project "$dir")"
  if [[ -z "$name" ]]; then
    doey_info "No project registered for $dir — nothing to purge"
    return 0
  fi

  session="doey-${name}"
  runtime_dir="/tmp/doey/${name}"
  session_active=false

  if session_exists "$session"; then
    session_active=true
    local tmux_rt
    tmux_rt="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null)" || true
    tmux_rt="${tmux_rt#*=}"
    [[ -n "$tmux_rt" ]] && runtime_dir="$tmux_rt"
  fi

  if [[ ! -d "$runtime_dir" ]]; then
    printf "  ${DIM}No runtime directory found — nothing to purge${RESET}\n"
    return 0
  fi

  # Header
  local state_label="stopped"; $session_active && state_label="active"
  printf '\n'
  doey_header "Doey — Purge  (session ${state_label})"

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
  else
    _purge_summary "$rt_files" "$rt_bytes" "$res_files" "$res_bytes" "$dry_run"
    if ! $dry_run; then
      local do_purge=true
      if ! $force; then
        doey_confirm "Found ${total_files} stale files ($(_purge_format_bytes "$((rt_bytes + res_bytes))")). Purge?" || do_purge=false
      fi
      if $do_purge; then
        _purge_execute "$list_file"
      else
        printf "  ${DIM}Cancelled${RESET}\n"
      fi
    fi
  fi

  _purge_write_report "$runtime_dir" "$name" "$session_active" "$dry_run" "$scope" \
    "$rt_files" "$rt_bytes" "$res_files" "$res_bytes"
}

check_claude_auth() {
  if ! command -v claude >/dev/null 2>&1; then
    doey_error "claude CLI not found"
    return 1
  fi
  _parse_auth_status
  if [ "$_AUTH_OK" = true ]; then
    doey_success "Authenticated (${_AUTH_METHOD} · ${_AUTH_EMAIL} · ${_AUTH_SUB})"
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
  local runtime_dir="/tmp/doey/${name}"
  local team_window=2

  cd "$dir"
  _doey_load_config  # Reload config now that we're in the project dir

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
PASTE_SETTLE_MS="500"
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

  _build_worker_pane_list "$session" "$team_window"
  _brief_team "$session" "$team_window" "" "$_WPL_RESULT" "$worker_count" "Grid ${grid}"

  (
    sleep "$DOEY_MANAGER_BRIEF_DELAY"
    # Boss briefing (pane 0.1)
    tmux send-keys -t "$session:0.1" \
      "Session online. You are ${DOEY_ROLE_BOSS}. Project: ${name}, dir: ${dir}, session: ${session}. ${DOEY_ROLE_COORDINATOR} is in the Core Team window. Team window ${team_window} has ${worker_count} workers. Awaiting instructions." Enter
    # Taskmaster briefing (Core Team pane 1.0)
    local _tm_pane
    _tm_pane=$(grep '^TASKMASTER_PANE=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    _tm_pane="${_tm_pane:-1.0}"
    tmux send-keys -t "$session:${_tm_pane}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. You are ${DOEY_ROLE_COORDINATOR} at pane ${_tm_pane} in Core Team window. Worker team windows: ${team_window}. Awaiting ${DOEY_ROLE_BOSS} instructions." Enter
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

  doey_banner
  doey_info "Project ${name}  Grid ${grid}  Workers ${worker_count}"
  doey_info "Dir ${short_dir}  Session ${session}"
  printf '\n'

  ensure_project_trusted "$dir"

  _launch_session_core "$name" "$dir" "$grid" 0

  printf '\n'
  if [ "$HAS_GUM" = true ]; then
    printf '%s\n' "$(gum style --foreground 2 --bold '✓ Doey is ready')"
    gum style --border rounded --border-foreground 6 --padding "1 2" --margin "0 1" \
      "$(gum style --foreground 6 --bold 'Project')  ${name}   $(gum style --foreground 6 --bold 'Grid')  ${grid}   $(gum style --foreground 6 --bold 'Workers')  ${worker_count}" \
      "$(gum style --foreground 6 --bold 'Session')  ${session}" \
      "$(gum style --foreground 6 --bold 'Dir')      ${short_dir}" \
      "" \
      "$(gum style --foreground 240 'Tip: Workers ready in ~15s')"
  else
    doey_success "Doey is ready"
    doey_info "Project ${name}  Grid ${grid}  Workers ${worker_count}"
    doey_info "Session ${session}  Dir ${short_dir}"
    doey_info "Manager 1.0  Dashboard win 0"
    doey_info "Tip: Workers ready in ~15s"
  fi
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
  # Stop doey-router
  if [ -f "$runtime_dir/doey-router.pid" ]; then
    kill "$(cat "$runtime_dir/doey-router.pid")" 2>/dev/null || true
    rm -f "$runtime_dir/doey-router.pid"
  fi
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
  mkdir -p "${runtime_dir}"/{messages,broadcasts,status,logs}
  : > "${runtime_dir}/logs/doey-router.log" 2>/dev/null
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
  sleep 0.5
  for (( attempt=0; attempt<max; attempt++ )); do
    child=$(pgrep -P "$shell_pid" 2>/dev/null || true)
    [ -z "$child" ] && return 0
    kill -9 "$child" 2>/dev/null || true
    sleep 0.1
  done
  return 0
}

# Print a doctor-style check line.
# Doctor counters — reset before each run, read after
_DOC_OK=0 _DOC_WARN=0 _DOC_FAIL=0 _DOC_SKIP=0

# Usage: _doc_check ok|warn|fail|skip "label" ["detail"]
_doc_check() {
  local level="$1" label="$2" detail="${3:-}"
  case "$level" in
    ok)   _DOC_OK=$((_DOC_OK + 1)) ;;
    warn) _DOC_WARN=$((_DOC_WARN + 1)) ;;
    fail) _DOC_FAIL=$((_DOC_FAIL + 1)) ;;
    skip) _DOC_SKIP=$((_DOC_SKIP + 1)) ;;
  esac
  if [ "$HAS_GUM" = true ]; then
    local icon color
    case "$level" in
      ok)   icon="✓"; color="2" ;;
      warn) icon="⚠"; color="3" ;;
      fail) icon="✗"; color="1" ;;
      skip) icon="–"; color="8" ;;
    esac
    printf '  %s %-22s %s\n' \
      "$(gum style --foreground "$color" "$icon")" \
      "$label" \
      "$([ -n "$detail" ] && gum style --foreground 240 "$detail")"
  else
    case "$level" in
      ok)   printf "  ${SUCCESS}✓${RESET} %-22s" "$label" ;;
      warn) printf "  ${WARN}⚠${RESET} %-22s" "$label" ;;
      fail) printf "  ${ERROR}✗${RESET} %-22s" "$label" ;;
      skip) printf "  ${DIM}–${RESET} %-22s" "$label" ;;
    esac
    [ -n "$detail" ] && printf " ${DIM}%s${RESET}" "$detail"
    printf '\n'
  fi
}

# ── Task Management (schema v3, .doey/tasks/) ────────────────────────
# Delegates to doey-task-helpers.sh for core CRUD operations.

_task_helpers_sourced=0
_task_source_helpers() {
  [ "$_task_helpers_sourced" -eq 1 ] && return 0
  local _helpers_path
  _helpers_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doey-task-helpers.sh"
  if [ -f "$_helpers_path" ]; then
    # shellcheck source=doey-task-helpers.sh
    source "$_helpers_path"
    _task_helpers_sourced=1
    return 0
  fi
  printf '  %s✗ Task helpers not found: %s%s\n' "$ERROR" "$_helpers_path" "$RESET" >&2
  return 1
}

# Thin wrappers — delegate to doey-task-helpers.sh while preserving
# the existing interface (callers pass task file paths, not project dirs).

_task_read() {
  _task_source_helpers || return 1
  local _file="$1"
  [ -s "$_file" ] || return 1
  TASK_ATTACHMENTS=""  # legacy field not in helpers
  task_read "$_file"
  # Also read TASK_ATTACHMENTS (legacy, not in helpers schema)
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "${_line%%=*}" in
      TASK_ATTACHMENTS) TASK_ATTACHMENTS="${_line#*=}" ;;
    esac
  done < "$_file" || true
  [ -n "${TASK_ID:-}" ] || return 1
}

_task_age() {
  _task_source_helpers || { printf '?'; return; }
  _task_age_str "$1"
}

_task_create() {
  _task_source_helpers || return 1
  local _tasks_dir="$1" _title="$2"
  local _description="${3:-}" _attachments="${4:-}"
  # Derive project dir from tasks dir (strip /.doey/tasks or /tasks suffix)
  local _proj_dir="${_tasks_dir%/.doey/tasks}"
  [ "$_proj_dir" = "$_tasks_dir" ] && _proj_dir="${_tasks_dir%/tasks}"
  local _id
  _id="$(task_create "$_proj_dir" "$_title" "feature" "user" "$_description")"
  # Append legacy TASK_ATTACHMENTS if provided (not in helpers schema)
  if [ -n "$_attachments" ]; then
    task_update_field "${_tasks_dir}/${_id}.task" "TASK_ATTACHMENTS" "$_attachments"
  fi
  echo "$_id"
}

_task_set_field() {
  _task_source_helpers || return 1
  task_update_field "$1" "$2" "$3"
}

_task_set_description() {
  local _file="${1}/${2}.task"
  [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$2" "$RESET"; return 1; }
  _task_set_field "$_file" "TASK_DESCRIPTION" "$3"
}

_task_add_attachment() {
  _task_source_helpers || return 1
  local _tasks_dir="$1" _id="$2" _attachment="$3"
  local _file="${_tasks_dir}/${_id}.task"
  [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$_id" "$RESET"; return 1; }
  _task_append_to_field "$_file" "TASK_ATTACHMENTS" "$_attachment" "|"
}

_task_set_status() {
  _task_source_helpers || return 1
  local _tasks_dir="$1" _id="$2" _new_status="$3"
  local _file="${_tasks_dir}/${_id}.task"
  [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$_id" "$RESET"; return 1; }
  # "failed" is a CLI-only status not in helpers — handle directly
  case "$_new_status" in
    failed)
      task_update_field "$_file" "TASK_STATUS" "failed"
      local _now; _now=$(date +%s)
      _task_append_to_field "$_file" "TASK_TIMESTAMPS" "failed=${_now}" "|"
      return 0
      ;;
    draft|active|in_progress|paused|blocked|pending_user_confirmation|done|cancelled) ;;
    *) printf '  %s✗ Invalid status: %s%s\n' "$ERROR" "$_new_status" "$RESET"; return 1 ;;
  esac
  # Derive project dir for helpers API
  local _proj_dir="${_tasks_dir%/.doey/tasks}"
  [ "$_proj_dir" = "$_tasks_dir" ] && _proj_dir="${_tasks_dir%/tasks}"
  task_update_status "$_proj_dir" "$_id" "$_new_status"
}

# Walk up from cwd to find the project directory (contains .doey/)
_task_find_project_dir() {
  local _search_dir
  _search_dir="$(pwd)"
  while [ "$_search_dir" != "/" ]; do
    if [ -d "${_search_dir}/.doey" ]; then
      echo "$_search_dir"
      return 0
    fi
    _search_dir="$(dirname "$_search_dir")"
  done
  return 1
}

# Return the persistent task directory (.doey/tasks/), auto-creating it
_task_persistent_dir() {
  local _proj_dir
  _proj_dir="$(_task_find_project_dir 2>/dev/null)" || true
  if [ -n "$_proj_dir" ]; then
    mkdir -p "${_proj_dir}/.doey/tasks"
    echo "${_proj_dir}/.doey/tasks"
    return 0
  fi
  # Fallback: use RUNTIME_DIR if no .doey/ found (e.g. unregistered project)
  local _dir _name _session _runtime
  _dir="$(pwd)"
  _name="$(find_project "$_dir" 2>/dev/null)"
  [ -z "$_name" ] && { printf '  %s✗ No doey project for %s%s\n' "$ERROR" "$_dir" "$RESET" >&2; return 1; }
  _session="doey-${_name}"
  _runtime=$(tmux show-environment -t "$_session" DOEY_RUNTIME 2>/dev/null) || true
  _runtime="${_runtime#*=}"
  [ -z "$_runtime" ] && { printf '  %s✗ Session not running: %s%s\n' "$ERROR" "$_session" "$RESET" >&2; return 1; }
  mkdir -p "${_runtime}/tasks"
  echo "${_runtime}/tasks"
}

# Get runtime dir for syncing (may fail silently if no session running)
_task_runtime_dir() {
  local _dir _name _session _runtime
  _dir="$(pwd)"
  _name="$(find_project "$_dir" 2>/dev/null)" || true
  [ -z "$_name" ] && return 1
  _session="doey-${_name}"
  _runtime=$(tmux show-environment -t "$_session" DOEY_RUNTIME 2>/dev/null) || true
  _runtime="${_runtime#*=}"
  [ -z "$_runtime" ] && return 1
  echo "$_runtime"
}

# Sync .task files and .next_id from persistent dir to runtime cache
_task_sync_to_runtime() {
  local _src="$1" _dst="$2"
  [ -d "$_src" ] || return 0
  mkdir -p "$_dst"
  # Copy .next_id
  [ -f "$_src/.next_id" ] && cp "$_src/.next_id" "$_dst/.next_id"
  # Copy all .task files (including terminal — TUI may want history)
  local _f
  for _f in "$_src"/*.task; do
    [ -f "$_f" ] || continue
    [ -s "$_f" ] || continue  # skip empty files
    cp "$_f" "$_dst/$(basename "$_f")"
  done
}

# Print a task field if non-empty
_tsf() { [ -n "$2" ] && printf '  %b%-16s%b %s\n' "$BOLD" "$1" "$RESET" "$2"; }

_task_show() {
  local _file="$1"
  [ -f "$_file" ] || { printf '  %s✗ Task file not found%s\n' "$ERROR" "$RESET"; return 1; }
  _task_read "$_file"
  local _age=""
  [ -n "$TASK_CREATED" ] && _age="$(_task_age "$TASK_CREATED")"
  printf '\n'
  printf '  %b━━━ Task #%s ━━━%b\n' "$BRAND" "$TASK_ID" "$RESET"
  printf '  %b%-16s%b %s\n' "$BOLD" "Title:" "$RESET" "$TASK_TITLE"
  printf '  %b%-16s%b %s\n' "$BOLD" "Status:" "$RESET" "$TASK_STATUS"
  _tsf "Type:" "$TASK_TYPE"
  _tsf "Tags:" "$TASK_TAGS"
  _tsf "Created by:" "$TASK_CREATED_BY"
  _tsf "Assigned to:" "$TASK_ASSIGNED_TO"
  [ -n "$_age" ] && printf '  %b%-16s%b %s ago\n' "$BOLD" "Age:" "$RESET" "$_age"
  _tsf "Description:" "$TASK_DESCRIPTION"
  _tsf "Acceptance:" "$TASK_ACCEPTANCE_CRITERIA"
  _tsf "Hypotheses:" "$TASK_HYPOTHESES"
  _tsf "Decisions:" "$TASK_DECISION_LOG"
  _tsf "Subtasks:" "$TASK_SUBTASKS"
  _tsf "Related files:" "$TASK_RELATED_FILES"
  _tsf "Blockers:" "$TASK_BLOCKERS"
  _tsf "Attachments:" "$TASK_ATTACHMENTS"
  _tsf "Timestamps:" "$TASK_TIMESTAMPS"
  _tsf "Notes:" "$TASK_NOTES"
  printf '  %b%-16s%b v%s\n' "$DIM" "Schema:" "$RESET" "${TASK_SCHEMA_VERSION:-1}"
  printf '\n'
}

task_command() {
  local _tasks_dir _runtime_cache _subcmd="${1:-list}"
  shift 2>/dev/null || true

  _tasks_dir="$(_task_persistent_dir)" || exit 1
  mkdir -p "$_tasks_dir"
  # Runtime cache for TUI sync (best-effort, may not exist if session is down)
  _runtime_cache=""
  local _rt
  _rt="$(_task_runtime_dir 2>/dev/null)" && _runtime_cache="${_rt}/tasks"

  case "$_subcmd" in
    list|ls|"")
      doey_header "Doey Tasks"
      printf '\n'
      local _count=0
      for _f in "${_tasks_dir}"/*.task; do
        [ -f "$_f" ] || continue
        [ -s "$_f" ] || continue  # skip empty files
        local TASK_ID TASK_TITLE TASK_STATUS TASK_CREATED TASK_TYPE
        local TASK_TAGS TASK_CREATED_BY TASK_ASSIGNED_TO TASK_DESCRIPTION
        local TASK_ATTACHMENTS TASK_ACCEPTANCE_CRITERIA TASK_HYPOTHESES
        local TASK_DECISION_LOG TASK_SUBTASKS TASK_RELATED_FILES
        local TASK_BLOCKERS TASK_TIMESTAMPS TASK_NOTES TASK_SCHEMA_VERSION
        _task_read "$_f" || continue  # skip malformed files
        [ "$TASK_STATUS" = "done" ] && continue
        [ "$TASK_STATUS" = "cancelled" ] && continue
        local _col _age
        case "$TASK_STATUS" in
          in_progress)                _col="$SUCCESS" ;;
          pending_user_confirmation)  _col="$WARN" ;;
          active)                     _col="$BOLD" ;;
          blocked)                    _col="$ERROR" ;;
          *)                          _col="$DIM" ;;
        esac
        _age="$(_task_age "$TASK_CREATED")"
        local _type_tag=""
        [ -n "$TASK_TYPE" ] && [ "$TASK_TYPE" != "feature" ] && _type_tag=" [${TASK_TYPE}]"
        printf '  %b[%s]%b  %b%-30s%b  %b%s%b%s  %s ago\n' \
          "$BOLD" "$TASK_ID" "$RESET" \
          "$_col" "$TASK_STATUS" "$RESET" \
          "$BOLD" "$TASK_TITLE" "$RESET" \
          "$_type_tag" \
          "$_age"
        _count=$((_count + 1))
      done
      if [ "$_count" -eq 0 ]; then
        printf '  %bNo active tasks.%b\n' "$DIM" "$RESET"
        printf '  %bAdd: doey task add "your goal"%b\n' "$DIM" "$RESET"
      else
        printf '\n  %bLifecycle: draft → active → in_progress → pending_user_confirmation → done%b\n' "$DIM" "$RESET"
      fi
      printf '\n'
      ;;

    add)
      local _title="" _desc="" _attach=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --description) shift; _desc="${1:-}"; shift ;;
          --attach)      shift; _attach="${1:-}"; shift ;;
          *)             if [ -n "$_title" ]; then _title="$_title $1"; else _title="$1"; fi; shift ;;
        esac
      done
      [ -z "$_title" ] && { printf '  Usage: doey task add "Your task title" [--description "text"] [--attach "url"]\n'; exit 1; }
      local _id
      _id="$(_task_create "$_tasks_dir" "$_title" "$_desc" "$_attach")"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '\n  %s[%s]%s Task created: %s%s%s\n\n' \
        "$SUCCESS" "$_id" "$RESET" "$BOLD" "$_title" "$RESET"
      ;;

    show)
      local _id="${1:-}"
      [ -z "$_id" ] && { printf '  Usage: doey task show <id>\n'; exit 1; }
      local _file="${_tasks_dir}/${_id}.task"
      [ -f "$_file" ] || { printf '  %s✗ Task %s not found%s\n' "$ERROR" "$_id" "$RESET"; exit 1; }
      _task_show "$_file"
      ;;

    ready|activate|start|pause|block|confirm|pending|done|failed|cancel)
      local _id="${1:-}"
      [ -z "$_id" ] && { printf '  Usage: doey task %s <id>\n' "$_subcmd"; exit 1; }
      local _ts_status _ts_icon _ts_color
      case "$_subcmd" in
        ready|activate)  _ts_status="active";                     _ts_icon="✓"; _ts_color="$SUCCESS" ;;
        start)           _ts_status="in_progress";                _ts_icon="●"; _ts_color="$SUCCESS" ;;
        pause)           _ts_status="paused";                     _ts_icon="⏸"; _ts_color="$WARN" ;;
        block)           _ts_status="blocked";                    _ts_icon="⊘"; _ts_color="$ERROR" ;;
        confirm|pending) _ts_status="pending_user_confirmation";  _ts_icon="✓"; _ts_color="$WARN" ;;
        done)            _ts_status="done";                       _ts_icon="✓"; _ts_color="$SUCCESS" ;;
        failed)          _ts_status="failed";                     _ts_icon="✗"; _ts_color="$ERROR" ;;
        cancel)          _ts_status="cancelled";                  _ts_icon="—"; _ts_color="$DIM" ;;
      esac
      _task_set_status "$_tasks_dir" "$_id" "$_ts_status"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '  %s%s Task [%s] %s.%s\n' "$_ts_color" "$_ts_icon" "$_id" "$_ts_status" "$RESET"
      ;;

    describe)
      local _id="${1:-}" _desc="${2:-}"
      [ -z "$_id" ] || [ -z "$_desc" ] && { printf '  Usage: doey task describe <id> "description text"\n'; exit 1; }
      _task_set_description "$_tasks_dir" "$_id" "$_desc"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '  %s✓ Task [%s] description updated.%s\n' "$SUCCESS" "$_id" "$RESET"
      ;;

    attach)
      local _id="${1:-}" _attachment="${2:-}"
      [ -z "$_id" ] || [ -z "$_attachment" ] && { printf '  Usage: doey task attach <id> "url_or_path"\n'; exit 1; }
      _task_add_attachment "$_tasks_dir" "$_id" "$_attachment"
      [ -n "$_runtime_cache" ] && _task_sync_to_runtime "$_tasks_dir" "$_runtime_cache"
      printf '  %s✓ Attachment added to task [%s].%s\n' "$SUCCESS" "$_id" "$RESET"
      ;;

    *)
      printf '  Usage: doey task [list|add|show|ready|start|pause|block|confirm|pending|done|failed|cancel|describe|attach]\n'
      ;;
  esac
}

# ── Update / Reinstall ───────────────────────────────────────────────
# Read current doey version hash from the version file or git.
_doey_current_version() {
  local vf="$HOME/.claude/doey/version"
  if [[ -f "$vf" ]]; then
    _env_val "$vf" version
  else
    local rp
    rp="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
    [[ -d "${rp:-}/.git" ]] && git -C "$rp" rev-parse --short HEAD 2>/dev/null || echo "unknown"
  fi
}

# ── Update: contributor path (local git repo) ──────────────────────
_update_contributor() {
  local repo_dir="$1"
  local old_hash
  old_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  doey_header "Updating Doey (Developer Mode)"
  printf '\n'
  doey_info "Source     ${repo_dir}"
  doey_info "Current    ${old_hash}"
  printf '\n'

  # Step 1: Check working tree
  doey_step "1/6" "Checking working tree..."
  local current_branch dirty=false stashed=false
  current_branch=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ -z "$current_branch" ]]; then
    doey_warn "Detached HEAD — checking out main"
    git -C "$repo_dir" checkout main 2>/dev/null || \
      git -C "$repo_dir" checkout -b main origin/main 2>/dev/null || true
  elif [[ "$current_branch" != "main" ]]; then
    doey_warn "On branch '$current_branch' — switching to main"
    git -C "$repo_dir" checkout main 2>/dev/null || true
  fi
  # Check for tracked-file changes only (untracked files don't block pull --ff-only)
  if ! git -C "$repo_dir" diff --quiet HEAD 2>/dev/null || \
     ! git -C "$repo_dir" diff --cached --quiet HEAD 2>/dev/null; then
    dirty=true
    if [ -t 0 ] && doey_confirm "You have uncommitted changes. Stash and continue?"; then
      git -C "$repo_dir" stash --quiet 2>/dev/null || true
      stashed=true
      doey_ok "Changes stashed"
    elif [ ! -t 0 ]; then
      # Non-interactive: auto-stash (matches pre-Task-74 behavior)
      git -C "$repo_dir" stash --quiet 2>/dev/null || true
      stashed=true
      doey_ok "Changes auto-stashed (non-interactive)"
    else
      doey_info "Update cancelled"
      return 0
    fi
  else
    doey_success "Working tree clean"
  fi

  # Step 2: Pull latest
  doey_step "2/6" "Pulling latest from origin/main..."
  local pull_rc=0
  git -C "$repo_dir" fetch origin main --quiet 2>/dev/null || true
  _spin "Pulling latest..." \
    git -C "$repo_dir" pull --ff-only origin main || pull_rc=$?
  if [ $pull_rc -ne 0 ]; then
    doey_error "git pull --ff-only failed"
    doey_info "This usually means local commits diverge from origin/main."
    doey_info "Resolve manually: cd $repo_dir && git pull --rebase origin main"
    [ "$stashed" = true ] && doey_info "Your stashed changes: git stash pop"
    return 1
  fi
  local new_hash
  new_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  if [[ "$old_hash" == "$new_hash" ]]; then
    doey_ok "Already up to date ($old_hash)"
  else
    doey_ok "Pulled $old_hash → $new_hash"
    # Code on disk changed — re-exec so steps 3-6 run from the NEW source.
    doey_info "Re-executing from updated source..."
    exec bash "$repo_dir/shell/doey.sh" --post-update "$repo_dir"
  fi

  # Step 3: Run install
  doey_step "3/6" "Running install..."
  if ! _spin "Installing files..." bash "$repo_dir/install.sh"; then
    doey_error "Install failed"
    doey_info "Try manually: cd $repo_dir && ./install.sh"
    return 1
  fi
  doey_success "Files installed"

  # Step 4: Rebuild Go binaries
  doey_step "4/6" "Rebuilding Go binaries..."
  _update_go_build_step "$repo_dir"

  # Step 5: Verify installation
  doey_step "5/6" "Verifying installation..."
  _verify_install_step

  # Step 6: Version comparison
  doey_step "6/6" "Version summary"
  local final_hash
  final_hash=$(_doey_current_version)
  printf '\n'
  _version_summary "$old_hash" "$final_hash"
  [ "$stashed" = true ] && doey_info "Stashed changes preserved — restore with: cd $repo_dir && git stash pop"

  _update_finish_banner
}

# ── Update: normal user path (download + install) ──────────────────
_update_normal() {
  local repo_dir="${1:-}"
  local old_version
  old_version=$(_doey_current_version)

  doey_header "Updating Doey"
  printf '\n'
  doey_info "Current version: ${old_version}"
  printf '\n'

  # Step 1: Download latest
  doey_step "1/5" "Downloading latest release..."
  local install_dir
  install_dir=$(mktemp -d "${TMPDIR:-/tmp}/doey-update.XXXXXX")
  local clone_rc=0
  _spin "Cloning latest release..." \
    git clone --depth 1 "https://github.com/FRIKKern/doey.git" "$install_dir" 2>/dev/null || clone_rc=$?
  if [ $clone_rc -ne 0 ]; then
    doey_error "Download failed — check your internet connection"
    rm -rf "$install_dir"
    return 1
  fi
  doey_success "Downloaded"

  # Step 2: Run install
  doey_step "2/5" "Running install..."
  if ! _spin "Installing files..." bash "$install_dir/install.sh"; then
    doey_error "Install failed"
    doey_info "Try downloading again: curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash"
    rm -rf "$install_dir"
    return 1
  fi
  doey_success "Installed"

  # Step 3: Rebuild Go binaries
  doey_step "3/5" "Rebuilding Go binaries..."
  _update_go_build_step "$install_dir"

  # Step 4: Verify installation
  doey_step "4/5" "Verifying installation..."
  _verify_install_step

  # Step 5: Version comparison
  doey_step "5/5" "Version summary"
  local new_version
  new_version=$(_doey_current_version)
  printf '\n'
  _version_summary "$old_version" "$new_version"

  rm -rf "$install_dir"
  _update_finish_banner
}

update_system() {
  local repo_dir
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"

  # Detect contributor: has a .git repo for the doey source
  if [[ -n "$repo_dir" ]] && [[ -d "$repo_dir/.git" ]]; then
    _update_contributor "$repo_dir"
  else
    _update_normal "$repo_dir"
  fi
}

_update_finish_banner() {
  rm -f "$HOME/.claude/doey/last-update-check.available"
  _check_claude_update

  # Install gum if missing (best-effort, don't fail update)
  if ! command -v gum >/dev/null 2>&1; then
    # Check known dirs and symlink if found
    local _gum_found=false
    for _d in "$HOME/go/bin" "$HOME/.local/go/bin"; do
      if [ -x "$_d/gum" ]; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$_d/gum" "$HOME/.local/bin/gum" 2>/dev/null || true
        _gum_found=true; HAS_GUM=true; break
      fi
    done
    if [ "$_gum_found" = false ]; then
      # Discover Go binary via shared helper (may not be on PATH)
      local _go_bin=""
      local _script_dir
      _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      if [ -f "$_script_dir/doey-go-helpers.sh" ]; then
        source "$_script_dir/doey-go-helpers.sh" 2>/dev/null || true
        _go_bin="$(_find_go_bin 2>/dev/null)" || _go_bin=""
      fi
      if [ -z "$_go_bin" ]; then
        command -v go >/dev/null 2>&1 && _go_bin="go"
        for _d in /usr/local/go/bin /snap/go/current/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
          [ -x "$_d/go" ] && _go_bin="$_d/go" && break
        done
      fi
      if [ -n "$_go_bin" ]; then
        doey_step "+" "Installing gum for luxury CLI..."
        if "$_go_bin" install github.com/charmbracelet/gum@latest 2>&1; then
          local _gopath
          _gopath="$("$_go_bin" env GOPATH 2>/dev/null)" || _gopath="$HOME/go"
          for _d in "$_gopath/bin" "$HOME/go/bin"; do
            if [ -x "$_d/gum" ]; then
              mkdir -p "$HOME/.local/bin"
              ln -sf "$_d/gum" "$HOME/.local/bin/gum" 2>/dev/null || true
              HAS_GUM=true; break
            fi
          done
          [ "$HAS_GUM" = true ] && doey_ok "gum installed" || doey_warn "gum installed but not on PATH"
        else
          doey_warn "gum install failed (optional)"
        fi
      fi
    fi
  fi

  printf '\n'
  doey_divider
  printf '\n'
  doey_banner
  doey_success "Update complete — restart sessions with: doey reload"
}

# Called via re-exec after git pull — runs from the NEW code on disk.
_post_update() {
  local install_dir="${1:-}"
  if [[ -z "$install_dir" ]] || [[ ! -d "$install_dir" ]]; then
    doey_error "--post-update: missing or invalid install dir"
    exit 1
  fi

  local old_version
  old_version=$(_doey_current_version)

  doey_header "Completing Update..."
  printf '\n'

  doey_step "1/4" "Running install from updated code..."
  if ! _spin "Installing..." bash "$install_dir/install.sh"; then
    doey_error "Install failed"
    [[ "$install_dir" == /tmp/* ]] && rm -rf "$install_dir"
    exit 1
  fi
  doey_success "Installed"

  doey_step "2/4" "Rebuilding Go binaries..."
  _update_go_build_step "$install_dir"

  [[ "$install_dir" == /tmp/* ]] && rm -rf "$install_dir"

  doey_step "3/4" "Verifying installation..."
  _verify_install_step

  doey_step "4/4" "Version summary"
  local new_version
  new_version=$(_doey_current_version)
  printf '\n'
  _version_summary "$old_version" "$new_version"

  _update_finish_banner
}

# Detect how Claude Code was installed and return the package manager name.
# Returns: brew, apt, snap, npm, or "unknown"
_claude_install_method() {
  # Standalone install: symlink in ~/.local/bin pointing to ~/.local/share/claude/
  # Must check first — other methods (npm) may also be present but not the active binary
  local claude_bin
  claude_bin="$(command -v claude 2>/dev/null)" || true
  if [ -n "$claude_bin" ] && [ -L "$claude_bin" ]; then
    local link_target
    link_target="$(readlink "$claude_bin" 2>/dev/null)" || true
    case "$link_target" in
      */.local/share/claude/*) echo "standalone"; return 0 ;;
    esac
  fi
  # macOS: check Homebrew
  if command -v brew >/dev/null 2>&1; then
    if brew list --formula 2>/dev/null | grep -q '^claude$' || \
       brew list --cask 2>/dev/null | grep -q '^claude$'; then
      echo "brew"; return 0
    fi
  fi
  # Linux: check snap
  if command -v snap >/dev/null 2>&1; then
    if snap list claude 2>/dev/null | grep -q 'claude'; then
      echo "snap"; return 0
    fi
  fi
  # Linux: check apt/dpkg
  if command -v dpkg >/dev/null 2>&1; then
    if dpkg -l claude 2>/dev/null | grep -q '^ii'; then
      echo "apt"; return 0
    fi
  fi
  # Fallback: npm (check if installed globally via npm)
  if command -v npm >/dev/null 2>&1; then
    if npm list -g @anthropic-ai/claude-code 2>/dev/null | grep -q 'claude-code'; then
      echo "npm"; return 0
    fi
  fi
  echo "unknown"
}

# Install Claude Code using the best available method for this platform.
_claude_install() {
  local method="$1"
  case "$method" in
    brew)
      printf "  ${DIM}brew install claude${RESET}\n"
      brew install claude 2>&1 | tail -3
      ;;
    snap)
      printf "  ${DIM}snap install claude${RESET}\n"
      sudo snap install claude 2>&1 | tail -3
      ;;
    apt)
      printf "  ${DIM}apt install claude${RESET}\n"
      sudo apt-get install -y claude 2>&1 | tail -3
      ;;
    npm)
      printf "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}\n"
      npm install -g @anthropic-ai/claude-code 2>&1 | tail -3
      ;;
    *)
      # Pick best native option and recurse
      local _best=""
      case "$(uname -s)" in
        Darwin) command -v brew >/dev/null 2>&1 && _best="brew" ;;
        Linux)  command -v snap >/dev/null 2>&1 && _best="snap" || \
                { command -v apt-get >/dev/null 2>&1 && _best="apt"; } ;;
      esac
      [ -z "$_best" ] && command -v npm >/dev/null 2>&1 && _best="npm"
      [ -z "$_best" ] && return 1
      _claude_install "$_best"
      ;;
  esac
}

# Upgrade Claude Code using the same method it was installed with.
# Args: $1=method, $2=target_version (optional, used for npm to avoid cache)
_claude_upgrade() {
  local method="$1" target_ver="${2:-}"
  case "$method" in
    standalone)
      printf "  ${DIM}claude update${RESET}\n"
      claude update 2>&1 | tail -5
      ;;
    brew)
      printf "  ${DIM}brew upgrade claude${RESET}\n"
      brew upgrade claude 2>&1 | tail -3
      ;;
    snap)
      printf "  ${DIM}snap refresh claude${RESET}\n"
      sudo snap refresh claude 2>&1 | tail -3
      ;;
    apt)
      printf "  ${DIM}apt upgrade claude${RESET}\n"
      sudo apt-get install --only-upgrade -y claude 2>&1 | tail -3
      ;;
    npm)
      # Pin exact version to bypass npm cache serving stale @latest
      local npm_target="@anthropic-ai/claude-code@${target_ver:-latest}"
      printf "  ${DIM}npm install -g %s${RESET}\n" "$npm_target"
      npm install -g "$npm_target" 2>&1 | tail -3
      ;;
    *)
      # Unknown method — try native install as upgrade
      _claude_install "$method"
      ;;
  esac
}

# Print a method-specific upgrade hint.  Usage: _claude_update_hint <method> <prefix>
_claude_update_hint() {
  local m="$1" p="$2"
  case "$m" in
    standalone) printf "  ${DIM}%s: claude update${RESET}\n" "$p" ;;
    brew)       printf "  ${DIM}%s: brew upgrade claude${RESET}\n" "$p" ;;
    snap)       printf "  ${DIM}%s: sudo snap refresh claude${RESET}\n" "$p" ;;
    apt)        printf "  ${DIM}%s: sudo apt-get install --only-upgrade claude${RESET}\n" "$p" ;;
    npm)        printf "  ${DIM}%s: npm install -g @anthropic-ai/claude-code@latest${RESET}\n" "$p" ;;
    *)          printf "  ${DIM}%s: https://docs.anthropic.com/en/docs/claude-code${RESET}\n" "$p" ;;
  esac
}

# Extract semver from claude --version output (e.g. "2.1.81 (Claude Code)" → "2.1.81")
_claude_semver() {
  claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Fetch latest available version from npm registry (lightweight, no install needed).
_claude_latest_ver() {
  if command -v npm >/dev/null 2>&1; then
    npm view @anthropic-ai/claude-code version 2>/dev/null
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 5 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null \
      | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4
  fi
}

# Check if Claude Code CLI has an update available, offer to install/upgrade it.
_check_claude_update() {
  if ! command -v claude >/dev/null 2>&1; then
    doey_warn "Claude Code CLI not installed"
    if [ -t 0 ]; then
      if doey_confirm_default_yes "Install now?"; then
        doey_info "Installing Claude Code..."
        if _claude_install "unknown"; then
          command -v claude >/dev/null 2>&1 && doey_success "Claude Code installed"
        else
          doey_error "Install failed — visit https://docs.anthropic.com/en/docs/claude-code"
        fi
      fi
    else
      doey_info "Install: https://docs.anthropic.com/en/docs/claude-code"
    fi
    return
  fi

  local current_ver latest_ver method
  current_ver="$(_claude_semver)"
  if [ -z "$current_ver" ]; then
    current_ver=$(claude --version 2>/dev/null || echo "unknown")
    printf "\n  ${DIM}Claude Code: ${RESET}${BOLD}%s${RESET}\n" "$current_ver"
    return
  fi

  printf "\n  ${DIM}Checking Claude Code version...${RESET}"
  method="$(_claude_install_method)"

  latest_ver="$(_claude_latest_ver)"
  if [ -z "$latest_ver" ]; then
    printf "\r  ${DIM}Claude Code: ${RESET}${BOLD}%s${RESET} ${DIM}(couldn't check for updates)${RESET}\n" "$current_ver"
    return
  fi

  if [ "$current_ver" = "$latest_ver" ]; then
    printf "\r  ${SUCCESS}✓${RESET} Claude Code ${BOLD}%s${RESET} ${DIM}(latest)${RESET}                    \n" "$current_ver"
    [[ "$method" != "unknown" ]] && printf "    ${DIM}installed via %s${RESET}\n" "$method"
  else
    printf "\r  ${WARN}⚠${RESET} Claude Code ${BOLD}%s${RESET} → ${SUCCESS}%s${RESET} available              \n" "$current_ver" "$latest_ver"
    [[ "$method" != "unknown" ]] && printf "    ${DIM}installed via %s${RESET}\n" "$method"
    if [ -t 0 ]; then
      if doey_confirm_default_yes "Update Claude Code?"; then
        doey_info "Updating Claude Code..."
        if _claude_upgrade "$method" "$latest_ver"; then
          local new_ver
          new_ver="$(_claude_semver)"
          doey_success "Claude Code updated to ${new_ver:-$latest_ver}"
        else
          doey_error "Update failed"
          _claude_update_hint "$method" "Try"
        fi
      fi
    else
      _claude_update_hint "$method" "Update"
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
  [ -z "$name" ] && { doey_error "No doey project for $dir"; exit 1; }
  session="doey-${name}"
  runtime_dir="/tmp/doey/${name}"
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
      tmux send-keys -t "$mgr_ref" "clear" Enter 2>/dev/null || true
      sleep 0.2
      mgr_agent=$(generate_team_agent "doey-manager" "$tw")
      local _rl_mgr_cmd="claude --dangerously-skip-permissions --model $DOEY_MANAGER_MODEL --name \"T${tw} ${DOEY_ROLE_TEAM_LEAD}\" --agent \"$mgr_agent\""
      _append_settings _rl_mgr_cmd "$runtime_dir"
      tmux send-keys -t "$mgr_ref" "$_rl_mgr_cmd" Enter
      printf " ${SUCCESS}✓${RESET}\n"
      (
        sleep "$DOEY_MANAGER_BRIEF_DELAY"
        tmux send-keys -t "$mgr_ref" \
          "Team is online (project: ${name}, dir: $dir). You have ${worker_count_tw:-0} workers in panes ${wp_list}. Your workers are in window ${tw}. Session: $session. All workers are idle and awaiting tasks. What should we work on?" Enter
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
        tmux send-keys -t "$pane_ref" "clear" Enter 2>/dev/null || true
        sleep 0.2

        local w_name
        w_name=$(tmux display-message -t "$pane_ref" -p '#{pane_title}' 2>/dev/null || echo "T${tw} W${wp}")
        local worker_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"${w_name}\""
        _append_settings worker_cmd "$runtime_dir"
        local worker_prompt
        worker_prompt=$(grep -rl "pane ${tw}\.${wp} " "${runtime_dir}"/worker-system-prompt-*.md 2>/dev/null | head -1)
        [ -n "$worker_prompt" ] && worker_cmd+=" --append-system-prompt-file \"${worker_prompt}\""
        tmux send-keys -t "$pane_ref" "$worker_cmd" Enter
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

# ── Uninstall ──────────────────────────────────────────────────────
uninstall_system() {
  doey_header "Doey — Uninstall"
  printf '\n'
  printf "  This will remove:\n"
  printf "    ${DIM}• ~/.local/bin/doey, tmux-statusbar.sh, pane-border-status.sh${RESET}\n"
  printf "    ${DIM}• ~/.local/bin/doey-tui, doey-remote-setup (Go binaries)${RESET}\n"
  printf "    ${DIM}• ~/.claude/agents/doey-*.md${RESET}\n"
  printf "    ${DIM}• ~/.claude/doey/ (config & state)${RESET}\n"
  printf "\n  ${DIM}Will NOT remove: git repo, /tmp/doey, or agent-memory${RESET}\n\n"

  doey_confirm "Continue?" || { doey_info "Cancelled."; printf '\n'; return 0; }

  rm -f ~/.local/bin/doey ~/.local/bin/tmux-statusbar.sh ~/.local/bin/pane-border-status.sh
  if command -v trash >/dev/null 2>&1; then
    trash ~/.local/bin/doey-tui ~/.local/bin/doey-remote-setup 2>/dev/null
  else
    rm -f ~/.local/bin/doey-tui ~/.local/bin/doey-remote-setup
  fi
  rm -f ~/.claude/agents/doey-*.md
  rm -rf ~/.claude/doey

  printf "\n  ${SUCCESS}✓ Uninstalled.${RESET} Reinstall: ${DIM}cd <repo> && ./install.sh${RESET}\n\n"
}

# ── Doctor — check installation health ────────────────────────────────
check_doctor() {
  PROJECT_DIR="$(pwd)"
  _DOC_OK=0 _DOC_WARN=0 _DOC_FAIL=0 _DOC_SKIP=0
  doey_header "Doey — System Check"
  printf '\n'

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
    local _claude_ver _claude_raw _claude_latest
    _claude_raw=$(claude --version 2>/dev/null || echo "unknown")
    _claude_ver=$(_claude_semver)
    _claude_ver="${_claude_ver:-$_claude_raw}"
    _claude_latest=$(_claude_latest_ver)
    if [ -n "$_claude_latest" ] && [ "$_claude_ver" != "$_claude_latest" ]; then
      _doc_check warn "claude CLI" "$_claude_ver → $_claude_latest available"
      printf "\n         "
      _claude_update_hint "$(_claude_install_method)" "Update"
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
  _parse_auth_status
  if [ "$_AUTH_OK" = true ]; then
    _doc_check ok "Claude auth" "${_AUTH_METHOD} · ${_AUTH_EMAIL} · ${_AUTH_SUB}"
  else
    _doc_check fail "Claude auth" "Not logged in — run 'claude' to authenticate"
  fi

  # PATH check
  if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then _doc_check ok "~/.local/bin in PATH"
  else _doc_check warn "~/.local/bin not in PATH"; fi

  # Installed files
  local _f _label _doey_repo
  _doey_repo="$(resolve_repo_dir)"
  for _f in "$HOME/.claude/agents/doey-manager.md:Agents" \
            "$_doey_repo/.claude/skills/doey-dispatch/SKILL.md:Skills" \
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

  # gum (optional luxury CLI)
  if command -v gum >/dev/null 2>&1; then
    _doc_check ok "gum" "$(gum --version 2>/dev/null || echo 'unknown')"
  else
    _doc_check fail "Gum missing" "run: go install github.com/charmbracelet/gum@latest"
  fi

  # Version
  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    _doc_check ok "Version" "$(_env_val "$version_file" version) ($(_env_val "$version_file" date))"
  else
    _doc_check warn "No version file" "Run 'doey update'"
  fi

  # TUI dashboard
  if command -v doey-tui >/dev/null 2>&1; then
    _doc_check ok "doey-tui" "$(doey-tui --version 2>/dev/null || echo 'installed')"
  else
    if command -v go >/dev/null 2>&1 || [ -x /usr/local/go/bin/go ] || [ -x /opt/homebrew/bin/go ]; then
      _doc_check warn "doey-tui not installed" "Go available — run: doey build"
    else
      _doc_check skip "doey-tui not installed" "using info-panel.sh fallback"
    fi
  fi

  # Remote setup wizard
  if command -v doey-remote-setup >/dev/null 2>&1; then
    _doc_check ok "doey-remote-setup" "installed"
  else
    _doc_check skip "doey-remote-setup not installed" "optional — run: doey build"
  fi

  # Orchestration CLI (doey-ctl)
  if command -v doey-ctl >/dev/null 2>&1; then
    _doc_check ok "doey-ctl" "found at $(command -v doey-ctl)"
  else
    _doc_check warn "doey-ctl not installed" "shell fallbacks will be used — run: doey build"
  fi

  # Go binary freshness
  if [[ -n "$repo_dir" ]] && type _go_binary_stale >/dev/null 2>&1; then
    local _stale_bins=""
    if _go_binary_stale "$HOME/.local/bin/doey-tui" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="doey-tui"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-remote-setup" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-remote-setup"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-ctl" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-ctl"
    fi
    if [[ -n "$_stale_bins" ]]; then
      _doc_check warn "Go binaries may be stale: ${_stale_bins}" "run: doey build"
    else
      _doc_check ok "Go binaries fresh"
    fi
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

  # Task helpers — verify doey-task-helpers.sh is reachable
  local _task_helpers=""
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/doey-task-helpers.sh" ]]; then
    _task_helpers="$repo_dir/shell/doey-task-helpers.sh"
  else
    # Fall back to location relative to the installed doey script
    local _doey_bin=""
    _doey_bin="$(command -v doey 2>/dev/null || true)"
    if [[ -n "$_doey_bin" ]] && [[ -f "$(dirname "$_doey_bin")/doey-task-helpers.sh" ]]; then
      _task_helpers="$(dirname "$_doey_bin")/doey-task-helpers.sh"
    fi
  fi
  if [[ -n "$_task_helpers" ]]; then
    _doc_check ok "Task helpers" "${_task_helpers/#$HOME/~}"
  else
    _doc_check warn "Task helpers not found" "doey-task-helpers.sh missing from repo and PATH"
  fi

  # Task counter — validate .next_id if .doey/tasks/ exists
  local _tasks_dir="${PROJECT_DIR}/.doey/tasks"
  if [[ -d "$_tasks_dir" ]] && [[ -f "${_tasks_dir}/.next_id" ]]; then
    local _nid; _nid="$(cat "${_tasks_dir}/.next_id" 2>/dev/null || true)"
    case "$_nid" in
      ''|*[!0-9]*) _doc_check warn "Task counter" ".next_id is not a positive integer: ${_nid:-empty}" ;;
      0)           _doc_check warn "Task counter" ".next_id=0 — may collide with existing tasks" ;;
      *)           _doc_check ok "Task counter" ".next_id=${_nid}" ;;
    esac
  elif [[ -d "$_tasks_dir" ]]; then
    _doc_check skip "Task counter" ".doey/tasks/ exists but no .next_id yet"
  fi

  # ── Summary footer ──
  printf '\n'
  local _doc_total=$((_DOC_OK + _DOC_WARN + _DOC_FAIL))
  if [ "$HAS_GUM" = true ]; then
    local _doc_summary=""
    _doc_summary="$(gum style --foreground 2 "${_DOC_OK} passed")"
    [ "$_DOC_WARN" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 3 "${_DOC_WARN} warnings")"
    [ "$_DOC_FAIL" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 1 --bold "${_DOC_FAIL} failed")"
    [ "$_DOC_SKIP" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 240 "${_DOC_SKIP} skipped")"
    gum style --padding "0 1" "$_doc_summary"
  else
    printf "  ${SUCCESS}%d passed${RESET}" "$_DOC_OK"
    [ "$_DOC_WARN" -gt 0 ] && printf "  ${WARN}%d warnings${RESET}" "$_DOC_WARN"
    [ "$_DOC_FAIL" -gt 0 ] && printf "  ${ERROR}%d failed${RESET}" "$_DOC_FAIL"
    [ "$_DOC_SKIP" -gt 0 ] && printf "  ${DIM}%d skipped${RESET}" "$_DOC_SKIP"
    printf '\n'
  fi
  printf '\n'
}

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

# ── Version — show installation info ─────────────────────────────────
show_version() {
  doey_header "Doey"
  printf '\n'

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

  doey_info "Agents     ~/.claude/agents/"
  doey_info "Skills     .claude/skills/"
  doey_info "CLI        ~/.local/bin/doey"
  local project_count=0
  [[ -f "$PROJECTS_FILE" ]] && project_count="$(grep -c '.' "$PROJECTS_FILE" 2>/dev/null || echo 0)"
  doey_info "Projects   ${project_count} registered"

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
  local session="doey-${name}" runtime_dir="/tmp/doey/${name}"
  local short_dir="${dir/#$HOME/~}"
  local team_window=2

  cd "$dir"
  _doey_load_config  # Reload config now that we're in the project dir

  # Quick mode: minimal defaults, skip wizard
  if [ "$DOEY_QUICK" = "true" ]; then
    : "${DOEY_INITIAL_TEAMS:=1}"
    : "${DOEY_INITIAL_WORKER_COLS:=1}"
    : "${DOEY_INITIAL_FREELANCER_TEAMS:=0}"
  fi

  # Run startup wizard if not skipped
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

  doey_banner
  local initial_workers=$(( DOEY_INITIAL_WORKER_COLS * 2 ))
  doey_info "Project ${name}  Grid dynamic  Workers ${initial_workers} (auto-expands)"
  doey_info "Dir ${short_dir}  Session ${session}"
  printf '\n'

  ensure_project_trusted "$dir"
  install_doey_hooks "$dir" "   "

  STEP_TOTAL=7
  step_start 1 "Creating session for ${name}..."
  _init_doey_session "$session" "$runtime_dir" "$dir" "$name"

  step_done

  step_start 2 "Applying theme..."
  local border_fmt=' #{?pane_active,#[fg=cyan bold],#[fg=colour245]}#{pane_title} #[default]'
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
MAX_WORKERS="$DOEY_MAX_WORKERS"
WORKER_PANES=""
WORKER_COUNT="0"
CURRENT_COLS="1"
RUNTIME_DIR="${runtime_dir}"
PASTE_SETTLE_MS="500"
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

  # Check if team 1 has a definition file — if so, use add_team_from_def instead of dynamic grid
  local _team1_def=""
  [ -n "${DOEY_TEAM_COUNT:-}" ] && _team1_def=$(_read_team_config "1" "DEF" "")
  local _team1_type=""
  [ -n "${DOEY_TEAM_COUNT:-}" ] && _team1_type=$(_read_team_config "1" "TYPE" "")

  if [ -n "$_team1_def" ]; then
    # First worker team uses a .team.md definition — dashboard + core team first, then spawn from def
    write_team_env "$runtime_dir" "$team_window" "dynamic" "" "0" "0" "" ""
    setup_dashboard "$session" "$dir" "$runtime_dir" "$DOEY_INITIAL_TEAMS"
    _create_core_team "$session" "$runtime_dir" "$dir"
    step_done

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

    step_done

    step_start 4 "Launching ${DOEY_ROLE_TEAM_LEAD}..."
    _launch_team_manager "$session" "$runtime_dir" "$team_window"
    _brief_team "$session" "$team_window" "" "" "0" \
      "Dynamic grid — ${initial_workers} initial workers, auto-expands when all are busy"
    step_done

    step_start 5 "Adding ${DOEY_INITIAL_WORKER_COLS} worker columns (${initial_workers} workers)..."
    local _col_i
    for (( _col_i=0; _col_i<DOEY_INITIAL_WORKER_COLS; _col_i++ )); do
      doey_add_column "$session" "$runtime_dir" "$dir" "$team_window"
  
    done
    step_done
  fi

  # ── Attach early, build remaining teams in background ────────────────
  # Team 1 + dashboard are ready. Spawn remaining teams (T2+, freelancers,
  # worktrees) and briefings in a background subshell so the user gets
  # attached to tmux immediately instead of waiting for all teams.

  # Update first worker team's env with per-team config if specified (quick, no tmux ops)
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

  # Count T1 for the initial summary (remaining teams update session.env when done)
  local _t1_team_windows _t1_team_count=0 _t1_tw
  _t1_team_windows=$(read_team_windows "$runtime_dir")
  for _t1_tw in $(echo "$_t1_team_windows" | tr ',' ' '); do
    _t1_team_count=$((_t1_team_count + 1))
  done

  printf '\n'
  if [ "$HAS_GUM" = true ]; then
    printf '%s\n' "$(gum style --foreground 2 --bold '✓ Doey is ready  (dynamic grid)')"
    gum style --border rounded --border-foreground 6 --padding "1 2" --margin "0 1" \
      "$(gum style --foreground 6 --bold 'Dashboard')  win 0  Info panel + ${DOEY_ROLE_BOSS}" \
      "$(gum style --foreground 6 --bold 'Teams')      ${_t1_team_count} windows (${_t1_team_windows})" \
      "$(gum style --foreground 6 --bold 'Workers')    T1: ${initial_workers} (auto-expands)" \
      "" \
      "$(gum style --foreground 6 --bold 'Project')   ${name}" \
      "$(gum style --foreground 6 --bold 'Grid')      dynamic  Max workers  ${DOEY_MAX_WORKERS}" \
      "$(gum style --foreground 6 --bold 'Session')   ${session}" \
      "" \
      "$(gum style --foreground 240 'Tip: doey add — adds 2 more workers')"
  else
    doey_success "Doey is ready  (dynamic grid)"
    doey_divider 50
    printf "\n"
    doey_info "Dashboard  win 0  Info panel + ${DOEY_ROLE_BOSS}"
    doey_info "Teams      ${_t1_team_count} windows (${_t1_team_windows})"
    doey_info "Workers    T1: ${initial_workers} (auto-expands, doey add)"
    printf "\n"
    doey_info "Project   ${name}"
    doey_info "Grid      dynamic  Max workers  ${DOEY_MAX_WORKERS}"
    doey_info "Session   ${session}"
    doey_info "Manifest  ${runtime_dir}/session.env"
    printf "\n"
    doey_info "Tip: doey add — adds 2 more workers"
    doey_divider 50
  fi
  printf '\n'

  # Background subshell: spawn remaining teams + send briefings
  (
    sleep 0.3  # Let attach happen first

    # ── Spawn remaining teams (T2+) ──
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

    tmux send-keys -t "$session:0.1" \
      "Session online. You are ${DOEY_ROLE_BOSS}. Project: ${name}, dir: ${dir}, session: ${session}. ${DOEY_ROLE_COORDINATOR} is in the Core Team window. ${final_team_count} team windows (${final_team_windows}). Awaiting instructions." Enter
    # Taskmaster briefing (Core Team pane 1.0)
    local _tm_pane
    _tm_pane=$(grep '^TASKMASTER_PANE=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    _tm_pane="${_tm_pane:-1.0}"
    tmux send-keys -t "$session:${_tm_pane}" \
      "Session online. Project: ${name}, dir: ${dir}, session: ${session}. You are ${DOEY_ROLE_COORDINATOR} at pane ${_tm_pane} in Core Team window. Worker team windows: ${final_team_windows}. Awaiting ${DOEY_ROLE_BOSS} instructions." Enter
  ) &
  local _BG_SPAWN_PID=$!

  # Attach immediately — user sees dashboard + T1 while remaining teams spawn behind
  tmux select-window -t "$session:0"
  attach_or_switch "$session"

  # After detach, wait for background spawner to finish
  wait "$_BG_SPAWN_PID" 2>/dev/null || true
}

_check_grid_feasibility() {
  local session="$1" window="$2" min_col_w="${3:-40}" min_row_h="${4:-8}"
  local win_dims
  win_dims="$(tmux display-message -t "$session:$window" -p '#{window_width} #{window_height}' 2>/dev/null)" || return 1
  local win_w="${win_dims%% *}"
  local win_h="${win_dims##* }"
  _FEASIBLE_MAX_COLS=$(( (win_w - 1) / (min_col_w + 1) ))
  _FEASIBLE_MAX_ROWS=$(( win_h / (min_row_h + 1) ))
  [ "$_FEASIBLE_MAX_COLS" -lt 1 ] && _FEASIBLE_MAX_COLS=1
  [ "$_FEASIBLE_MAX_ROWS" -lt 1 ] && _FEASIBLE_MAX_ROWS=1
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
  local session="$1" team_window="${2:-1}" runtime_dir="${3:-}" mgr_width=90

  local win_w win_h dims
  dims="$(tmux display-message -t "$session:${team_window}" -p '#{window_width} #{window_height}')"
  win_w="${dims%% *}"
  win_h="${dims##* }"

  local pane_ids=()
  while IFS=$'\t' read -r _idx _pid; do
    pane_ids+=("${_pid#%}")
  done < <(tmux list-panes -t "$session:${team_window}" -F '#{pane_index}	#{pane_id}')

  local num_panes=${#pane_ids[@]}
  if (( num_panes < 3 )); then return 0; fi

  if [ -z "$runtime_dir" ]; then
    runtime_dir=$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
  fi

  local top_h=$((win_h / 2)) bot_h=$((win_h - win_h / 2 - 1))

  # Both freelancer and regular teams use the same layout: pane 0 full-height left, workers in 2-row columns
  # Exception: freelancer teams get 3 rows in the last column
  local _rgl_is_freelancer="false"
  if [ -n "$runtime_dir" ] && [ -f "${runtime_dir}/team_${team_window}.env" ]; then
    local _rgl_tt
    _rgl_tt=$(_env_val "${runtime_dir}/team_${team_window}.env" TEAM_TYPE)
    [ "$_rgl_tt" = "freelancer" ] && _rgl_is_freelancer="true"
  fi

  local max_mgr=$((win_w / 3))
  (( mgr_width > max_mgr )) && mgr_width=$max_mgr

  local num_workers=$((num_panes - 1))
  local worker_cols
  if [ "$_rgl_is_freelancer" = "true" ] && (( num_workers >= 3 )); then
    # Last column gets 3 rows; reserve 3 for it, rest get 2 each
    worker_cols=$(( (num_workers - 2) / 2 + 1 ))
  else
    worker_cols=$(( (num_workers + 1) / 2 ))
  fi
  local worker_area=$((win_w - mgr_width - 1))
  local body="" x=0
  body="${mgr_width}x${win_h},${x},0,${pane_ids[0]}"
  x=$((mgr_width + 1))

  local c w wi=1
  for ((c=0; c<worker_cols; c++)); do
    if ((c == worker_cols - 1)); then
      w=$((win_w - x))
    else
      w=$((worker_area / worker_cols))
    fi
    local tp="${pane_ids[$wi]}"
    body+=","
    # Determine panes in this column: 3 for freelancer last column, otherwise 2 (or 1 if remainder)
    local _rgl_col_panes=2
    if [ "$_rgl_is_freelancer" = "true" ] && (( c == worker_cols - 1 )) && (( num_workers >= 3 )); then
      _rgl_col_panes=3
    fi
    local _rgl_remaining=$((num_panes - wi))
    (( _rgl_col_panes > _rgl_remaining )) && _rgl_col_panes=$_rgl_remaining
    if (( _rgl_col_panes == 3 )); then
      local _rgl_h1=$(( (win_h - 2) / 3 ))
      local _rgl_h2=$(( (win_h - 2) / 3 ))
      local _rgl_h3=$(( win_h - 2 - _rgl_h1 - _rgl_h2 ))
      local _rgl_y2=$(( _rgl_h1 + 1 )) _rgl_y3=$(( _rgl_h1 + 1 + _rgl_h2 + 1 ))
      local mp="${pane_ids[$((wi + 1))]}"
      local bp="${pane_ids[$((wi + 2))]}"
      body+="${w}x${win_h},${x},0[${w}x${_rgl_h1},${x},0,${tp},${w}x${_rgl_h2},${x},${_rgl_y2},${mp},${w}x${_rgl_h3},${x},${_rgl_y3},${bp}]"
    elif (( _rgl_col_panes == 2 )); then
      local bp="${pane_ids[$((wi + 1))]}"
      body+="${w}x${win_h},${x},0[${w}x${top_h},${x},0,${tp},${w}x${bot_h},${x},$((top_h+1)),${bp}]"
    else
      body+="${w}x${win_h},${x},0,${tp}"
    fi
    wi=$((wi + _rgl_col_panes))
    x=$((x + w + 1))
  done

  local layout_str="${win_w}x${win_h},0,0{${body}}"
  tmux select-layout -t "$session:${team_window}" "$(_layout_checksum "$layout_str"),${layout_str}" 2>/dev/null || true
}

rebuild_pane_state() {
  local session="$1" include_pane0="${2:-false}"
  _worker_panes=""
  local pidx
  while IFS='' read -r pidx; do
    [ "$pidx" = "0" ] && [ "$include_pane0" != "true" ] && continue
    [ -n "$_worker_panes" ] && _worker_panes+=","
    _worker_panes+="$pidx"
  done < <(tmux list-panes -t "$session" -F '#{pane_index}')
}

# Bulk-read all team env keys in a single pass.  Sets _ts_* variables.
# Usage: _read_team_env_bulk <env_file>
_read_team_env_bulk() {
  local _reb_file="$1" _reb_line _reb_val
  _ts_worker_count="" _ts_grid="" _ts_worker_panes=""
  _ts_wt_dir="" _ts_wt_branch="" _ts_team_type=""
  _ts_team_name="" _ts_team_role="" _ts_worker_model="" _ts_manager_model=""
  [ ! -f "$_reb_file" ] && return 0
  while IFS= read -r _reb_line || [ -n "$_reb_line" ]; do
    _reb_val="${_reb_line#*=}"
    _reb_val="${_reb_val//\"/}"
    case "$_reb_line" in
      WORKER_COUNT=*)   _ts_worker_count="$_reb_val" ;;
      GRID=*)           _ts_grid="$_reb_val" ;;
      WORKER_PANES=*)   _ts_worker_panes="$_reb_val" ;;
      WORKTREE_DIR=*)   _ts_wt_dir="$_reb_val" ;;
      WORKTREE_BRANCH=*) _ts_wt_branch="$_reb_val" ;;
      TEAM_TYPE=*)      _ts_team_type="$_reb_val" ;;
      TEAM_NAME=*)      _ts_team_name="$_reb_val" ;;
      TEAM_ROLE=*)      _ts_team_role="$_reb_val" ;;
      WORKER_MODEL=*)   _ts_worker_model="$_reb_val" ;;
      MANAGER_MODEL=*)  _ts_manager_model="$_reb_val" ;;
    esac
  done < "$_reb_file"
}

_read_team_state() {
  local session="$1" runtime_dir="$2" dir="$3" team_window="$4"
  local team_env="${runtime_dir}/team_${team_window}.env"

  _ts_dir="$dir" _ts_wt_dir="" _ts_wt_branch=""

  if [ ! -f "$team_env" ]; then
    _ts_worker_count=0
    _ts_grid="${GRID:-dynamic}" _ts_cols=1 _ts_worker_panes=""
    return 0
  fi

  _read_team_env_bulk "$team_env"
  _ts_worker_count="${_ts_worker_count:-0}"
  _ts_grid="${_ts_grid:-dynamic}"

  local _pane_count
  _pane_count=$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l)
  _pane_count="${_pane_count// /}"
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

  # Bulk-read env values (avoids ~12 forks from _env_val calls)
  local _bbw_acronym="" _bbw_worker_model="" _bbw_team_type=""
  local _bbw_env_key _bbw_env_raw
  if [ -f "${runtime_dir}/session.env" ]; then
    while IFS='=' read -r _bbw_env_key _bbw_env_raw; do
      case "$_bbw_env_key" in
        PROJECT_ACRONYM) _bbw_acronym="${_bbw_env_raw//\"/}" ;;
      esac
    done < "${runtime_dir}/session.env"
  fi
  local _bbw_team_env="${runtime_dir}/team_${team_window}.env"
  if [ -f "$_bbw_team_env" ]; then
    while IFS='=' read -r _bbw_env_key _bbw_env_raw; do
      case "$_bbw_env_key" in
        WORKER_MODEL) _bbw_worker_model="${_bbw_env_raw//\"/}" ;;
        TEAM_TYPE) _bbw_team_type="${_bbw_env_raw//\"/}" ;;
      esac
    done < "$_bbw_team_env"
  fi
  [ -z "$_bbw_worker_model" ] && _bbw_worker_model="$DOEY_WORKER_MODEL"
  local _bbw_is_freelancer="false"
  [ "$_bbw_team_type" = "freelancer" ] && _bbw_is_freelancer="true"

  # Phase 1: Prepare all workers — build prompt files and command strings
  local _bbw_pane_arr=() _bbw_cmd_arr=() _bbw_count=0
  local pair pane_idx worker_num
  for pair in "$@"; do
    pane_idx="${pair%%:*}"
    worker_num="${pair##*:}"
    local prompt_suffix="w${team_window}-${worker_num}"
    local prompt_file="${runtime_dir}/worker-system-prompt-${prompt_suffix}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$prompt_file"
    local _bbw_role_label="$DOEY_ROLE_WORKER" _bbw_id_prefix="w"
    if [ "$_bbw_is_freelancer" = "true" ]; then
      _bbw_role_label="$DOEY_ROLE_FREELANCER" _bbw_id_prefix="f"
    fi
    local _bbw_pane_id="t${team_window}-${_bbw_id_prefix}${worker_num}"
    [ -n "$_bbw_acronym" ] && _bbw_pane_id="${_bbw_acronym}-${_bbw_pane_id}"
    printf '\n\n## Identity\nYou are %s %s (%s) in pane %s.%s of session %s.\n' \
      "$_bbw_role_label" "$worker_num" "$_bbw_pane_id" "$team_window" "$pane_idx" "$session" >> "$prompt_file"
    if [ "$_bbw_is_freelancer" = "true" ]; then
      printf 'You are part of the Freelancer pool — independent workers available to any team.\n' >> "$prompt_file"
    fi

    local _bbw_name_prefix="W"
    [ "$_bbw_is_freelancer" = "true" ] && _bbw_name_prefix="F"
    local cmd="claude --dangerously-skip-permissions --effort high --model $_bbw_worker_model --name \"T${team_window} ${_bbw_name_prefix}${worker_num}\""
    _append_settings cmd "$runtime_dir"
    cmd+=" --append-system-prompt-file \"${prompt_file}\""

    # Store pane index and command for phase 2
    _bbw_pane_arr+=("$pane_idx")
    _bbw_cmd_arr+=("$cmd")
    _bbw_count=$(( _bbw_count + 1 ))
  done

  # Phase 2: Launch ALL workers rapidly — no sleep between sends
  local _bbw_i=0
  while [ "$_bbw_i" -lt "$_bbw_count" ]; do
    local _bbw_cur_pane _bbw_cur_cmd
    _bbw_cur_pane="${_bbw_pane_arr[$_bbw_i]}"
    _bbw_cur_cmd="${_bbw_cmd_arr[$_bbw_i]}"
    tmux send-keys -t "$session:${team_window}.${_bbw_cur_pane}" "$_bbw_cur_cmd" Enter
    if [ "$_bbw_is_freelancer" = "true" ]; then
      write_pane_status "$runtime_dir" "${session}:${team_window}.${_bbw_cur_pane}" "RESERVED"
      local _bbw_safe="${session}:${team_window}.${_bbw_cur_pane}"
      _bbw_safe="${_bbw_safe//[-:.]/_}"
      echo "permanent" > "${runtime_dir}/status/${_bbw_safe}.reserved"
    else
      write_pane_status "$runtime_dir" "${session}:${team_window}.${_bbw_cur_pane}" "READY"
    fi
    _bbw_i=$(( _bbw_i + 1 ))
  done

  # Phase 3: Single sleep for auth stagger (O(1) instead of O(N))
  if [ "$_bbw_count" -gt 0 ]; then
    sleep $DOEY_WORKER_LAUNCH_DELAY
  fi
}

doey_add_column() {
  local session="$1" runtime_dir="$2" dir="$3" team_window="${4:-1}"

  safe_source_session_env "${runtime_dir}/session.env"
  _read_team_state "$session" "$runtime_dir" "$dir" "$team_window"

  if [[ "$_ts_grid" != "dynamic" ]]; then
    doey_error "Team window $team_window is not using dynamic grid mode"
    return 1
  fi
  if (( _ts_worker_count >= DOEY_MAX_WORKERS )); then
    doey_error "Max workers reached ($DOEY_MAX_WORKERS)"
    return 1
  fi

  # Pre-check: can we fit another column?
  local _dac_win_w
  _dac_win_w="$(tmux display-message -t "$session:$team_window" -p '#{window_width}' 2>/dev/null)" || true
  if [ -n "$_dac_win_w" ]; then
    local _dac_pane_count
    _dac_pane_count="$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l)"
    _dac_pane_count="${_dac_pane_count// /}"
    local _dac_min_col_w=40
    # Calculate width per column with current panes
    local _dac_cols_now=$(( (_dac_pane_count + 1) / 2 ))  # rough: 2 panes per column
    local _dac_needed_w=$(( (_dac_cols_now + 1) * _dac_min_col_w ))
    if [ "$_dac_needed_w" -gt "$_dac_win_w" ]; then
      printf "  %s Terminal too narrow for another column (%s available, need %s+)%s\n" \
        "${WARN:-}" "$_dac_win_w" "$_dac_needed_w" "${RESET:-}" >&2
      return 1
    fi
  fi

  doey_info "Adding worker column to team ${team_window}..."

  local last_pane new_pane_top new_pane_bottom
  last_pane="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"
  # Use -P -F to atomically capture new pane index (avoids sleep + list-panes race)
  new_pane_top="$(tmux split-window -h -t "$session:$team_window.${last_pane}" -c "$_ts_dir" -P -F '#{pane_index}')"
  new_pane_bottom="$(tmux split-window -v -t "$session:$team_window.${new_pane_top}" -c "$_ts_dir" -P -F '#{pane_index}')"

  local _pane_prefix="W"
  [ "$_ts_team_type" = "freelancer" ] && _pane_prefix="F"

  # Freelancer teams get 3 rows in the last column
  local _dac_new_pane_mid=""
  local _dac_panes_added=2
  if [ "$_ts_team_type" = "freelancer" ]; then
    _dac_new_pane_mid="$new_pane_bottom"
    new_pane_bottom="$(tmux split-window -v -t "$session:$team_window.${_dac_new_pane_mid}" -c "$_ts_dir" -P -F '#{pane_index}')"
    _dac_panes_added=3
  fi

  local w1_num=$(( _ts_worker_count + 1 )) w2_num=$(( _ts_worker_count + 2 ))
  tmux select-pane -t "$session:$team_window.${new_pane_top}" -T "T${team_window} ${_pane_prefix}${w1_num}"
  if [ "$_ts_team_type" = "freelancer" ]; then
    local w3_num=$(( _ts_worker_count + 3 ))
    tmux select-pane -t "$session:$team_window.${_dac_new_pane_mid}" -T "T${team_window} ${_pane_prefix}${w2_num}"
    tmux select-pane -t "$session:$team_window.${new_pane_bottom}" -T "T${team_window} ${_pane_prefix}${w3_num}"
  else
    tmux select-pane -t "$session:$team_window.${new_pane_bottom}" -T "T${team_window} ${_pane_prefix}${w2_num}"
  fi

  local _rps_include_p0="false"
  [ "$_ts_team_type" = "freelancer" ] && _rps_include_p0="true"
  rebuild_pane_state "$session:$team_window" "$_rps_include_p0"

  local new_worker_count=$(( _ts_worker_count + _dac_panes_added ))
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$_worker_panes" "$new_worker_count" "" "$_ts_wt_dir" "$_ts_wt_branch" "$_ts_team_name" "$_ts_team_role" "$_ts_worker_model" "$_ts_manager_model" "$_ts_team_type"

  if [ "$_ts_team_type" = "freelancer" ]; then
    _batch_boot_workers "$session" "$runtime_dir" "$team_window" "${new_pane_top}:${w1_num}" "${_dac_new_pane_mid}:${w2_num}" "${new_pane_bottom}:${w3_num}"
  else
    _batch_boot_workers "$session" "$runtime_dir" "$team_window" "${new_pane_top}:${w1_num}" "${new_pane_bottom}:${w2_num}"
  fi
  rebalance_grid_layout "$session" "$team_window" "$runtime_dir"

  if [ "$_ts_team_type" = "freelancer" ]; then
    doey_ok "Added ${_pane_prefix}${w1_num}, ${_pane_prefix}${w2_num}, and ${_pane_prefix}${w3_num} — ${new_worker_count} workers in $((_ts_cols + 1)) columns"
  else
    doey_ok "Added W${w1_num} and W${w2_num} — ${new_worker_count} workers in $((_ts_cols + 1)) columns"
  fi
}

doey_remove_column() {
  local session="$1" runtime_dir="$2" col_index="${3:-}" team_window="${4:-1}"

  safe_source_session_env "${runtime_dir}/session.env"
  _read_team_state "$session" "$runtime_dir" "${PROJECT_DIR}" "$team_window"

  if [[ "$_ts_grid" != "dynamic" ]]; then
    doey_error "Team window $team_window is not using dynamic grid mode"
    return 1
  fi
  if (( _ts_worker_count == 0 )); then
    doey_error "No worker columns to remove"
    return 1
  fi

  [[ -z "$col_index" ]] && col_index="last"

  # Parse worker panes into positional params (bash 3.2 safe)
  local _old_ifs="$IFS"; IFS=','; set -- $_ts_worker_panes; IFS="$_old_ifs"
  if [ "$#" -lt 2 ]; then
    doey_error "Not enough worker panes to remove a column"
    return 1
  fi

  local remove_top remove_bottom
  if [ "$col_index" = "last" ]; then
    eval "remove_top=\${$(( $# - 1 ))}"
    eval "remove_bottom=\${$#}"
  else
    local ci=$(( col_index ))
    if [ "$ci" -lt 1 ] || [ "$ci" -gt $(( _ts_worker_count / 2 )) ]; then
      doey_error "Invalid column: $col_index (valid: 1-$(( _ts_worker_count / 2 )))"
      return 1
    fi
    local pair_start=$(( (ci - 1) * 2 + 1 ))
    eval "remove_top=\${${pair_start}}"
    eval "remove_bottom=\${$(( pair_start + 1 ))}"
  fi

  doey_info "Removing panes ${team_window}.${remove_top} and ${team_window}.${remove_bottom}..."

  # Stop processes in both panes
  local pane_idx pane_pid
  for pane_idx in "$remove_top" "$remove_bottom"; do
    pane_pid=$(tmux display-message -t "$session:$team_window.${pane_idx}" -p '#{pane_pid}' 2>/dev/null || true)
    [ -n "$pane_pid" ] && pkill -P "$pane_pid" 2>/dev/null || true
  done
  sleep 0.2  # Wait for process termination

  # Kill higher index first to avoid index shift
  if (( remove_top > remove_bottom )); then
    tmux kill-pane -t "$session:$team_window.${remove_top}" 2>/dev/null || true
    tmux kill-pane -t "$session:$team_window.${remove_bottom}" 2>/dev/null || true
  else
    tmux kill-pane -t "$session:$team_window.${remove_bottom}" 2>/dev/null || true
    tmux kill-pane -t "$session:$team_window.${remove_top}" 2>/dev/null || true
  fi
  sleep 0.2

  local _rps_include_p0="false"
  [ "$_ts_team_type" = "freelancer" ] && _rps_include_p0="true"
  rebuild_pane_state "$session:$team_window" "$_rps_include_p0"

  local new_worker_count=$(( _ts_worker_count - 2 ))
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$_worker_panes" "$new_worker_count" "" "$_ts_wt_dir" "$_ts_wt_branch" "$_ts_team_name" "$_ts_team_role" "$_ts_worker_model" "$_ts_manager_model" "$_ts_team_type"
  rebalance_grid_layout "$session" "$team_window" "$runtime_dir"

  doey_ok "Removed worker column — ${new_worker_count} workers remaining"
}

_apply_team_border_theme() {
  local session="$1" window_index="$2"
  local target="${session}:${window_index}"
  local border_fmt=" #{?pane_active,#[fg=cyan bold],#[fg=colour245]}#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
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
  local mgr_model="${4:-}" mgr_agent_override="${5:-}"
  local mgr_name_override="${6:-}" mgr_pane_title_override="${7:-}"
  [ -z "$mgr_model" ] && mgr_model=$(_env_val "${runtime_dir}/team_${window_index}.env" MANAGER_MODEL)
  [ -z "$mgr_model" ] && mgr_model="$DOEY_MANAGER_MODEL"
  local mgr_agent
  if [ -n "$mgr_agent_override" ]; then
    mgr_agent="$mgr_agent_override"
  else
    mgr_agent=$(generate_team_agent "doey-manager" "$window_index")
  fi
  local _proj="${session#doey-}"
  local _mgr_name="${mgr_name_override:-T${window_index} ${DOEY_ROLE_TEAM_LEAD}}"
  local _mgr_pane_title="${mgr_pane_title_override:-${_proj} T${window_index} Mgr}"
  local _mgr_cmd="claude --dangerously-skip-permissions --model $mgr_model --name \"${_mgr_name}\" --agent \"$mgr_agent\""
  _append_settings _mgr_cmd "$runtime_dir"
  tmux send-keys -t "${session}:${window_index}.0" "$_mgr_cmd" Enter
  tmux select-pane -t "${session}:${window_index}.0" -T "$_mgr_pane_title"
  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"
}

_brief_team() {
  local session="$1" window_index="$2" wp_list="$3"
  local worker_count="$4" grid_desc="$5" wt_brief="${6:-}"
  local team_name="${7:-}" team_role="${8:-}"
  local _role_brief=""
  [ -n "$team_role" ] && _role_brief=" Team role: ${team_role}."
  (
    sleep "$DOEY_MANAGER_BRIEF_DELAY"
    tmux send-keys -t "${session}:${window_index}.0" \
      "Team is online in window ${window_index}. ${grid_desc} — ${worker_count} workers. Your workers are in panes ${wp_list}. ${DOEY_ROLE_COORDINATOR} monitors all teams from the Core Team window. Session: ${session}.${wt_brief}${_role_brief} All workers are idle and awaiting tasks. What should we work on?" Enter
  ) &
}

_build_worker_pane_list() {
  local session="$1" window_index="$2"
  _WPL_RESULT=""
  # For freelancer teams, pane 0 is also a worker (no manager)
  local _wpl_skip_pane0="true"
  local _wpl_runtime
  _wpl_runtime=$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null) || true
  _wpl_runtime="${_wpl_runtime#*=}"
  if [ -n "$_wpl_runtime" ] && [ -f "${_wpl_runtime}/team_${window_index}.env" ]; then
    local _wpl_tt
    _wpl_tt=$(_env_val "${_wpl_runtime}/team_${window_index}.env" TEAM_TYPE)
    [ "$_wpl_tt" = "freelancer" ] && _wpl_skip_pane0="false"
  fi
  local _pi
  for _pi in $(tmux list-panes -t "${session}:${window_index}" -F '#{pane_index}'); do
    [ "$_pi" = "0" ] && [ "$_wpl_skip_pane0" = "true" ] && continue
    [ -n "$_WPL_RESULT" ] && _WPL_RESULT="${_WPL_RESULT}, "
    _WPL_RESULT="${_WPL_RESULT}${window_index}.${_pi}"
  done
}

_name_team_window() {
  local session="$1" window_index="$2" wt_dir="$3" runtime_dir="${4:-}"
  local _proj="${session#doey-}" _te="${runtime_dir:+${runtime_dir}/team_${window_index}.env}"
  _apply_team_border_theme "$session" "$window_index"
  tmux select-pane -t "${session}:${window_index}.0" -T "${_proj} T${window_index} Mgr"
  local label=""
  if [ -n "$_te" ] && [ -f "$_te" ]; then
    label=$(_env_val "$_te" TEAM_NAME)
    [ "$label" = "generic" ] && label=""
    if [ -z "$label" ]; then
      local _ntw_tt
      _ntw_tt=$(_env_val "$_te" TEAM_TYPE)
      if [ "$_ntw_tt" = "freelancer" ]; then label="Freelancers"
      elif [ -z "$wt_dir" ]; then label="Regular Team"
      else label="Worktree Team"; fi
    fi
  fi
  [ -z "$label" ] && label="Regular Team"
  tmux rename-window -t "${session}:${window_index}" "$label"
}

_worktree_brief() {
  [ -n "$1" ] || return 0
  echo " ISOLATED WORKTREE: branch ${2}, dir ${1}. Workers operate on this isolated copy — changes do NOT affect the main repo until merged."
}

_print_team_created() {
  local window_index="$1" grid_desc="$2" worker_count="$3"
  local wt_dir="${4:-}" wt_branch="${5:-}"
  if [ -n "$wt_dir" ]; then
    printf "  ${SUCCESS}Team window %s created${RESET} — %s, %s workers, ${BOLD}worktree${RESET} (%s)\n" "$window_index" "$grid_desc" "$worker_count" "$wt_branch"
  else
    printf "  ${SUCCESS}Team window %s created${RESET} — %s, %s workers\n" "$window_index" "$grid_desc" "$worker_count"
  fi
}

# Spawn a team from a .team.md definition file
add_team_from_def() {
  local session="$1" runtime_dir="$2" dir="$3" team_name="$4" type_override="${5:-}"

  # Find and parse definition
  if ! _find_team_def "$team_name"; then
    printf "  ${ERROR}Team definition '%s' not found${RESET}\n" "$team_name" >&2
    printf "  Searched: .doey/teams/ → teams/ → ~/.config/doey/teams/ → repo teams/\n" >&2
    return 1
  fi
  local def_file="$_FTD_RESULT"
  printf "  ${DIM}Loading team definition: %s${RESET}\n" "$def_file"

  local env_file
  env_file=$(_parse_team_def "$def_file" "$runtime_dir") || return 1

  # Read parsed values
  local td_name td_grid td_workers td_type
  local td_manager_model td_worker_model td_briefing
  td_name=$(_env_val "$env_file" NAME)
  td_grid=$(_env_val "$env_file" GRID "dynamic")
  td_workers=$(_env_val "$env_file" WORKERS "3")
  if [ -n "$type_override" ]; then
    td_type="$type_override"
  else
    td_type=$(_env_val "$env_file" TYPE "local")
  fi
  td_manager_model=$(_env_val "$env_file" MANAGER_MODEL "")
  td_worker_model=$(_env_val "$env_file" WORKER_MODEL "")
  td_briefing=$(_env_val "$env_file" BRIEFING_FILE "")

  # Create tmux window
  local window_index
  window_index=$(tmux new-window -t "$session" -c "$dir" -P -F '#{window_index}')
  printf "  ${DIM}Creating team '%s' in window %s...${RESET}\n" "$td_name" "$window_index"

  # Determine pane count from definition (find highest PANE_N key)
  # Also detect whether any pane has role=manager for fast-path decision
  local max_pane=0 _p_idx=0 _has_manager="false"
  while [ "$_p_idx" -le 20 ]; do
    if grep -q "^PANE_${_p_idx}_ROLE=" "$env_file" 2>/dev/null; then
      max_pane="$_p_idx"
      local _p_role
      _p_role=$(_env_val "$env_file" "PANE_${_p_idx}_ROLE" "")
      [ "$_p_role" = "manager" ] && _has_manager="true"
    fi
    _p_idx=$((_p_idx + 1))
  done

  # ── Fast-path: managerless (freelancer) teams ─────────────────────────
  # All panes are workers — no manager launch, no briefing delay.
  if [ "$_has_manager" = "false" ]; then
    # Pre-split all panes at once (pane 0 already exists from new-window)
    local _fp_i=1
    while [ "$_fp_i" -le "$max_pane" ]; do
      tmux split-window -t "${session}:${window_index}" -c "$dir" -h 2>/dev/null || \
        tmux split-window -t "${session}:${window_index}" -c "$dir" -v 2>/dev/null
      _fp_i=$((_fp_i + 1))
    done
    tmux select-layout -t "${session}:${window_index}" tiled 2>/dev/null || true

    # Build pane list covering ALL panes (0..max_pane)
    local _fp_pane_list="" _fp_count=0 _fp_j=0
    while [ "$_fp_j" -le "$max_pane" ]; do
      [ -n "$_fp_pane_list" ] && _fp_pane_list="${_fp_pane_list},"
      _fp_pane_list="${_fp_pane_list}${_fp_j}"
      _fp_count=$((_fp_count + 1))
      _fp_j=$((_fp_j + 1))
    done

    # Write team env: MANAGER_PANE="" and TEAM_TYPE="freelancer"
    write_team_env "$runtime_dir" "$window_index" "$td_grid" \
      "$_fp_pane_list" "$_fp_count" "" "" "" "$td_name" "" \
      "$td_worker_model" "$td_manager_model" "freelancer" "$td_name"
    _register_team_window "$runtime_dir" "$window_index"
    _ensure_worker_prompt "$runtime_dir" "$dir"

    # Boot all panes as workers via _batch_boot_workers (pane 0 through max_pane)
    local _fp_pairs="" _fp_k=0
    while [ "$_fp_k" -le "$max_pane" ]; do
      _fp_pairs="${_fp_pairs} ${_fp_k}:${_fp_k}"
      _fp_k=$((_fp_k + 1))
    done
    _batch_boot_workers "$session" "$runtime_dir" "$window_index" $_fp_pairs

    _build_worker_pane_list "$session" "$window_index"
    rebalance_grid_layout "$session" "$window_index" "$runtime_dir"
    _name_team_window "$session" "$window_index" "" "$runtime_dir"

    printf "  \033[0;32mTeam '%s' created in window %s (%s workers, managerless)\033[0m\n" \
      "$td_name" "$window_index" "$_fp_count"
    return 0
  fi

  # ── Standard path: teams with a manager ───────────────────────────────

  # Build worker panes (pane 0 = manager, rest are workers)
  local worker_pane_list="" worker_count=0 _wp_i=1
  while [ "$_wp_i" -le "$max_pane" ]; do
    # Split window to create worker panes
    tmux split-window -t "${session}:${window_index}" -c "$dir" -h 2>/dev/null || \
      tmux split-window -t "${session}:${window_index}" -c "$dir" -v 2>/dev/null
    [ -n "$worker_pane_list" ] && worker_pane_list="${worker_pane_list},"
    worker_pane_list="${worker_pane_list}${_wp_i}"
    worker_count=$(( worker_count + 1 ))
    _wp_i=$((_wp_i + 1))
  done
  # Apply initial tiled layout, then rebalance after workers are launched
  tmux select-layout -t "${session}:${window_index}" tiled 2>/dev/null || true

  # Write team env with TEAM_DEF field
  write_team_env "$runtime_dir" "$window_index" "$td_grid" \
    "$worker_pane_list" "$worker_count" "0" "" "" "$td_name" "" \
    "$td_worker_model" "$td_manager_model" "$td_type" "$td_name"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$dir"

  # Launch manager (pane 0)
  local mgr_agent="" mgr_name=""
  mgr_agent=$(_env_val "$env_file" PANE_0_AGENT "doey-manager")
  mgr_name=$(_env_val "$env_file" PANE_0_NAME "Manager")
  local mgr_agent_name
  mgr_agent_name=$(generate_team_agent "$mgr_agent" "$window_index")
  local mgr_model="${td_manager_model:-$DOEY_MANAGER_MODEL}"
  local _mgr_cmd="claude --dangerously-skip-permissions --model $mgr_model --agent \"$mgr_agent_name\" --name \"${mgr_name}\""
  _append_settings _mgr_cmd "$runtime_dir"
  tmux send-keys -t "${session}:${window_index}.0" "$_mgr_cmd" Enter
  tmux select-pane -t "${session}:${window_index}.0" -T "$mgr_name"

  # Launch workers (panes 1+)
  local _w_i=1
  while [ "$_w_i" -le "$max_pane" ]; do
    local w_agent w_name w_model w_agent_name
    w_agent=$(_env_val "$env_file" "PANE_${_w_i}_AGENT" "")
    w_name=$(_env_val "$env_file" "PANE_${_w_i}_NAME" "Worker ${_w_i}")
    w_model="${td_worker_model:-$DOEY_WORKER_MODEL}"

    local _w_cmd="claude --dangerously-skip-permissions --effort high --model $w_model --name \"${w_name}\""
    if [ -n "$w_agent" ]; then
      w_agent_name=$(generate_team_agent "$w_agent" "$window_index")
      _w_cmd+=" --agent \"$w_agent_name\""
    fi
    local _w_prompt
    _w_prompt=$(ls "${runtime_dir}"/worker-system-prompt-*.md 2>/dev/null | head -1)
    [ -n "$_w_prompt" ] && _w_cmd+=" --append-system-prompt-file \"$_w_prompt\""
    _append_settings _w_cmd "$runtime_dir"

    sleep "${DOEY_WORKER_LAUNCH_DELAY:-2}"
    tmux send-keys -t "${session}:${window_index}.${_w_i}" "$_w_cmd" Enter
    tmux select-pane -t "${session}:${window_index}.${_w_i}" -T "$w_name"
    _w_i=$((_w_i + 1))
  done

  # Build worker pane list, apply manager-left layout, and name window
  _build_worker_pane_list "$session" "$window_index"
  rebalance_grid_layout "$session" "$window_index" "$runtime_dir"
  _name_team_window "$session" "$window_index" "" "$runtime_dir"

  # Brief manager with team layout + briefing content
  if [ -n "$td_briefing" ] && [ -f "$td_briefing" ]; then
    local _brief_text _layout=""
    _layout="Team: ${td_name} | Window: ${window_index} | Workers: ${worker_count}\nPanes:"
    local _b_i=0
    while [ "$_b_i" -le "$max_pane" ]; do
      local _b_role _b_name
      _b_role=$(_env_val "$env_file" "PANE_${_b_i}_ROLE" "")
      _b_name=$(_env_val "$env_file" "PANE_${_b_i}_NAME" "")
      [ -n "$_b_role" ] && _layout="${_layout}\n  Pane ${_b_i}: ${_b_name} (${_b_role})"
      _b_i=$((_b_i + 1))
    done
    _brief_text=$(printf '%b\n\n%s' "$_layout" "$(cat "$td_briefing")")

    (
      sleep "$DOEY_MANAGER_BRIEF_DELAY"
      local _bf
      _bf=$(mktemp "${runtime_dir}/brief_XXXXXX.txt")
      printf '%s' "$_brief_text" > "$_bf"
      tmux copy-mode -q -t "${session}:${window_index}.0" 2>/dev/null
      tmux load-buffer "$_bf"
      tmux paste-buffer -t "${session}:${window_index}.0"
      sleep 0.3
      tmux send-keys -t "${session}:${window_index}.0" Enter
      rm -f "$_bf"
    ) &
  fi

  printf "  \033[0;32mTeam '%s' created in window %s (%s workers)\033[0m\n" \
    "$td_name" "$window_index" "$worker_count"
}

add_dynamic_team_window() {
  local session="$1" runtime_dir="$2" dir="$3" initial_cols="${4:-$DOEY_INITIAL_WORKER_COLS}"
  local worktree_spec="${5:-}"
  local team_name="${6:-}" team_role="${7:-}" worker_model="${8:-}" manager_model="${9:-}"
  local team_type="${10:-}"
  local team_dir="$dir" worktree_branch="" wt_dir_for_env=""
  local is_freelancer="false"
  [ "$team_type" = "freelancer" ] && is_freelancer="true"

  # Freelancer teams: panes 0+1 form the base (F0, F1), no extra columns by default
  if [ "$is_freelancer" = "true" ]; then
    initial_cols=0
  fi

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

  local _team_label="team"
  [ "$is_freelancer" = "true" ] && _team_label="freelancer team"
  printf "  ${DIM}Creating dynamic %s window %s...${RESET}\n" "$_team_label" "$window_index"

  # Freelancer teams: no manager, all panes are workers. MANAGER_PANE is empty.
  local mgr_pane="0"
  [ "$is_freelancer" = "true" ] && mgr_pane=""

  write_team_env "$runtime_dir" "$window_index" "dynamic" "" "0" "$mgr_pane" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model" "$team_type"
  _name_team_window "$session" "$window_index" "$wt_dir_for_env" "$runtime_dir"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$team_dir"

  # Only launch manager for non-freelancer teams
  if [ "$is_freelancer" = "true" ]; then
    # Freelancer: pane 0 is F0, split vertically for pane 1 (F1) — two rows in first column
    # Split first, then batch-boot both workers in one call (single DOEY_WORKER_LAUNCH_DELAY)
    tmux split-window -v -t "$session:${window_index}.0" -c "$team_dir"
    local _fl_p1
    _fl_p1="$(tmux list-panes -t "$session:$window_index" -F '#{pane_index}' | tail -1)"

    # Name panes before boot
    tmux select-pane -t "$session:${window_index}.0" -T "T${window_index} F0"
    tmux select-pane -t "$session:${window_index}.${_fl_p1}" -T "T${window_index} F1"

    # Batch-boot both freelancers — handles prompt files, commands, status, and RESERVED flags
    _batch_boot_workers "$session" "$runtime_dir" "$window_index" "0:0" "${_fl_p1}:1"

    # Update worker count: F0 is uncounted (like manager pane), F1 adds 1
    # so doey_add_column numbering continues sequentially (F2, F3, ...)
    write_team_env "$runtime_dir" "$window_index" "dynamic" "" "1" "$mgr_pane" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model" "$team_type"
  else
    _launch_team_manager "$session" "$runtime_dir" "$window_index"
  fi

  # Calculate max feasible columns
  _check_grid_feasibility "$session" "$window_index" 40 8 2>/dev/null || true
  if [ "${_FEASIBLE_MAX_COLS:-99}" -lt "$initial_cols" ]; then
    printf "  %s Requested %s worker columns but only %s fit — reducing%s\n" \
      "${WARN:-}" "$initial_cols" "$_FEASIBLE_MAX_COLS" "${RESET:-}" >&2
    initial_cols="$_FEASIBLE_MAX_COLS"
  fi

  local _col_i
  for (( _col_i=0; _col_i<initial_cols; _col_i++ )); do
    doey_add_column "$session" "$runtime_dir" "$team_dir" "$window_index"

  done

  _build_worker_pane_list "$session" "$window_index"
  local worker_count wt_brief
  worker_count=$(_env_val "${runtime_dir}/team_${window_index}.env" WORKER_COUNT)
  wt_brief=$(_worktree_brief "$wt_dir_for_env" "$worktree_branch")

  if [ "$is_freelancer" = "true" ]; then
    _print_team_created "$window_index" "freelancer pool" "$worker_count" "$wt_dir_for_env" "$worktree_branch"
  else
    _brief_team "$session" "$window_index" "$_WPL_RESULT" "$worker_count" "Dynamic grid, auto-expands when all are busy" "$wt_brief" "$team_name" "$team_role"
    _print_team_created "$window_index" "dynamic grid" "$worker_count" "$wt_dir_for_env" "$worktree_branch"
  fi
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

  local actual
  actual=$(tmux list-panes -t "${session}:${window_index}" 2>/dev/null | wc -l)
  actual="${actual// /}"
  [ "$actual" -eq "$total_panes" ] || printf "  ${WARN}Expected %s panes but got %s — terminal may be too small${RESET}\n" "$total_panes" "$actual"

  # Apply manager-left layout: pane 0 full-height left, workers in 2-row columns
  rebalance_grid_layout "$session" "$window_index" "$runtime_dir"

  local worker_panes worker_count
  worker_panes=$(_build_worker_csv "$total_panes")
  worker_count=$((total_panes - 1))

  local i
  for (( i=1; i<total_panes; i++ )); do
    tmux select-pane -t "${session}:${window_index}.${i}" -T "T${window_index} W${i}"
  done

  write_team_env "$runtime_dir" "$window_index" "$grid" "$worker_panes" "$worker_count" "0" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$team_dir"
  _launch_team_manager "$session" "$runtime_dir" "$window_index"

  local _aw_pairs=()
  for (( i=1; i<total_panes; i++ )); do
    _aw_pairs+=("${i}:${i}")
  done
  _batch_boot_workers "$session" "$runtime_dir" "$window_index" "${_aw_pairs[@]}"

  _build_worker_pane_list "$session" "$window_index"
  _brief_team "$session" "$window_index" "$_WPL_RESULT" "$worker_count" "Grid ${grid}" "" "$team_name" "$team_role"
  _print_team_created "$window_index" "grid ${grid}" "$worker_count" "$wt_dir_for_env" "$worktree_branch"
}

kill_team_window() {
  local session="$1" runtime_dir="$2" window="$3"
  local team_env="${runtime_dir}/team_${window}.env"

  [ -f "$team_env" ] || { printf "  ${ERROR}No team env for window %s${RESET}\n" "$window"; return 1; }
  [ "$window" != "0" ] || { printf "  ${ERROR}Cannot kill window 0 — use 'doey stop'${RESET}\n"; return 1; }

  printf "  ${DIM}Killing team window %s...${RESET}\n" "$window"

  local pane_id pane_pid
  for pane_id in $(tmux list-panes -t "${session}:${window}" -F '#{pane_id}' 2>/dev/null); do
    pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null) || continue
    [ -n "$pane_pid" ] || continue
    pkill -P "$pane_pid" 2>/dev/null || true
    kill -- -"$pane_pid" 2>/dev/null || true
  done
  sleep 0.3
  tmux kill-window -t "${session}:${window}" 2>/dev/null || true

  local _wt_dir
  _wt_dir=$(_env_val "$team_env" WORKTREE_DIR)
  if [ -n "$_wt_dir" ]; then
    local _proj_dir
    _proj_dir=$(_env_val "${runtime_dir}/session.env" PROJECT_DIR)
    [ -z "$_proj_dir" ] || _worktree_safe_remove "$_proj_dir" "$_wt_dir"
  fi

  rm -f "$team_env"
  rm -f "$HOME/.claude/agents/t${window}-manager.md" 2>/dev/null || true
  local safe_prefix="${session//[-:.]/_}_${window}_"
  rm -f "${runtime_dir}/status/${safe_prefix}"* 2>/dev/null || true
  rm -f "${runtime_dir}/results/"*"_${window}_"* 2>/dev/null || true
  _unregister_team_window "$runtime_dir" "$window"

  printf "  ${SUCCESS}Team window %s killed and cleaned up${RESET}\n" "$window"
}

list_team_windows() {
  local session="$1" runtime_dir="$2"

  doey_header "Doey — Team Windows"
  printf '\n'

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
      *) doey_error "Unknown test flag: $1"; return 1 ;;
    esac
  done

  local test_id="e2e-test-$(date +%s)"
  local test_root="/tmp/doey-test/${test_id}"
  local project_dir="${test_root}/project"
  local report_file="${test_root}/report.md"
  local last8="${test_id: -8}"
  local test_project_name="e2e-test-${last8}"
  local session="doey-${test_project_name}"

  doey_header "Doey — E2E Test"
  printf '\n'
  doey_info "Test ID    ${test_id}"
  doey_info "Grid       ${grid}"
  doey_info "Sandbox    ${project_dir}"
  doey_info "Report     ${report_file}"
  printf '\n'

  doey_step "1/6" "Creating sandbox project..."
  mkdir -p "${project_dir}/.claude/hooks"
  cd "$project_dir"
  git init -q
  printf '# E2E Test Sandbox\n\nThis project was created by `doey test` for automated testing.\n' > README.md
  printf 'E2E Test Sandbox - build whatever is requested\n' > CLAUDE.md
  install_doey_hooks "$project_dir" "  "
  git add -A && git commit -q -m "Initial sandbox commit"
  doey_ok "Sandbox created"

  doey_step "2/6" "Registering sandbox..."
  echo "${test_project_name}:${project_dir}" >> "$PROJECTS_FILE"
  doey_ok "Registered ${test_project_name}"

  doey_step "3/6" "Launching team..."
  launch_session_headless "$test_project_name" "$project_dir" "$grid"
  doey_step "4/6" "Waiting for Taskmaster boot..."
  local _wait_count=0
  local _safe_session="${session//[-:.]/_}"
  local _tm_status="/tmp/doey/${test_project_name}/status/${_safe_session}_0_2.status"
  while [ "$_wait_count" -lt 30 ]; do
    if [ -f "$_tm_status" ]; then
      local _tm_state
      _tm_state="$(cat "$_tm_status" 2>/dev/null || true)"
      case "$_tm_state" in
        BUSY|READY) break ;;
      esac
    fi
    sleep 2
    _wait_count=$((_wait_count + 1))
  done
  if [ "$_wait_count" -ge 30 ]; then
    doey_warn "Taskmaster did not report ready within 60s — continuing anyway"
  fi
  doey_ok "Boot complete"

  doey_step "5/6" "Launching test driver..."
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  local journey_file="${repo_dir}/tests/e2e/journey.md"
  if [[ ! -f "$journey_file" ]]; then
    doey_error "Journey file not found: $journey_file"
    return 1
  fi
  mkdir -p "${test_root}/observations"
  doey_info "Watch live: tmux attach -t ${session}"
  printf '\n'

  claude --dangerously-skip-permissions --agent test-driver --model opus \
    "Run the E2E test. Session: ${session}. Project name: ${test_project_name}. Project dir: ${project_dir}. Runtime dir: /tmp/doey/${test_project_name}. Journey file: ${journey_file}. Observations dir: ${test_root}/observations. Report file: ${report_file}. Test ID: ${test_id}"

  printf '\n'
  doey_step "6/6" "Results"
  if [[ -f "$report_file" ]]; then
    local result_color="$ERROR" result_text="TEST FAILED"
    grep -q "Result: PASS" "$report_file" 2>/dev/null && { result_color="$SUCCESS"; result_text="TEST PASSED"; }
    printf '\n  %s══════ %s ══════%s\n\n' "$result_color" "$result_text" "$RESET"
    doey_info "Report: ${report_file}"
  else
    doey_warn "No report generated"
  fi

  if [[ "$open" == true ]]; then open "${project_dir}/index.html" 2>/dev/null || true; fi

  if [[ "$keep" == false ]]; then
    doey_info "Cleaning up..."
    tmux kill-session -t "$session" 2>/dev/null || true
    grep -v "^${test_project_name}:" "$PROJECTS_FILE" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "$PROJECTS_FILE"
    rm -rf "$test_root"
    doey_ok "Cleaned up"
  else
    printf '\n  %sKept for inspection:%s\n' "$BOLD" "$RESET"
    printf "    ${DIM}Session${RESET}   tmux attach -t ${session}\n"
    printf "    ${DIM}Sandbox${RESET}   ${project_dir}\n"
    printf "    ${DIM}Runtime${RESET}   /tmp/doey/${test_project_name}\n"
    printf "    ${DIM}Report${RESET}    ${report_file}\n\n"
  fi
}

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
  tmux send-keys -t "$session:${settings_win}.0" "DOEY_SETTINGS_LIVE=1 bash \"\$HOME/.local/bin/settings-panel.sh\"" Enter

  # Split right — pane 1 becomes the Claude config editor
  tmux split-window -h -t "$session:${settings_win}.0"
  tmux send-keys -t "$session:${settings_win}.1" "claude --agent settings-editor" Enter

  # Focus the right pane (editor)
  tmux select-pane -t "$session:${settings_win}.1"
  attach_or_switch "$session"
}

# ── Remote Server Management ──────────────────────────────────────────

_doey_ensure_hcloud() {
  # Already installed? Done.
  command -v hcloud >/dev/null 2>&1 && return 0

  printf '\n'
  doey_warn "hcloud CLI not found."
  printf "  The Hetzner Cloud CLI is required for remote server management.\n\n"

  # Detect OS
  local os_type=""
  case "$(uname -s)" in
    Darwin*) os_type="macos" ;;
    Linux*)  os_type="linux" ;;
    *)       os_type="unknown" ;;
  esac

  # Ask user
  local install_method=""
  if [ "$os_type" = "macos" ]; then
    if command -v brew >/dev/null 2>&1; then
      install_method="brew"
      printf "  Install hcloud via Homebrew? [Y/n] "
    else
      doey_error "Homebrew not found."
      printf "  Install hcloud manually:\n"
      printf "  ${BOLD}brew install hcloud${RESET} (after installing Homebrew) or\n"
      printf "  See https://github.com/hetznercloud/cli/releases\n"
      return 1
    fi
  elif [ "$os_type" = "linux" ]; then
    install_method="script"
    printf "  Install hcloud via official install script? [Y/n] "
  else
    doey_error "Unsupported OS."
    printf "  Install hcloud manually from:\n"
    printf "  https://github.com/hetznercloud/cli/releases\n"
    return 1
  fi

  local reply=""
  read -r reply
  case "$reply" in
    [Nn]*)
      printf "\n  To install hcloud manually:\n"
      if [ "$os_type" = "macos" ]; then
        printf "    ${BOLD}brew install hcloud${RESET}\n"
      else
        printf "    ${BOLD}curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin/${RESET}\n"
      fi
      printf "  Then re-run: ${BOLD}doey remote setup <project>${RESET}\n\n"
      return 1
      ;;
  esac

  # Install
  printf "\n"
  if [ "$install_method" = "brew" ]; then
    doey_info "Running: brew install hcloud ..."
    if ! brew install hcloud 2>&1 | sed 's/^/  /'; then
      doey_error "brew install failed."
      return 1
    fi
  elif [ "$install_method" = "script" ]; then
    doey_info "Downloading hcloud from GitHub releases..."
    local arch=""
    case "$(uname -m)" in
      x86_64|amd64)  arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *)
        doey_error "Unsupported architecture: $(uname -m)"
        return 1
        ;;
    esac
    local tmp_dir=""
    tmp_dir="$(mktemp -d)"
    local url="https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-${arch}.tar.gz"
    if ! curl -sSL "$url" -o "${tmp_dir}/hcloud.tar.gz" 2>&1; then
      doey_error "Download failed."
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! tar xzf "${tmp_dir}/hcloud.tar.gz" -C "$tmp_dir" 2>&1; then
      doey_error "Extract failed."
      rm -rf "$tmp_dir"
      return 1
    fi
    # Try /usr/local/bin first, fall back to ~/.local/bin
    local install_dir="/usr/local/bin"
    if [ ! -w "$install_dir" ]; then
      install_dir="$HOME/.local/bin"
      mkdir -p "$install_dir"
    fi
    if ! mv "${tmp_dir}/hcloud" "${install_dir}/hcloud" 2>/dev/null; then
      doey_info "Trying with sudo..."
      if ! sudo mv "${tmp_dir}/hcloud" "/usr/local/bin/hcloud"; then
        doey_error "Install failed. Move hcloud to your PATH manually."
        printf "  Binary is at: ${tmp_dir}/hcloud\n"
        return 1
      fi
      install_dir="/usr/local/bin"
    fi
    chmod +x "${install_dir}/hcloud"
    rm -rf "$tmp_dir"
    # Ensure install_dir is in PATH for this session
    case ":$PATH:" in
      *":${install_dir}:"*) ;;
      *) export PATH="${install_dir}:${PATH}" ;;
    esac
    doey_info "Installed to ${install_dir}/hcloud"
  fi

  # Verify
  if ! command -v hcloud >/dev/null 2>&1; then
    doey_error "hcloud still not found on PATH after install."
    printf "  You may need to restart your shell or add it to your PATH.\n"
    return 1
  fi

  local hcloud_ver=""
  hcloud_ver="$(hcloud version 2>/dev/null | head -1 || echo "unknown")"
  doey_success "hcloud installed: ${hcloud_ver}"
  printf '\n'
  return 0
}

# Ensure hcloud is authenticated (has an active context with a valid token).
# If not, interactively prompt the user to paste their API token.
_doey_ensure_hcloud_auth() {
  # Already authenticated — skip
  if hcloud server list >/dev/null 2>&1; then
    return 0
  fi

  printf '\n'
  doey_warn "hcloud is not authenticated."
  printf "  You need a Hetzner Cloud API token.\n"
  printf "  Create one at: ${BOLD}https://console.hetzner.cloud${RESET}\n"
  printf "  (Project → Security → API Tokens → Generate)\n\n"

  local token=""
  printf "  API Token: "
  read -rs token
  printf "\n"

  if [ -z "$token" ]; then
    doey_error "No token provided. Aborting."
    return 1
  fi

  # Create hcloud context with the provided token
  if ! echo "$token" | hcloud context create doey 2>&1 | sed 's/^/  /'; then
    doey_error "Failed to create hcloud context."
    printf "  Check that your token is valid and try again.\n"
    return 1
  fi

  # Verify the token actually works
  if ! hcloud server list >/dev/null 2>&1; then
    doey_error "Authentication failed — token may be invalid or expired."
    printf "  Delete the context with: ${BOLD}hcloud context delete doey${RESET}\n"
    printf "  Then re-run: ${BOLD}doey remote setup <project>${RESET}\n"
    return 1
  fi

  doey_success "Authenticated with Hetzner Cloud."
  printf '\n'
  return 0
}

doey_remote() {
  local remotes_dir="$HOME/.config/doey/remotes"
  mkdir -p "$remotes_dir"

  local subcmd="${1:-list}"

  case "$subcmd" in
    list)
      # List all remotes
      local remote_files
      remote_files=$(ls "$remotes_dir"/*.remote 2>/dev/null || true)
      if [ -z "$remote_files" ]; then
        printf "\n  ${DIM}No remote servers configured.${RESET}\n\n"
        printf "  Usage: ${BOLD}doey remote <project>${RESET}  — provision & attach to a remote server\n"
        printf "         ${BOLD}doey remote stop <project>${RESET} — destroy a remote server\n"
        printf "         ${BOLD}doey remote status <project>${RESET} — show server status\n\n"
        return 0
      fi
      printf "\n  ${BOLD}%-20s %-16s %-10s %-10s %s${RESET}\n" "PROJECT" "SERVER_IP" "STATUS" "PROVIDER" "CREATED"
      printf "  ${DIM}%-20s %-16s %-10s %-10s %s${RESET}\n" "───────" "─────────" "──────" "────────" "───────"
      local f
      for f in $remote_files; do
        [ -f "$f" ] || continue
        local r_project r_ip r_status r_provider r_created
        r_project="$(basename "$f" .remote)"
        r_ip="$(grep '^SERVER_IP=' "$f" 2>/dev/null | cut -d= -f2- || echo "—")"
        r_status="$(grep '^STATUS=' "$f" 2>/dev/null | cut -d= -f2- || echo "unknown")"
        r_provider="$(grep '^PROVIDER=' "$f" 2>/dev/null | cut -d= -f2- || echo "—")"
        r_created="$(grep '^CREATED=' "$f" 2>/dev/null | cut -d= -f2- || echo "—")"
        printf "  %-20s %-16s %-10s %-10s %s\n" "$r_project" "$r_ip" "$r_status" "$r_provider" "$r_created"
      done
      printf "\n"
      ;;

    stop)
      local project="${2:-}"
      [ -z "$project" ] && { doey_error "Usage: doey remote stop <project>"; return 1; }
      local remote_file="$remotes_dir/${project}.remote"
      [ -f "$remote_file" ] || { doey_error "No remote config found for '$project'"; return 1; }

      if ! _doey_ensure_hcloud; then
        return 1
      fi

      local server_name
      server_name="$(grep '^SERVER_NAME=' "$remote_file" | cut -d= -f2-)"
      [ -z "$server_name" ] && { doey_error "No SERVER_NAME in $remote_file"; return 1; }

      doey_info "Deleting server ${server_name}..."
      if hcloud server delete "$server_name" 2>/dev/null; then
        doey_ok "Server deleted."
      else
        doey_warn "Server may already be deleted."
      fi

      doey_info "Removing SSH key..."
      hcloud ssh-key delete "doey-${project}" 2>/dev/null || true

      command -v trash >/dev/null 2>&1 && trash "$remote_file" || rm -f "$remote_file"
      doey_ok "Remote '$project' removed."
      printf '\n'
      ;;

    status)
      local project="${2:-}"
      [ -z "$project" ] && { doey_error "Usage: doey remote status <project>"; return 1; }
      local remote_file="$remotes_dir/${project}.remote"
      [ -f "$remote_file" ] || { doey_error "No remote config found for '$project'"; return 1; }

      if ! _doey_ensure_hcloud; then
        return 1
      fi

      printf "\n  ${BOLD}Remote: %s${RESET}\n\n" "$project"
      local key val
      while IFS='=' read -r key val; do
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue
        printf "  %-15s %s\n" "$key" "$val"
      done < "$remote_file"

      local server_name
      server_name="$(grep '^SERVER_NAME=' "$remote_file" | cut -d= -f2-)"
      if [ -n "$server_name" ]; then
        printf "\n  ${DIM}Live status from Hetzner:${RESET}\n"
        hcloud server describe "$server_name" 2>/dev/null | head -20 | sed 's/^/  /' || printf "  ${WARN}Could not query server (may be deleted)${RESET}\n"
      fi
      printf "\n"
      ;;

    *)
      # Positional arg = project name → provision or attach
      local project="$subcmd"
      _doey_remote_provision "$project"
      ;;
  esac
}

_doey_remote_provision() {
  local project="$1"
  if [ -z "$project" ] || ! echo "$project" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'; then
    doey_error "Invalid project name."
    printf "  Use only letters, numbers, hyphens, and underscores.\n"
    return 1
  fi
  local remotes_dir="$HOME/.config/doey/remotes"
  local remote_file="$remotes_dir/${project}.remote"
  local ssh_key="$remotes_dir/doey_ed25519"
  local server_name="doey-${project}"

  # Check prerequisites
  if ! _doey_ensure_hcloud; then
    return 1
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    doey_error "ssh not found."
    return 1
  fi

  # Ensure hcloud is authenticated (prompts interactively if needed)
  if ! _doey_ensure_hcloud_auth; then
    return 1
  fi

  # If .remote file exists, check if server is still running
  if [ -f "$remote_file" ]; then
    local existing_ip existing_name
    existing_ip="$(grep '^SERVER_IP=' "$remote_file" | cut -d= -f2-)"
    existing_name="$(grep '^SERVER_NAME=' "$remote_file" | cut -d= -f2-)"

    if [ -n "$existing_name" ] && hcloud server describe "$existing_name" >/dev/null 2>&1; then
      doey_ok "Server '$existing_name' is running at $existing_ip"
      doey_info "Attaching..."
      _doey_remote_attach "$project" "$existing_ip"
      return $?
    else
      doey_warn "Server from config is gone. Re-provisioning..."
      command -v trash >/dev/null 2>&1 && trash "$remote_file" || rm -f "$remote_file"
    fi
  fi

  # Generate SSH key if needed
  if [ ! -f "$ssh_key" ]; then
    doey_info "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "doey-remote" >/dev/null 2>&1
  fi

  # Upload SSH key to Hetzner (delete old one first if exists)
  hcloud ssh-key delete "doey-${project}" 2>/dev/null || true
  doey_info "Uploading SSH key to Hetzner..."
  if ! hcloud ssh-key create --name "doey-${project}" --public-key-from-file "${ssh_key}.pub" >/dev/null 2>&1; then
    doey_error "Failed to upload SSH key to Hetzner"
    return 1
  fi

  # Create server
  doey_info "Creating server '${server_name}' (cx22, Ubuntu 24.04, nbg1)..."
  local create_output
  if ! create_output=$(hcloud server create \
    --name "$server_name" \
    --type cx22 \
    --image ubuntu-24.04 \
    --location nbg1 \
    --ssh-key "doey-${project}" 2>&1); then
    doey_error "Failed to create server."
    printf "  Check hcloud output:\n"
    echo "$create_output" | sed 's/^/  /'
    return 1
  fi

  # Wait for IP
  doey_info "Waiting for server IP..."
  local server_ip=""
  local attempts=0
  while [ -z "$server_ip" ] || [ "$server_ip" = "-" ]; do
    if [ "$attempts" -ge 30 ]; then
      doey_error "Timed out waiting for server IP"
      return 1
    fi
    sleep 2
    server_ip="$(hcloud server ip "$server_name" 2>/dev/null || echo "")"
    attempts=$((attempts + 1))
  done
  doey_ok "Server ready at ${server_ip}"

  # Wait for SSH to become available
  doey_info "Waiting for SSH..."
  attempts=0
  while ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$ssh_key" root@"$server_ip" "echo ok" >/dev/null 2>&1; do
    if [ "$attempts" -ge 30 ]; then
      doey_error "Timed out waiting for SSH"
      return 1
    fi
    sleep 3
    attempts=$((attempts + 1))
  done

  # Copy and run provisioning script
  local provision_script="$HOME/.local/bin/doey-remote-provision.sh"
  if [ ! -f "$provision_script" ]; then
    doey_error "Provisioning script not found at $provision_script"
    printf "  Run ${BOLD}doey update${RESET} to install it.\n"
    return 1
  fi

  doey_info "Uploading provisioning script..."
  scp -o StrictHostKeyChecking=accept-new -i "$ssh_key" "$provision_script" root@"$server_ip":/tmp/doey-remote-provision.sh >/dev/null 2>&1

  doey_info "Provisioning server (this may take a few minutes)..."
  if ! ssh -o StrictHostKeyChecking=accept-new -i "$ssh_key" root@"$server_ip" "bash /tmp/doey-remote-provision.sh '$project'" 2>&1 | sed 's/^/  /'; then
    doey_error "Provisioning failed."
    return 1
  fi

  # Save state
  local server_id
  server_id="$(hcloud server describe "$server_name" -o format='{{.ID}}' 2>/dev/null || echo "unknown")"
  cat > "$remote_file" << REMOTE_EOF
SERVER_ID=$server_id
SERVER_IP=$server_ip
SERVER_NAME=$server_name
PROVIDER=hetzner
STATUS=running
CREATED=$(date +%Y-%m-%dT%H:%M:%S)
REMOTE_EOF

  doey_success "Server provisioned and ready!"
  _doey_remote_attach "$project" "$server_ip"
}

_doey_remote_attach() {
  local project="$1"
  local ip="$2"
  local ssh_key="$HOME/.config/doey/remotes/doey_ed25519"

  doey_info "Connecting to doey@${ip}..."
  printf '\n'
  ssh -t \
    -o StrictHostKeyChecking=accept-new \
    -i "$ssh_key" \
    doey@"$ip" \
    "cd '/home/doey/${project}' && doey"
}

# ── Main Dispatch ─────────────────────────────────────────────────────

_attach_session() {
  local session="$1"
  doey_ok "Attaching to ${session}..."
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

grid="dynamic"

# Parse global flags
DOEY_QUICK="${DOEY_QUICK:-false}"
DOEY_SKIP_WIZARD="${DOEY_SKIP_WIZARD:-false}"
_doey_parsed_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --quick|-q) DOEY_QUICK=true; DOEY_SKIP_WIZARD=true; shift ;;
    --no-wizard) DOEY_SKIP_WIZARD=true; shift ;;
    *) _doey_parsed_args+=("$1"); shift ;;
  esac
done
set -- "${_doey_parsed_args[@]+"${_doey_parsed_args[@]}"}"

# ── Unified CLI routing — forward ctl subcommands to doey-ctl binary ──
# Phase 1 of doey-ctl merge: `doey msg send` works like `doey-ctl msg send`.
# Placed before main dispatch so ctl commands take priority.
case "${1:-}" in
  msg|status|health|task|tmux|plan|team|config|agent|event|nudge|migrate)
    if command -v doey-ctl >/dev/null 2>&1; then
      exec doey-ctl "$@"
    else
      printf 'Error: doey-ctl binary not found. Run "doey doctor" or reinstall.\n' >&2
      exit 1
    fi
    ;;
esac

case "${1:-}" in
  --help|-h)
    doey_header "Doey"
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
    add-team   Add a team window with its own ${DOEY_ROLE_TEAM_LEAD}+Workers
    kill-team  Kill a team window by window index
    list-teams Show all team windows and their status
    teams      List available premade and project team definitions
    deploy     Deploy validation pipeline (start/status/gate)
    remote     Manage remote Hetzner servers (list/provision/stop/status)
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
    doey reload       # hot-reload Manager
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
  doctor)       check_doctor; exit 0 ;;
  version|--version|-v) show_version; exit 0 ;;
  uninstall)    uninstall_system; exit 0 ;;
  --post-update) _post_update "$2"; exit 0 ;;
  update|reinstall) update_system; exit 0 ;;
  build)
    printf "  %bBuilding Go binaries...%b\n" "$BRAND" "$RESET"
    if type _build_all_go_binaries >/dev/null 2>&1; then
      local repo_dir; repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
      if _build_all_go_binaries "$repo_dir"; then
        printf "  %b✓ Go binaries built%b\n" "$SUCCESS" "$RESET"
      else
        printf "  %b✗ Build failed%b\n" "$ERROR" "$RESET"; exit 1
      fi
    else
      printf "  %b✗ Go helpers not loaded%b\n" "$ERROR" "$RESET"; exit 1
    fi
    ;;
  config)       shift; doey_config "$@"; exit 0 ;;
  task|tasks)   shift; task_command "$@"; exit 0 ;;
  remote)       shift; doey_remote "$@"; exit 0 ;;
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
  deploy)
    require_running_session
    shift
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
  add-window)
    require_running_session
    _aw_wt_spec="" _aw_team_type="" _aw_reserved="" _aw_grid_cols=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --worktree) _aw_wt_spec="auto" ;;
        --type) shift; _aw_team_type="${1:-}" ;;
        --grid) shift; _aw_grid_cols="${1%%x*}" ;;
        --reserved) _aw_reserved="true" ;;
        *) ;; # ignore unknown
      esac
      shift
    done
    if [ "$_aw_team_type" = "freelancer" ]; then
      _aw_cols="${_aw_grid_cols:-$DOEY_INITIAL_WORKER_COLS}"
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" \
        "$_aw_cols" "$_aw_wt_spec" "Freelancers" "" "" "" "freelancer"
    elif [ -n "$_aw_wt_spec" ] || [ -n "$_aw_grid_cols" ]; then
      _aw_cols="${_aw_grid_cols:-$DOEY_INITIAL_WORKER_COLS}"
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" \
        "$_aw_cols" "$_aw_wt_spec"
    else
      add_dynamic_team_window "$session" "$runtime_dir" "$dir"
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
  [0-9]*x[0-9]*)
    _check_prereqs
    grid="$1"
    ;;
  "") ;;
  *)
    doey_error "Unknown command: $1"
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
