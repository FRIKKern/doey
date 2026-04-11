#!/usr/bin/env bash
# Install the Doey system
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BRAND='\033[1;36m'  SUCCESS='\033[0;32m'  DIM='\033[0;90m'
WARN='\033[0;33m'   ERROR='\033[0;31m'   BOLD='\033[1m'   RESET='\033[0m'

# Source shared Go helpers
source "$(dirname "$0")/shell/doey-go-helpers.sh" 2>/dev/null || true

step_ok()   { printf "   ${SUCCESS}✓${RESET}\n"; }
step_fail() { printf "   ${ERROR}✗${RESET}\n"; }
detail()    { printf "         ${DIM}→ %s${RESET}\n" "$1"; }
warn_msg()  { printf "  ${WARN}⚠  %s${RESET}\n" "$1"; }
err_msg()   { printf "  ${ERROR}✗  %s${RESET}\n" "$1"; }

die() {
  echo ""
  err_msg "$1"
  [ -n "${2:-}" ] && printf "     ${DIM}%s${RESET}\n" "$2"
  echo ""
  exit 1
}

clean_orphans() {
  local dest="$1" src="$2"
  for f in "$dest"/doey-*.md; do
    [ -f "$f" ] || continue
    [ -f "$src/$(basename "$f")" ] || { rm -f "$f"; detail "removed orphan: $(basename "$f")"; }
  done
}

# Glob .md files from src, copy to dest, clean orphans. Sets _COUNT.
install_md_files() {
  local src="$1" dest="$2" step="$3" label="$4"
  shopt -s nullglob
  _files=("$src/"*.md)
  shopt -u nullglob
  [ ${#_files[@]} -gt 0 ] || die "No files found in $src/"
  _COUNT=${#_files[@]}
  printf "  ${BRAND}[%s]${RESET} Installing %s (${BOLD}%s${RESET})..." "$step" "$label" "$_COUNT"
  cp "${_files[@]}" "$dest/" && step_ok || { step_fail; die "Failed to copy $label."; }
  clean_orphans "$dest" "$src"
}

echo ""
printf "${BRAND}┌────────────────────────────────────────────┐${RESET}\n"
printf "${BRAND}│${RESET}  ${BOLD}Doey Installer${RESET}                             ${BRAND}│${RESET}\n"
printf "${BRAND}│${RESET}  ${DIM}Multi-agent orchestration for Claude Code${RESET}   ${BRAND}│${RESET}\n"
printf "${BRAND}└────────────────────────────────────────────┘${RESET}\n"
echo ""

case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *)      PLATFORM="unknown" ;;
esac
IS_INTERACTIVE=false
[ -t 0 ] && IS_INTERACTIVE=true

ask_install() {
  local name="$1"
  printf "  ${WARN}⚠${RESET}  ${BOLD}%s${RESET} is not installed.\n" "$name"
  if [ "$IS_INTERACTIVE" = true ]; then
    printf "     Install it now? ${DIM}[Y/n]${RESET} "
    read -r reply
    case "$reply" in
      [Nn]*) return 1 ;;
      *)     return 0 ;;
    esac
  else
    return 1
  fi
}

run_install() {
  local name="$1" cmd="$2"
  printf "     ${DIM}Running: %s${RESET}\n" "$cmd"
  if bash -c "$cmd"; then
    printf "  ${SUCCESS}✓${RESET} %s installed successfully\n" "$name"
    return 0
  else
    printf "  ${ERROR}✗${RESET} Failed to install %s\n" "$name"
    return 1
  fi
}

require_tool() {
  local name="$1" pkg="${2:-$1}"
  if ask_install "$name"; then
    case "$PLATFORM" in
      macos)
        [ "$HAS_BREW" = true ] || die "$name is not installed and Homebrew is not available." \
            "Install Homebrew first: https://brew.sh  — then re-run this installer."
        run_install "$name" "brew install $pkg" || die "Failed to install $name."
        ;;
      linux)
        run_install "$name" "sudo apt-get update && sudo apt-get install -y $pkg" || die "Failed to install $name."
        ;;
      *) die "$name is not installed." "Please install $name manually and re-run this installer." ;;
    esac
  else
    die "$name is required." \
        "Install: brew install $pkg (macOS) | apt install $pkg (Linux)"
  fi
}

