#!/usr/bin/env bash
# Install the Doey system
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BRAND='\033[1;36m'  SUCCESS='\033[0;32m'  DIM='\033[0;90m'
WARN='\033[0;33m'   ERROR='\033[0;31m'   BOLD='\033[1m'   RESET='\033[0m'

step_ok()   { printf "   ${SUCCESS}✓${RESET}\n"; }
step_fail() { printf "   ${ERROR}✗${RESET}\n"; }
detail()    { printf "         ${DIM}→ %s${RESET}\n" "$1"; }
warn_msg()  { printf "  ${WARN}⚠  %s${RESET}\n" "$1"; }
err_msg()   { printf "  ${ERROR}✗  %s${RESET}\n" "$1"; }

die() {
  echo ""
  err_msg "$1"
  [ "${2:-}" ] && printf "     ${DIM}%s${RESET}\n" "$2"
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
    printf "     Install it now? ${DIM}[y/N]${RESET} "
    read -r reply
    case "$reply" in
      [Yy]*) return 0 ;;
      *)     return 1 ;;
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
    macos) [ "$HAS_BREW" = true ] && run_install "Node.js" "brew install node" && HAS_NODE=true \
           || warn_msg "Install Homebrew (https://brew.sh) then: brew install node" ;;
    linux) printf "     ${BRAND}curl -fsSL https://fnm.vercel.app/install | bash && fnm install 22${RESET}\n"
           printf "     ${DIM}Then re-run this installer.${RESET}\n" ;;
    *)     warn_msg "Install Node.js 18+ from https://nodejs.org" ;;
  esac
elif [ "$HAS_NODE" = false ]; then
  warn_msg "Node.js is needed for Claude Code — install later from https://nodejs.org"
fi

if has claude; then
  check_ok "claude CLI"
elif [ "$HAS_NODE" = true ] && ask_install "Claude Code CLI"; then
  run_install "Claude Code" "npm install -g @anthropic-ai/claude-code" || \
    warn_msg "Failed — try manually: npm i -g @anthropic-ai/claude-code"
else
  warn_msg "claude CLI not found (npm i -g @anthropic-ai/claude-code)"
fi

if has jq; then
  check_ok "jq"
else
  warn_msg "jq not found (optional — hooks will use python3 fallback)"
fi

if [ -f ~/.claude/agents/doey-manager.md ] && [ -f ~/.local/bin/doey ]; then
  echo ""
  warn_msg "Doey appears to already be installed."
  printf "     ${DIM}Continuing will update all files to the latest version.${RESET}\n"
fi

echo ""

printf "  ${BRAND}[1/5]${RESET} Creating directories..."
{
  mkdir -p ~/.claude/{agents,doey,agent-memory/doey-manager,agent-memory/doey-watchdog} ~/.local/bin ~/.config/doey
} && step_ok || { step_fail; die "Failed to create directories."; }

# Clean up old commands that are now project-level skills
for f in ~/.claude/commands/doey-*.md; do
  [ -f "$f" ] && rm -f "$f"
done

echo "$SCRIPT_DIR" > ~/.claude/doey/repo-path

INSTALLED_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
INSTALLED_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > ~/.claude/doey/version << VEOF
version=$INSTALLED_VERSION
date=$INSTALLED_DATE
repo=$SCRIPT_DIR
VEOF

install_md_files "$SCRIPT_DIR/agents" ~/.claude/agents "2/5" "agent definitions"
AGENT_COUNT=$_COUNT
for f in "${_files[@]}"; do detail "$(basename "$f" .md)"; done

printf "  ${BRAND}[3/5]${RESET} Installing skills..."
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

printf "  ${BRAND}[4/5]${RESET} Installing doey command..."
{
  install_script "$SCRIPT_DIR/shell/doey.sh" ~/.local/bin/doey
  for s in tmux-statusbar.sh tmux-theme.sh pane-border-status.sh info-panel.sh settings-panel.sh; do
    install_script "$SCRIPT_DIR/shell/$s" "$HOME/.local/bin/$s"
  done
} && step_ok || { step_fail; die "Failed to install doey to ~/.local/bin."; }
detail "~/.local/bin/doey"

# Install default config template if user has no config yet
if [ ! -f "${HOME}/.config/doey/config.sh" ]; then
  mkdir -p "${HOME}/.config/doey"
  if [ -f "$SCRIPT_DIR/shell/doey-config-default.sh" ]; then
    cp "$SCRIPT_DIR/shell/doey-config-default.sh" "${HOME}/.config/doey/config.sh"
    detail "installed default config"
  fi
fi

PATH_OK=true
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  PATH_OK=false
  echo ""
  warn_msg "~/.local/bin is not in your PATH"
  printf "     ${DIM}Add to your shell config (~/.zshrc or ~/.bashrc):${RESET}\n"
  printf "     ${BRAND}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}\n"
fi

printf "  ${BRAND}[5/5]${RESET} Running context audit..."
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
