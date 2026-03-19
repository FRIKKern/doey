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

# Remove doey-* files in $1 that no longer exist in $2 (source dir)
clean_orphans() {
  local dest_dir="$1" src_dir="$2"
  for installed in "$dest_dir"/doey-*.md; do
    [ -f "$installed" ] || continue
    local_name="$(basename "$installed")"
    if [ ! -f "$src_dir/$local_name" ]; then
      rm -f "$installed"
      detail "removed orphan: $local_name"
    fi
  done
}

echo ""
printf "${BRAND}┌────────────────────────────────────────────┐${RESET}\n"
printf "${BRAND}│${RESET}  ${BOLD}Doey Installer${RESET}                             ${BRAND}│${RESET}\n"
printf "${BRAND}│${RESET}  ${DIM}Multi-agent orchestration for Claude Code${RESET}   ${BRAND}│${RESET}\n"
printf "${BRAND}└────────────────────────────────────────────┘${RESET}\n"
echo ""

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}
PLATFORM=$(detect_platform)
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

# Install a required tool via brew (macOS) or apt (Linux), or die
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
if command -v brew &>/dev/null; then
  HAS_BREW=true
fi

if command -v git &>/dev/null; then
  printf "  ${SUCCESS}✓${RESET} git\n"
else
  require_tool "git"
fi

if command -v tmux &>/dev/null; then
  TMUX_VER=$(tmux -V 2>/dev/null | head -1)
  printf "  ${SUCCESS}✓${RESET} tmux ${DIM}(%s)${RESET}\n" "$TMUX_VER"
  TMUX_MAJOR=$(echo "$TMUX_VER" | sed 's/[^0-9.]//g' | cut -d. -f1)
  if [ -n "$TMUX_MAJOR" ] && [ "$TMUX_MAJOR" -lt 3 ] 2>/dev/null; then
    warn_msg "tmux 3.0+ recommended (you have $TMUX_VER)"
  fi
else
  require_tool "tmux"
fi

if command -v node &>/dev/null; then
  NODE_VER=$(node -v 2>/dev/null | sed 's/^v//')
  NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
  if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
    printf "  ${SUCCESS}✓${RESET} Node.js ${DIM}(v%s)${RESET}\n" "$NODE_VER"
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

if command -v claude &>/dev/null; then
  printf "  ${SUCCESS}✓${RESET} claude CLI\n"
elif [ "$HAS_NODE" = true ] && ask_install "Claude Code CLI"; then
  run_install "Claude Code" "npm install -g @anthropic-ai/claude-code" || \
    warn_msg "Failed — try manually: npm i -g @anthropic-ai/claude-code"
else
  warn_msg "claude CLI not found (npm i -g @anthropic-ai/claude-code)"
fi

if command -v jq &>/dev/null; then
  printf "  ${SUCCESS}✓${RESET} jq\n"
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
  mkdir -p ~/.claude/{agents,commands,doey,agent-memory/doey-manager,agent-memory/doey-watchdog} ~/.local/bin
} && step_ok || { step_fail; die "Failed to create directories."; }

echo "$SCRIPT_DIR" > ~/.claude/doey/repo-path

INSTALLED_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
INSTALLED_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > ~/.claude/doey/version << VEOF
version=$INSTALLED_VERSION
date=$INSTALLED_DATE
repo=$SCRIPT_DIR
VEOF

# Clean up stale files from previous installs (skills → commands rename)
rm -f ~/.claude/skills/doey-*.md 2>/dev/null
rmdir ~/.claude/skills 2>/dev/null || true

shopt -s nullglob
agent_files=("$SCRIPT_DIR/agents/"*.md)
shopt -u nullglob
if [[ ${#agent_files[@]} -eq 0 ]]; then
  die "No agent files found in $SCRIPT_DIR/agents/"
fi
AGENT_COUNT=${#agent_files[@]}
printf "  ${BRAND}[2/5]${RESET} Installing agent definitions (${BOLD}%s${RESET})..." "$AGENT_COUNT"
{
  cp "${agent_files[@]}" ~/.claude/agents/
} && step_ok || { step_fail; die "Failed to copy agent definitions."; }

for f in "${agent_files[@]}"; do
  detail "$(basename "$f" .md)"
done

clean_orphans ~/.claude/agents "$SCRIPT_DIR/agents"

shopt -s nullglob
cmd_files=("$SCRIPT_DIR/commands/"*.md)
shopt -u nullglob
if [[ ${#cmd_files[@]} -eq 0 ]]; then
  die "No command files found in $SCRIPT_DIR/commands/"
fi
CMD_COUNT=${#cmd_files[@]}
printf "  ${BRAND}[3/5]${RESET} Installing slash commands (${BOLD}%s${RESET})..." "$CMD_COUNT"
{
  cp "${cmd_files[@]}" ~/.claude/commands/
} && step_ok || { step_fail; die "Failed to copy commands."; }

CMD_NAMES=""
for f in "${cmd_files[@]}"; do CMD_NAMES="${CMD_NAMES:+$CMD_NAMES, }/$(basename "$f" .md)"; done
detail "$CMD_NAMES"

clean_orphans ~/.claude/commands "$SCRIPT_DIR/commands"

printf "  ${BRAND}[4/5]${RESET} Installing doey command..."
{
  # doey.sh installs as "doey"; others keep their names
  rm -f ~/.local/bin/doey
  cp "$SCRIPT_DIR/shell/doey.sh" ~/.local/bin/doey
  chmod +x ~/.local/bin/doey
  for script in tmux-statusbar.sh pane-border-status.sh info-panel.sh; do
    rm -f "$HOME/.local/bin/$script"
    cp "$SCRIPT_DIR/shell/$script" "$HOME/.local/bin/$script"
    chmod +x "$HOME/.local/bin/$script"
  done
} && step_ok || { step_fail; die "Failed to install doey to ~/.local/bin."; }
detail "~/.local/bin/doey"

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
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %-2s slash commands                    ${SUCCESS}│${RESET}\n" "$CMD_COUNT"
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