printf "${BOLD}  Checking prerequisites...${RESET}\n"
echo ""
HAS_NODE=false
HAS_BREW=false
command -v brew &>/dev/null && HAS_BREW=true

has() { command -v "$1" &>/dev/null; }
check_ok() { printf "  ${SUCCESS}✓${RESET} %s\n" "$*"; }

has git   && check_ok "git"   || require_tool "git"

if has tmux; then
  TMUX_VER=$(tmux -V 2>/dev/null | head -1)
  check_ok "tmux ${DIM}($TMUX_VER)${RESET}"
  TMUX_MAJOR=$(echo "$TMUX_VER" | sed 's/[^0-9.]//g' | cut -d. -f1)
  [ -n "$TMUX_MAJOR" ] && [ "$TMUX_MAJOR" -lt 3 ] 2>/dev/null && warn_msg "tmux 3.0+ recommended (you have $TMUX_VER)"
else
  require_tool "tmux"
fi

if has node; then
  NODE_VER=$(node -v 2>/dev/null | sed 's/^v//')
  NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
  if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
    check_ok "Node.js ${DIM}(v$NODE_VER)${RESET}"
    HAS_NODE=true
  else
    warn_msg "Node.js 18+ required (you have v${NODE_VER})"
  fi
fi

if [ "$HAS_NODE" = false ] && ask_install "Node.js"; then
  case "$PLATFORM" in
    macos)
      if [ "$HAS_BREW" = true ]; then
        run_install "Node.js" "brew install node" && HAS_NODE=true
      else
        warn_msg "Install Homebrew first: https://brew.sh — then: brew install node"
      fi
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        run_install "Node.js" "sudo apt-get update -qq && sudo apt-get install -y nodejs npm" && HAS_NODE=true
      else
        printf "     ${BRAND}curl -fsSL https://fnm.vercel.app/install | bash && fnm install 22${RESET}\n"
        printf "     ${DIM}Then re-run this installer.${RESET}\n"
      fi
      ;;
    *) warn_msg "Install Node.js 18+ from https://nodejs.org" ;;
  esac
elif [ "$HAS_NODE" = false ]; then
  warn_msg "Node.js is needed for Claude Code — install later from https://nodejs.org"
fi

if has claude; then
  CLAUDE_VER=$(claude --version 2>/dev/null || echo "unknown")
  check_ok "claude CLI ${DIM}($CLAUDE_VER)${RESET}"
elif [ "$HAS_NODE" = true ]; then
  if ask_install "Claude Code CLI"; then
    run_install "Claude Code" "npm install -g @anthropic-ai/claude-code" || \
      warn_msg "Failed — try: sudo npm i -g @anthropic-ai/claude-code"
    if has claude; then
      echo ""
      printf "  ${BRAND}→${RESET} Run ${BOLD}claude${RESET} once to authenticate before using Doey\n"
    fi
  else
    warn_msg "claude CLI is required — install later: npm i -g @anthropic-ai/claude-code"
  fi
else
  printf "  ${ERROR}✗${RESET}  ${BOLD}Claude Code CLI${RESET} requires Node.js\n"
  printf "     ${DIM}Install Node.js 18+ first, then: ${RESET}${BRAND}npm i -g @anthropic-ai/claude-code${RESET}\n"
fi

if has jq; then
  check_ok "jq"
else
  warn_msg "jq not found (optional — hooks will use python3 fallback)"
fi

# Detect Go binary — sets GO_BIN or leaves it empty.
_find_go() {
  if type _find_go_bin >/dev/null 2>&1; then
    GO_BIN=$(_find_go_bin 2>/dev/null) || GO_BIN=""
  else
    GO_BIN=""
    command -v go >/dev/null 2>&1 && GO_BIN="go" && return 0
    for d in /usr/local/go/bin /opt/homebrew/bin /snap/go/current/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
      [ -x "$d/go" ] && GO_BIN="$d/go" && return 0
    done
  fi
}

_find_gum() {
  command -v gum >/dev/null 2>&1 && return 0
  for d in "$HOME/go/bin" "$HOME/.local/go/bin"; do
    if [ -x "$d/gum" ]; then
      # Symlink to ~/.local/bin/ so it persists on PATH
      mkdir -p "$HOME/.local/bin"
      ln -sf "$d/gum" "$HOME/.local/bin/gum" 2>/dev/null || true
      return 0
    fi
  done
  return 1
}

