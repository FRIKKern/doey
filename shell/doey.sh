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

# shellcheck source=doey-task-cli.sh
source "${SCRIPT_DIR}/doey-task-cli.sh"

# shellcheck source=doey-test-runner.sh
source "${SCRIPT_DIR}/doey-test-runner.sh"

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
DOEY_WORKER_LAUNCH_DELAY="${DOEY_WORKER_LAUNCH_DELAY:-1}"
DOEY_TEAM_LAUNCH_DELAY="${DOEY_TEAM_LAUNCH_DELAY:-2}"
DOEY_MANAGER_LAUNCH_DELAY="${DOEY_MANAGER_LAUNCH_DELAY:-1}"
DOEY_MANAGER_BRIEF_DELAY="${DOEY_MANAGER_BRIEF_DELAY:-2}"

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

# ── Helpers ───────────────────────────────────────────────────────────

# _env_val, _read_team_config, resolve_repo_dir → doey-helpers.sh

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

# project_name_from_dir, project_acronym, find_project → doey-helpers.sh

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
  local reserved="${15:-}"
  local task_id="${16:-}"
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
RESERVED="${reserved}"
TASK_ID="${task_id}"
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
  local wt_path="${TMPDIR:-/tmp}/doey/${project_name}/worktrees/team-${team_window}"

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
  doey_send_command "${session}:1.1" "${_DRAIN_STDIN}${_spec_cmd}"
  write_pane_status "$runtime_dir" "${session}:1.1" "READY"

  # Deployment (pane 1.2)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Deployment\" --agent doey-deployment"
  _append_settings _spec_cmd "$runtime_dir"
  doey_send_command "${session}:1.2" "${_DRAIN_STDIN}${_spec_cmd}"
  write_pane_status "$runtime_dir" "${session}:1.2" "READY"

  # Doey Expert (pane 1.3)
  _spec_cmd="claude --dangerously-skip-permissions --effort high --model $DOEY_WORKER_MODEL --name \"Doey Expert\" --agent doey-doey-expert"
  _append_settings _spec_cmd "$runtime_dir"
  doey_send_command "${session}:1.3" "${_DRAIN_STDIN}${_spec_cmd}"
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

# ── Version/update helpers moved to doey-update.sh ──

# ── Purge functions moved to doey-purge.sh ──

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
  local runtime_dir="${TMPDIR:-/tmp}/doey/${name}"
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
  _doey_load_config  # Reload config now that we're in the project dir

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

  local _rgl_has_manager="true"
  if [ -n "$runtime_dir" ] && [ -f "${runtime_dir}/team_${team_window}.env" ]; then
    local _rgl_tt
    _rgl_tt="$(_env_val "${runtime_dir}/team_${team_window}.env" TEAM_TYPE)" || true
    [ "$_rgl_tt" = "freelancer" ] && _rgl_has_manager="false"
  fi

  local top_h=$((win_h / 2)) bot_h=$((win_h - win_h / 2 - 1))

  local num_workers worker_cols worker_area body="" x=0

  if [ "$_rgl_has_manager" = "true" ]; then
    local max_mgr=$((win_w / 3))
    (( mgr_width > max_mgr )) && mgr_width=$max_mgr
    num_workers=$((num_panes - 1))
    worker_cols=$(( (num_workers + 1) / 2 ))
    worker_area=$((win_w - mgr_width - 1))
    body="${mgr_width}x${win_h},${x},0,${pane_ids[0]}"
    x=$((mgr_width + 1))
  else
    num_workers=$num_panes
    worker_cols=$(( (num_workers + 1) / 2 ))
    worker_area=$win_w
  fi

  local c w wi
  if [ "$_rgl_has_manager" = "true" ]; then wi=1; else wi=0; fi
  for ((c=0; c<worker_cols; c++)); do
    if ((c == worker_cols - 1)); then
      w=$((win_w - x))
    else
      w=$((worker_area / worker_cols))
    fi
    local tp="${pane_ids[$wi]}"
    [ -n "$body" ] && body+=","
    # Determine panes in this column: 2 (or 1 if remainder)
    local _rgl_col_panes=2
    local _rgl_remaining=$((num_panes - wi))
    (( _rgl_col_panes > _rgl_remaining )) && _rgl_col_panes=$_rgl_remaining
    if (( _rgl_col_panes == 2 )); then
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
  _ts_reserved=""
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
      RESERVED=*)       _ts_reserved="$_reb_val" ;;
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

