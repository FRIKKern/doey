#!/usr/bin/env bash
# doey-new.sh — Create a new project and launch a Doey session in it.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_new_sourced:-}" = "1" ] && return 0
__doey_new_sourced=1

# ── New Project ─────────────────────────────────────────────────────

_doey_new() {
  local name="" custom_path=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --path)
        shift
        custom_path="${1:-}"
        [ -z "$custom_path" ] && { doey_error "--path requires a value"; exit 1; }
        ;;
      -*)
        doey_error "Unknown flag: $1"
        printf '  Usage: doey new <project-name> [--path /custom/path]\n' >&2
        exit 1
        ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        else
          doey_error "Unexpected argument: $1"
          printf '  Usage: doey new <project-name> [--path /custom/path]\n' >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Require a project name
  if [ -z "$name" ]; then
    doey_error "Usage: doey new <project-name> [--path /custom/path]"
    printf '\n  Creates a new project directory, initializes git, and launches Doey.\n\n' >&2
    printf '  Examples:\n' >&2
    printf '    doey new my-app\n' >&2
    printf '    doey new my-app --path /tmp/projects\n' >&2
    exit 1
  fi

  # Validate project name (alphanumeric, hyphens, underscores only)
  if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    doey_error "Invalid project name: $name"
    printf '  Allowed characters: letters, numbers, hyphens, underscores\n' >&2
    exit 1
  fi

  # Require git
  if ! command -v git >/dev/null 2>&1; then
    doey_error "git is required but not installed"
    exit 1
  fi

  # Determine target directory
  local target_dir
  if [ -n "$custom_path" ]; then
    target_dir="${custom_path}/${name}"
  else
    target_dir="$HOME/projects/${name}"
  fi

  # Check if directory already exists
  if [ -d "$target_dir" ]; then
    doey_error "Directory already exists: $target_dir"
    printf '  Use "cd %s && doey" to launch Doey in an existing project.\n' "$target_dir" >&2
    exit 1
  fi

  # Create parent directory if needed
  local parent_dir
  parent_dir="$(dirname "$target_dir")"
  if [ ! -d "$parent_dir" ]; then
    mkdir -p "$parent_dir"
  fi

  # Create project directory
  mkdir -p "$target_dir"
  printf '  %b✓ Created %s%b\n' "$SUCCESS" "$target_dir" "$RESET"

  # Initialize git
  git -C "$target_dir" init -q
  printf '  %b✓ Initialized git repository%b\n' "$SUCCESS" "$RESET"

  # Create README.md
  printf '# %s\n' "$name" > "${target_dir}/README.md"

  # Create .gitignore
  cat > "${target_dir}/.gitignore" << 'GITIGNORE'
node_modules/
.env
.env.local
__pycache__/
*.pyc
.DS_Store
dist/
build/
.vscode/
.idea/
*.log
tmp/
coverage/
GITIGNORE

  printf '  %b✓ Created README.md and .gitignore%b\n' "$SUCCESS" "$RESET"

  # Initial commit
  git -C "$target_dir" add -A
  git -C "$target_dir" commit -q -m "Initial commit"
  printf '  %b✓ Initial commit%b\n' "$SUCCESS" "$RESET"

  # Register and launch doey session
  printf '\n  Launching Doey session...\n\n'
  cd "$target_dir"
  register_project "$target_dir"
  local proj_name
  proj_name="$(find_project "$target_dir")"
  if [ -n "$proj_name" ]; then
    launch_with_grid "$proj_name" "$target_dir" "dynamic"
  fi
}