if _find_gum; then
  check_ok "gum ${DIM}($(gum --version 2>/dev/null || echo 'unknown'))${RESET}"
else
  _find_go
  _gum_go_bin="$GO_BIN"
  if [ -n "$_gum_go_bin" ]; then
    printf "  ${WARN}⚠${RESET}  gum not found — installing via go install...\n"
    if "$_gum_go_bin" install github.com/charmbracelet/gum@latest 2>&1; then
      # Symlink to ~/.local/bin/ for persistent PATH access
      _gum_gopath="$("$_gum_go_bin" env GOPATH 2>/dev/null)" || _gum_gopath="$HOME/go"
      for d in "$_gum_gopath/bin" "$HOME/go/bin"; do
        if [ -x "$d/gum" ]; then
          mkdir -p "$HOME/.local/bin"
          ln -sf "$d/gum" "$HOME/.local/bin/gum" 2>/dev/null || true
          break
        fi
      done
      if _find_gum; then
        check_ok "gum installed ${DIM}($(gum --version 2>/dev/null || echo 'unknown'))${RESET}"
      else
        warn_msg "gum installed but not found on PATH — add \$(go env GOPATH)/bin to PATH"
      fi
    else
      warn_msg "gum install failed (optional — luxury CLI will use fallback)"
    fi
  else
    warn_msg "gum not found (optional — install with: go install github.com/charmbracelet/gum@latest)"
  fi
fi

if [ -f ~/.claude/agents/doey-manager.md ] && [ -f ~/.local/bin/doey ]; then
  echo ""
  warn_msg "Doey appears to already be installed."
  printf "     ${DIM}Continuing will update all files to the latest version.${RESET}\n"
fi

echo ""

printf "  ${BRAND}[1/7]${RESET} Creating directories..."
{
  mkdir -p ~/.claude/{agents,doey,agent-memory} ~/.local/bin ~/.config/doey ~/.config/doey/teams ~/.config/doey/remotes ~/.local/share/doey/teams
} && step_ok || { step_fail; die "Failed to create directories."; }

# Clean up old commands that are now project-level skills
shopt -s nullglob
for f in ~/.claude/commands/doey-*.md; do rm -f "$f"; done
shopt -u nullglob