# Check for workers stuck in BOOTING state past the timeout.
# Runs as a background watchdog after _batch_boot_workers. For each status file
# still showing BOOTING after DOEY_BOOT_TIMEOUT seconds, transitions it to READY
# and logs a warning so the Taskmaster/Subtaskmaster can detect the issue.
# Usage: _check_boot_timeouts <runtime_dir> <session> <team_window> <pane_idx:worker_num> ...
_check_boot_timeouts() {
  local runtime_dir="$1" session="$2" team_window="$3"
  shift 3

  local timeout="${DOEY_BOOT_TIMEOUT:-60}"
  local now pair pane_idx safe status_file status updated_str updated_epoch age
  now=$(date '+%s')

  for pair in "$@"; do
    pane_idx="${pair%%:*}"
    safe="${session}:${team_window}.${pane_idx}"
    safe="${safe//[-:.]/_}"
    status_file="${runtime_dir}/status/${safe}.status"

    [ -f "$status_file" ] || continue
    status=$(grep '^STATUS: ' "$status_file" 2>/dev/null | head -1 | cut -d' ' -f2-) || continue
    [ "$status" = "BOOTING" ] || continue

    # Parse the UPDATED timestamp
    updated_str=$(grep '^UPDATED: ' "$status_file" 2>/dev/null | head -1 | cut -d' ' -f2-) || continue
    [ -n "$updated_str" ] || continue
    # Cross-platform: GNU date -d, BSD date -j, python3 fallback
    updated_epoch=$(date -d "$updated_str" '+%s' 2>/dev/null) \
      || updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$updated_str" '+%s' 2>/dev/null) \
      || updated_epoch=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))" "$updated_str" 2>/dev/null) \
      || updated_epoch=""
    [ -n "$updated_epoch" ] || continue

    age=$(( now - updated_epoch ))
    if [ "$age" -ge "$timeout" ]; then
      mkdir -p "${runtime_dir}/logs"
      printf '%s WARN: pane %s:%s.%s stuck in BOOTING for %ds (timeout=%ds) — forcing READY\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$session" "$team_window" "$pane_idx" "$age" "$timeout" \
        >> "${runtime_dir}/logs/boot-timeout.log"
      write_pane_status "$runtime_dir" "${session}:${team_window}.${pane_idx}" "READY"
    fi
  done
}

