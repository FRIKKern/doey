#!/usr/bin/env bash
# doey-update.sh — Update, reinstall, uninstall, and version functions.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_update_sourced:-}" = "1" ] && return 0
__doey_update_sourced=1

# ── Helper Functions ─────────────────────────────────────────────────

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

# ── Update: contributor path (local git repo) ────────────────────────
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
  # Check for tracked-file changes only (untracked files don't block pull --ff-only)
  # Must run BEFORE checkout — checkout can fail or discard changes on dirty trees
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
  if [[ -z "$current_branch" ]]; then
    doey_warn "Detached HEAD — checking out main"
    git -C "$repo_dir" checkout main 2>/dev/null || \
      git -C "$repo_dir" checkout -b main origin/main 2>/dev/null || true
  elif [[ "$current_branch" != "main" ]]; then
    doey_warn "On branch '$current_branch' — switching to main"
    git -C "$repo_dir" checkout main 2>/dev/null || true
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
  local install_log
  install_log="$(mktemp -t doey-install.XXXXXX.log)"
  if ! _spin "Installing files..." bash -c "DOEY_ASSUME_YES=1 bash '$repo_dir/install.sh' </dev/null >'$install_log' 2>&1"; then
    doey_error "Install failed"
    doey_info "Output (${install_log}):"
    printf '\n'
    tail -40 "$install_log" >&2 || true
    printf '\n'
    doey_info "Full log: $install_log"
    doey_info "Try manually: cd $repo_dir && ./install.sh"
    return 1
  fi
  rm -f "$install_log"
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

# ── Update: normal user path (download + install) ────────────────────
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
  local install_log
  install_log="$(mktemp -t doey-install.XXXXXX.log)"
  if ! _spin "Installing files..." bash -c "DOEY_ASSUME_YES=1 bash '$install_dir/install.sh' </dev/null >'$install_log' 2>&1"; then
    doey_error "Install failed"
    doey_info "Output (${install_log}):"
    printf '\n'
    tail -40 "$install_log" >&2 || true
    printf '\n'
    doey_info "Full log: $install_log"
    doey_info "Try downloading again: curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash"
    rm -rf "$install_dir"
    return 1
  fi
  rm -f "$install_log"
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
  local install_log
  install_log="$(mktemp -t doey-install.XXXXXX.log)"
  if ! _spin "Installing..." bash -c "DOEY_ASSUME_YES=1 bash '$install_dir/install.sh' </dev/null >'$install_log' 2>&1"; then
    doey_error "Install failed"
    doey_info "Output (${install_log}):"
    printf '\n'
    tail -40 "$install_log" >&2 || true
    printf '\n'
    doey_info "Full log: $install_log"
    [[ "$install_dir" == /tmp/* ]] && rm -rf "$install_dir"
    exit 1
  fi
  rm -f "$install_log"
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

# ── Claude Code Management ───────────────────────────────────────────

# Detect how Claude Code was installed and return the package manager name.
# Returns: brew, apt, snap, npm, standalone, or "unknown"
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

# ── Uninstall ────────────────────────────────────────────────────────
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

# ── Auto-update check ────────────────────────────────────────────────
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