# Only save repo-path if it's a persistent directory (not a temp dir)
case "$SCRIPT_DIR" in
  /tmp/*|/var/folders/*) ;; # Don't save temp paths — would break future 'doey update'
  *) echo "$SCRIPT_DIR" > "$HOME/.claude/doey/repo-path" ;;
esac

INSTALLED_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
INSTALLED_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > ~/.claude/doey/version << VEOF
version=$INSTALLED_VERSION
date=$INSTALLED_DATE
repo=$SCRIPT_DIR
VEOF

# Expand role templates before installing agents
if [ -x "$SCRIPT_DIR/shell/expand-templates.sh" ]; then
  bash "$SCRIPT_DIR/shell/expand-templates.sh" >/dev/null 2>&1 || true
fi

install_md_files "$SCRIPT_DIR/agents" ~/.claude/agents "2/7" "agent definitions"
AGENT_COUNT=$_COUNT
for f in "${_files[@]}"; do detail "$(basename "$f" .md)"; done

printf "  ${BRAND}[3/7]${RESET} Installing premade teams..."
shopt -s nullglob
_team_files=("$SCRIPT_DIR/teams/"*.team.md)
shopt -u nullglob
TEAM_COUNT=${#_team_files[@]}
if [ "$TEAM_COUNT" -gt 0 ]; then
  cp "${_team_files[@]}" ~/.local/share/doey/teams/ && step_ok || { step_fail; die "Failed to copy team definitions."; }
  for f in "${_team_files[@]}"; do detail "$(basename "$f" .team.md)"; done
else
  step_ok
  detail "no team definitions found (skipped)"
  TEAM_COUNT=0
fi

printf "  ${BRAND}[4/7]${RESET} Installing skills..."
# Skills live in .claude/skills/ (project-level, auto-discovered)
# Count them for the summary
shopt -s nullglob
_skill_dirs=("$SCRIPT_DIR/.claude/skills"/doey-*/)
shopt -u nullglob
SKILL_COUNT=${#_skill_dirs[@]}
if [ "$SKILL_COUNT" -gt 0 ]; then
  step_ok
  detail "$SKILL_COUNT skills (project-level, auto-discovered)"
else
  step_fail
  die "No skills found in .claude/skills/"
fi

install_script() { rm -f "$2"; cp "$1" "$2"; chmod +x "$2"; }

printf "  ${BRAND}[5/7]${RESET} Installing doey command..."
{
  install_script "$SCRIPT_DIR/shell/doey.sh" ~/.local/bin/doey
  cp "$SCRIPT_DIR/shell/doey-go-helpers.sh" "$HOME/.local/bin/doey-go-helpers.sh"
  cp "$SCRIPT_DIR/shell/doey-task-helpers.sh" "$HOME/.local/bin/doey-task-helpers.sh"
  cp "$SCRIPT_DIR/shell/doey-render-task.sh" "$HOME/.local/bin/doey-render-task.sh"
  cp "$SCRIPT_DIR/shell/doey-roles.sh" "$HOME/.local/bin/doey-roles.sh"
  cp "$SCRIPT_DIR/shell/doey-send.sh" "$HOME/.local/bin/doey-send.sh"
  cp "$SCRIPT_DIR/shell/doey-helpers.sh" "$HOME/.local/bin/doey-helpers.sh"
  cp "$SCRIPT_DIR/shell/doey-ui.sh" "$HOME/.local/bin/doey-ui.sh"
  cp "$SCRIPT_DIR/shell/doey-remote.sh" "$HOME/.local/bin/doey-remote.sh"
  cp "$SCRIPT_DIR/shell/doey-purge.sh" "$HOME/.local/bin/doey-purge.sh"
  cp "$SCRIPT_DIR/shell/doey-update.sh" "$HOME/.local/bin/doey-update.sh"
  cp "$SCRIPT_DIR/shell/doey-doctor.sh" "$HOME/.local/bin/doey-doctor.sh"
  cp "$SCRIPT_DIR/shell/doey-task-cli.sh" "$HOME/.local/bin/doey-task-cli.sh"
  cp "$SCRIPT_DIR/shell/doey-test-runner.sh" "$HOME/.local/bin/doey-test-runner.sh"
  cp "$SCRIPT_DIR/shell/doey-grid.sh" "$HOME/.local/bin/doey-grid.sh"
  cp "$SCRIPT_DIR/shell/doey-menu.sh" "$HOME/.local/bin/doey-menu.sh"
  cp "$SCRIPT_DIR/shell/doey-team-mgmt.sh" "$HOME/.local/bin/doey-team-mgmt.sh"
  cp "$SCRIPT_DIR/shell/doey-mcp.sh" "$HOME/.local/bin/doey-mcp.sh"
  cp "$SCRIPT_DIR/shell/doey-session.sh" "$HOME/.local/bin/doey-session.sh"
  cp "$SCRIPT_DIR/shell/doey-headless.sh" "$HOME/.local/bin/doey-headless.sh"
  chmod +x "$HOME/.local/bin/doey-headless.sh"
  install_script "$SCRIPT_DIR/shell/intent-fallback.sh" "$HOME/.local/bin/intent-fallback.sh"
  install_script "$SCRIPT_DIR/shell/doey-intent-dispatch.sh" "$HOME/.local/bin/doey-intent-dispatch.sh"
  install_script "$SCRIPT_DIR/shell/doey-tunnel.sh" "$HOME/.local/bin/doey-tunnel.sh"
  install_script "$SCRIPT_DIR/shell/doey-tunnel-detect.sh" "$HOME/.local/bin/doey-tunnel-detect.sh"
  cp "$SCRIPT_DIR/shell/masterplan-tui.sh" "$HOME/.local/bin/masterplan-tui.sh"
  install_script "$SCRIPT_DIR/shell/doey-masterplan-spawn.sh" "$HOME/.local/bin/doey-masterplan-spawn.sh"
  for s in tmux-statusbar.sh tmux-theme.sh pane-border-status.sh info-panel.sh settings-panel.sh tmux-settings-btn.sh doey-statusline.sh doey-remote-provision.sh; do
    install_script "$SCRIPT_DIR/shell/$s" "$HOME/.local/bin/$s"
  done
} && step_ok || { step_fail; die "Failed to install doey to ~/.local/bin."; }
detail "~/.local/bin/doey"

# Install default config template if user has no config yet
if [ ! -f "${HOME}/.config/doey/config.sh" ] && [ -f "$SCRIPT_DIR/shell/doey-config-default.sh" ]; then
  cp "$SCRIPT_DIR/shell/doey-config-default.sh" "${HOME}/.config/doey/config.sh"
  detail "installed default config"
fi

# Build all Go binaries from the centralized target list in doey-go-helpers.sh.
# Returns 0 on success (doey-tui built), non-zero if doey-tui fails.
_build_tui() {
  # Source the shared helper for the targets list
  source "$SCRIPT_DIR/shell/doey-go-helpers.sh" 2>/dev/null || true

  local tui_rc=0 line name module_dir build_target output_path first=true

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%|*}"; line="${line#*|}"
    module_dir="${line%%|*}"; line="${line#*|}"
    build_target="${line%%|*}"; line="${line#*|}"
    output_path="$line"

    if [ "$first" = true ]; then
      # First target (doey-tui) — its failure is fatal
      first=false
      set +e
      if type _build_go_binary >/dev/null 2>&1; then
        _build_go_binary "$module_dir" "$build_target" "$output_path"
      else
        (cd "$SCRIPT_DIR/$module_dir" && "$GO_BIN" mod tidy 2>/dev/null && "$GO_BIN" build -o "$output_path" "$build_target")
      fi
      tui_rc=$?
      set -e
      if [ $tui_rc -eq 0 ]; then
        step_ok
        detail "~/.local/bin/${name} (built from source)"
      else
        step_fail
        warn_msg "${name} build failed — info-panel.sh will be used as fallback"
        return $tui_rc
      fi
    else
      # Remaining targets — optional, don't fail the install
      printf "         ${DIM}→ building ${name}...${RESET}"
      set +e
      if type _build_go_binary >/dev/null 2>&1; then
        _build_go_binary "$module_dir" "$build_target" "$output_path" 2>/dev/null
      else
        (cd "$SCRIPT_DIR/$module_dir" && "$GO_BIN" build -o "$output_path" "$build_target") 2>/dev/null
      fi
      local _brc=$?
      set -e
      if [ $_brc -eq 0 ] && [ -x "$output_path" ]; then
        printf " ${SUCCESS}✓${RESET}\n"
        detail "~/.local/bin/${name} (built from source)"
      else
        printf " ${DIM}skipped${RESET}\n"
      fi
    fi
  done <<EOF
${_DOEY_GO_TARGETS}
EOF

  return $tui_rc
}

printf "  ${BRAND}[6/7]${RESET} Installing doey-tui..."
if [ -d "$SCRIPT_DIR/tui" ]; then
  _find_go
  if [ -n "$GO_BIN" ]; then
    _build_tui
  elif [ -f "$SCRIPT_DIR/tui/go.mod" ]; then
    # Developer needs Go to build the TUI
    GO_VERSION=$(sed -n 's/^go[[:space:]][[:space:]]*//p' "$SCRIPT_DIR/tui/go.mod" | head -1)
    GO_VERSION="${GO_VERSION:-1.24}"
    printf "\n"
    warn_msg "Go not installed — required to build doey-tui (version ${GO_VERSION}+)"
    if command -v brew >/dev/null 2>&1; then
      printf "         ${DIM}→ Installing Go via Homebrew...${RESET}\n"
      set +e; brew install go 2>&1 | sed 's/^/         /'; BREW_RC=$?; set -e
      if [ $BREW_RC -eq 0 ]; then
        _find_go
        if [ -n "$GO_BIN" ]; then
          detail "Go installed — building doey-tui..."
          _build_tui
        else
          step_fail
          warn_msg "Go installed but not found in PATH — re-run install.sh after opening a new terminal"
        fi
      else
        step_fail
        warn_msg "brew install go failed — install manually from https://go.dev/dl/ (version ${GO_VERSION}+)"
        detail "info-panel.sh will be used as fallback"
      fi
    else
      printf "   ${DIM}skipped${RESET}\n"
      warn_msg "Install Go ${GO_VERSION}+ from https://go.dev/dl/ then re-run install.sh"
      detail "info-panel.sh will be used as fallback"
    fi
  else
    # Normal user install (not the Doey repo) — Go is optional
    printf "   ${DIM}skipped${RESET}\n"
    warn_msg "Go not installed — doey-tui not built (info-panel.sh will be used as fallback)"
  fi
else
  printf "   ${DIM}skipped${RESET}\n"
  detail "tui/ directory not found"
fi

# Install git hooks for Go binary rebuilds
if [ -d "$SCRIPT_DIR/.git/hooks" ]; then
  # Copy shared Go helpers so hooks can source them
  if [ -f "$SCRIPT_DIR/shell/doey-go-helpers.sh" ]; then
    cp "$SCRIPT_DIR/shell/doey-go-helpers.sh" "$SCRIPT_DIR/.git/hooks/doey-go-helpers.sh"
  fi
  for _hook in pre-commit:pre-commit-go.sh pre-push:pre-push-gate.sh; do
    _name="${_hook%%:*}"; _script="${_hook#*:}"
    if [ -f "$SCRIPT_DIR/shell/$_script" ] && [ ! "$SCRIPT_DIR/shell/$_script" -ef "$SCRIPT_DIR/.git/hooks/$_name" ]; then
      install_script "$SCRIPT_DIR/shell/$_script" "$SCRIPT_DIR/.git/hooks/$_name"
      detail "installed $_name hook for Go builds"
    fi
  done
fi

PATH_OK=true
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  PATH_OK=false
  echo ""
  warn_msg "~/.local/bin is not in your PATH"
  printf "     ${DIM}Add to your shell config (~/.zshrc or ~/.bashrc):${RESET}\n"
  printf "     ${BRAND}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}\n"
fi

printf "  ${BRAND}[7/7]${RESET} Running context audit..."
AUDIT_OUTPUT=""
AUDIT_FAILED=false
if AUDIT_OUTPUT=$(bash "$SCRIPT_DIR/shell/context-audit.sh" --repo --no-color 2>&1); then
  step_ok
else
  AUDIT_FAILED=true
  step_fail
  printf "\n%s\n\n" "$AUDIT_OUTPUT"
  warn_msg "Context audit found issues — review above before launching sessions"
fi

echo ""
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

   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
   Let me Doey for you
DOG
printf "${RESET}"
echo ""
printf "${SUCCESS}┌────────────────────────────────────────────┐${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
if [ "$AUDIT_FAILED" = true ]; then
printf "${SUCCESS}│${RESET}  ${WARN}${BOLD}Installed with warnings${RESET}  ${DIM}(see audit above)${RESET}  ${SUCCESS}│${RESET}\n"
else
printf "${SUCCESS}│${RESET}  ${SUCCESS}${BOLD}Installation complete!${RESET}                     ${SUCCESS}│${RESET}\n"
fi
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${BOLD}Installed:${RESET}                                ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %-2s agent definitions                 ${SUCCESS}│${RESET}\n" "$AGENT_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %-2s premade teams                      ${SUCCESS}│${RESET}\n" "$TEAM_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %-2s skills (project-level)              ${SUCCESS}│${RESET}\n" "$SKILL_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} doey CLI                               ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${BOLD}Quick start:${RESET}                              ${SUCCESS}│${RESET}\n"
if [ "$PATH_OK" = false ]; then
  printf "${SUCCESS}│${RESET}    ${WARN}1. Add ~/.local/bin to PATH (see above)${RESET} ${SUCCESS}│${RESET}\n"
  printf "${SUCCESS}│${RESET}    2. ${BRAND}cd /your/project${RESET}                      ${SUCCESS}│${RESET}\n"
  printf "${SUCCESS}│${RESET}    3. ${BRAND}doey${RESET}                                  ${SUCCESS}│${RESET}\n"
else
  printf "${SUCCESS}│${RESET}    1. ${BRAND}cd /your/project${RESET}                      ${SUCCESS}│${RESET}\n"
  printf "${SUCCESS}│${RESET}    2. ${BRAND}doey${RESET}                                  ${SUCCESS}│${RESET}\n"
fi
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}└────────────────────────────────────────────┘${RESET}\n"
echo ""