# Boot multiple workers in parallel: send all launch commands, then wait once.
# Usage: _batch_boot_workers <session> <runtime_dir> <team_window> <pane_idx:worker_num> ...
# Each trailing arg is a pane_idx:worker_num pair (e.g. "1:1" "2:2" "5:3").
_batch_boot_workers() {
  local session="$1" runtime_dir="$2" team_window="$3"
  shift 3

  # Bulk-read env values (avoids ~12 forks from _env_val calls)
  local _bbw_acronym="" _bbw_worker_model="" _bbw_team_type="" _bbw_reserved=""
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
        RESERVED) _bbw_reserved="${_bbw_env_raw//\"/}" ;;
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
    doey_send_command "$session:${team_window}.${_bbw_cur_pane}" "${_DRAIN_STDIN}${_bbw_cur_cmd}"
    if [ "$_bbw_reserved" = "true" ] || [ "$_bbw_is_freelancer" = "true" ]; then
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

  # Phase 4: Schedule background boot-timeout watchdog
  if [ "$_bbw_count" -gt 0 ]; then
    (
      sleep "${DOEY_BOOT_TIMEOUT:-60}"
      _check_boot_timeouts "$runtime_dir" "$session" "$team_window" "$@"
    ) &
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

  local _dac_panes_added=2

  # Name panes sequentially
  local _dac_w_i=1
  local w1_num=$(( _ts_worker_count + _dac_w_i ))
  tmux select-pane -t "$session:$team_window.${new_pane_top}" -T "T${team_window} ${_pane_prefix}${w1_num}"
  _dac_w_i=$((_dac_w_i + 1))

  local w2_num=$(( _ts_worker_count + _dac_w_i ))
  tmux select-pane -t "$session:$team_window.${new_pane_bottom}" -T "T${team_window} ${_pane_prefix}${w2_num}"
  _dac_w_i=$((_dac_w_i + 1))

  local _rps_include_p0="false"
  [ "$_ts_team_type" = "freelancer" ] && _rps_include_p0="true"
  rebuild_pane_state "$session:$team_window" "$_rps_include_p0"

  local new_worker_count=$(( _ts_worker_count + _dac_panes_added ))
  write_team_env "$runtime_dir" "$team_window" "dynamic" "$_worker_panes" "$new_worker_count" "" "$_ts_wt_dir" "$_ts_wt_branch" "$_ts_team_name" "$_ts_team_role" "$_ts_worker_model" "$_ts_manager_model" "$_ts_team_type" "" "$_ts_reserved"

  _batch_boot_workers "$session" "$runtime_dir" "$team_window" "${new_pane_top}:${w1_num}" "${new_pane_bottom}:${w2_num}"
  rebalance_grid_layout "$session" "$team_window" "$runtime_dir"

  doey_ok "Added ${_pane_prefix}${w1_num} and ${_pane_prefix}${w2_num} — ${new_worker_count} workers in $((_ts_cols + 1)) columns"
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

  # Resolve pane indices to stable pane IDs before killing
  local remove_top_id remove_bottom_id
  remove_top_id=$(tmux display-message -t "$session:$team_window.${remove_top}" -p '#{pane_id}' 2>/dev/null || true)
  remove_bottom_id=$(tmux display-message -t "$session:$team_window.${remove_bottom}" -p '#{pane_id}' 2>/dev/null || true)

  # Stop processes in both panes (using stable pane IDs)
  local _rc_pid _rc_ppid
  for _rc_pid in "$remove_top_id" "$remove_bottom_id"; do
    [ -z "$_rc_pid" ] && continue
    _rc_ppid=$(tmux display-message -t "$_rc_pid" -p '#{pane_pid}' 2>/dev/null || true)
    [ -n "$_rc_ppid" ] && pkill -P "$_rc_ppid" 2>/dev/null || true
  done
  sleep 0.2  # Wait for process termination

  # Kill using stable pane IDs (no index shift issues)
  [ -n "$remove_top_id" ] && tmux kill-pane -t "$remove_top_id" 2>/dev/null || true
  [ -n "$remove_bottom_id" ] && tmux kill-pane -t "$remove_bottom_id" 2>/dev/null || true
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
  local current
  current=$(read_team_windows "$runtime_dir")
  if [ -z "$current" ]; then
    _set_session_env "$runtime_dir" TEAM_WINDOWS "$window_index"
  else
    _set_session_env "$runtime_dir" TEAM_WINDOWS "${current},${window_index}"
  fi
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
    mgr_agent=$(generate_team_agent "doey-subtaskmaster" "$window_index")
  fi
  local _proj="${session#doey-}"
  local _mgr_name="${mgr_name_override:-T${window_index} ${DOEY_ROLE_TEAM_LEAD}}"
  local _mgr_pane_title="${mgr_pane_title_override:-${_proj} T${window_index} Mgr}"
  local _mgr_cmd="claude --dangerously-skip-permissions --model $mgr_model --name \"${_mgr_name}\" --agent \"$mgr_agent\""
  _append_settings _mgr_cmd "$runtime_dir"
  doey_send_command "${session}:${window_index}.0" "${_DRAIN_STDIN}${_mgr_cmd}"
  tmux select-pane -t "${session}:${window_index}.0" -T "$_mgr_pane_title"
  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"

  # Background boot-timeout watchdog for manager pane
  (
    sleep "${DOEY_BOOT_TIMEOUT:-60}"
    _check_boot_timeouts "$runtime_dir" "$session" "$window_index" "0:0"
  ) &
}

_brief_team() {
  local session="$1" window_index="$2" wp_list="$3"
  local worker_count="$4" grid_desc="$5" wt_brief="${6:-}"
  local team_name="${7:-}" team_role="${8:-}"
  local _role_brief=""
  [ -n "$team_role" ] && _role_brief=" Team role: ${team_role}."
  (
    sleep "$DOEY_MANAGER_BRIEF_DELAY"
    doey_send_verified "${session}:${window_index}.0" \
      "Team is online in window ${window_index}. ${grid_desc} — ${worker_count} workers. Your workers are in panes ${wp_list}. ${DOEY_ROLE_COORDINATOR} monitors all teams from the Core Team window. Session: ${session}.${wt_brief}${_role_brief} All workers are idle and awaiting tasks. What should we work on?" || true
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
  mgr_agent=$(_env_val "$env_file" PANE_0_AGENT "doey-subtaskmaster")
  mgr_name=$(_env_val "$env_file" PANE_0_NAME "Manager")
  local mgr_agent_name
  mgr_agent_name=$(generate_team_agent "$mgr_agent" "$window_index")
  local mgr_model="${td_manager_model:-$DOEY_MANAGER_MODEL}"
  local _mgr_cmd="claude --dangerously-skip-permissions --model $mgr_model --agent \"$mgr_agent_name\" --name \"${mgr_name}\""
  _append_settings _mgr_cmd "$runtime_dir"
  doey_send_command "${session}:${window_index}.0" "${_DRAIN_STDIN}${_mgr_cmd}"
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
    doey_send_command "${session}:${window_index}.${_w_i}" "${_DRAIN_STDIN}${_w_cmd}"
    tmux select-pane -t "${session}:${window_index}.${_w_i}" -T "$w_name"
    # Write READY status so Taskmaster/Subtaskmaster can dispatch immediately
    write_pane_status "$runtime_dir" "${session}:${window_index}.${_w_i}" "READY"
    _w_i=$((_w_i + 1))
  done

  # Write READY for manager pane (matches _launch_team_manager pattern)
  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"

  # Schedule background boot-timeout watchdog (matches _batch_boot_workers Phase 4)
  if [ "$max_pane" -gt 0 ]; then
    local _atd_pairs="" _atd_k=1
    while [ "$_atd_k" -le "$max_pane" ]; do
      _atd_pairs="${_atd_pairs} ${_atd_k}:${_atd_k}"
      _atd_k=$((_atd_k + 1))
    done
    (
      sleep "${DOEY_BOOT_TIMEOUT:-60}"
      _check_boot_timeouts "$runtime_dir" "$session" "$window_index" $_atd_pairs
    ) &
  fi

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
      doey_send_verified "${session}:${window_index}.0" "$_brief_text" || true
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
  local reserved="${11:-false}"
  local task_id="${12:-}"
  # --reserved implies freelancer team type if not already set
  if [ "$reserved" = "true" ] && [ -z "$team_type" ]; then
    team_type="freelancer"
  fi
  local team_dir="$dir" worktree_branch="" wt_dir_for_env=""
  local is_freelancer="false"
  [ "$team_type" = "freelancer" ] && is_freelancer="true"

  # Freelancer teams: panes 0+1 form the base column (F0, F1).
  # Extra columns beyond the base are added by the loop below.
  # If caller specified columns (e.g. --grid 3x2 → initial_cols=3), subtract 1
  # for the base column. If no columns specified, default to 0 extra.
  if [ "$is_freelancer" = "true" ]; then
    if [ -n "${4:-}" ] && [ "$initial_cols" -gt 0 ] 2>/dev/null; then
      initial_cols=$((initial_cols - 1))
    else
      initial_cols=0
    fi
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

  write_team_env "$runtime_dir" "$window_index" "dynamic" "" "0" "$mgr_pane" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model" "$team_type" "" "$reserved" "$task_id"
  _name_team_window "$session" "$window_index" "$wt_dir_for_env" "$runtime_dir"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$team_dir"

  # Only launch manager for non-freelancer teams
  if [ "$is_freelancer" = "true" ]; then
    # Freelancer: pane 0 is F0, split vertically for additional rows based on _DOEY_GRID_ROWS
    local _fl_grid_rows="${_DOEY_GRID_ROWS:-2}"
    [ "$_fl_grid_rows" -lt 1 ] 2>/dev/null && _fl_grid_rows=2

    # First split: F0 + F1
    tmux split-window -v -t "$session:${window_index}.0" -c "$team_dir"
    local _fl_p1
    _fl_p1="$(tmux list-panes -t "$session:$window_index" -F '#{pane_index}' | tail -1)"

    # Name base panes
    tmux select-pane -t "$session:${window_index}.0" -T "T${window_index} F0"
    tmux select-pane -t "$session:${window_index}.${_fl_p1}" -T "T${window_index} F1"

    local _fl_boot_args="0:0 ${_fl_p1}:1"
    local _fl_worker_count=1
    local _fl_row_i=2

    # Add extra rows beyond 2 if _fl_grid_rows > 2
    while [ "$_fl_row_i" -lt "$_fl_grid_rows" ]; do
      local _fl_extra
      _fl_extra="$(tmux split-window -v -t "$session:${window_index}.${_fl_p1}" -c "$team_dir" -P -F '#{pane_index}')"
      tmux select-pane -t "$session:${window_index}.${_fl_extra}" -T "T${window_index} F${_fl_row_i}"
      _fl_boot_args="${_fl_boot_args} ${_fl_extra}:${_fl_row_i}"
      _fl_worker_count=$((_fl_worker_count + 1))
      _fl_p1="$_fl_extra"
      _fl_row_i=$((_fl_row_i + 1))
    done

    # Batch-boot all freelancers in base column
    _batch_boot_workers "$session" "$runtime_dir" "$window_index" $_fl_boot_args

    # Update worker count: F0 is uncounted (like manager pane), others add to count
    write_team_env "$runtime_dir" "$window_index" "dynamic" "" "$_fl_worker_count" "$mgr_pane" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model" "$team_type" "" "$reserved" "$task_id"
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

  # Mark all worker panes as reserved if --reserved was passed
  if [ "$reserved" = "true" ] && [ -n "$_WPL_RESULT" ]; then
    local _rv_pane _rv_safe
    local _rv_old_ifs="$IFS"
    IFS=', '
    for _rv_pane in $_WPL_RESULT; do
      [ -z "$_rv_pane" ] && continue
      write_pane_status "$runtime_dir" "${session}:${_rv_pane}" "RESERVED"
      _rv_safe="${session}:${_rv_pane}"
      _rv_safe="${_rv_safe//[-:.]/_}"
      echo "permanent" > "${runtime_dir}/status/${_rv_safe}.reserved"
    done
    IFS="$_rv_old_ifs"
  fi

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

  if [ -z "$team_windows" ] || { [ "$team_windows" = "0" ] && [ ! -f "${runtime_dir}/team_0.env" ]; }; then
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
# 'doey' is the user-facing CLI. Subcommands like msg/status/task are
# handled by the internal doey-ctl binary, forwarded transparently here.
case "${1:-}" in
  msg|status|health|task|tmux|plan|team|config|agent|event|nudge|migrate)
    if command -v doey-ctl >/dev/null 2>&1; then
      exec doey-ctl "$@"
    else
      printf 'Error: doey CLI tools not installed. Run "doey doctor" or reinstall.\n' >&2
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
    test dispatch  Test dispatch chain reliability (requires running session)
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
        "$_aw_cols" "$_aw_wt_spec" "$_aw_name" "" "" "" "" "$_aw_reserved" "$_aw_task_id"
    else
      add_dynamic_team_window "$session" "$runtime_dir" "$dir" \
        "" "" "$_aw_name" "" "" "" "" "$_aw_reserved" "$_aw_task_id"
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
