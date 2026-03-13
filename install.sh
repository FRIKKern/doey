#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Install the Doey system
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ────────────────────────────────────────────────────────────
BRAND='\033[1;36m'    # Bold cyan
SUCCESS='\033[0;32m'  # Green
DIM='\033[0;90m'      # Gray
WARN='\033[0;33m'     # Yellow
ERROR='\033[0;31m'    # Red
BOLD='\033[1m'        # Bold
RESET='\033[0m'       # Reset

# ── Helpers ───────────────────────────────────────────────────────────
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

# ── Header ────────────────────────────────────────────────────────────
echo ""
printf "${BRAND}┌────────────────────────────────────────────┐${RESET}\n"
printf "${BRAND}│${RESET}  ${BOLD}Doey Installer${RESET}                             ${BRAND}│${RESET}\n"
printf "${BRAND}│${RESET}  ${DIM}Multi-agent orchestration for Claude Code${RESET}   ${BRAND}│${RESET}\n"
printf "${BRAND}└────────────────────────────────────────────┘${RESET}\n"
echo ""

# ── Prerequisite checks ──────────────────────────────────────────────
printf "${BOLD}  Checking prerequisites...${RESET}\n"

# tmux — required
if command -v tmux &>/dev/null; then
  TMUX_VER=$(tmux -V 2>/dev/null | head -1)
  printf "  ${SUCCESS}✓${RESET} tmux ${DIM}(%s)${RESET}\n" "$TMUX_VER"
else
  die "tmux is not installed — it is required." \
      "Install: brew install tmux  (macOS) | apt install tmux  (Linux)"
fi

# claude CLI — recommended
if command -v claude &>/dev/null; then
  printf "  ${SUCCESS}✓${RESET} claude CLI\n"
else
  warn_msg "claude CLI not found (install later: npm i -g @anthropic-ai/claude-code)"
fi

# Already installed?
if [ -f ~/.claude/agents/doey-manager.md ] && [ -f ~/.local/bin/doey ]; then
  echo ""
  warn_msg "Doey appears to already be installed."
  printf "     ${DIM}Continuing will update all files to the latest version.${RESET}\n"
fi

echo ""

# ── Step 1: Directories ──────────────────────────────────────────────
printf "  ${BRAND}[1/5]${RESET} Creating directories..."
{
  mkdir -p ~/.claude/agents
  mkdir -p ~/.claude/commands
  mkdir -p ~/.claude/doey
  mkdir -p ~/.claude/agent-memory/doey-manager
  mkdir -p ~/.claude/agent-memory/doey-watchdog
  mkdir -p ~/.local/bin
} && step_ok || { step_fail; die "Failed to create directories."; }

# Save repo location so /doey-reinstall can find it later
echo "$SCRIPT_DIR" > ~/.claude/doey/repo-path

# Write version info
INSTALLED_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
INSTALLED_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > ~/.claude/doey/version << VEOF
version=$INSTALLED_VERSION
date=$INSTALLED_DATE
repo=$SCRIPT_DIR
VEOF

# ── Clean up stale files from previous installs ───────────────────────
# Skills were moved from ~/.claude/skills/ to ~/.claude/commands/ in v0.2
rm -f ~/.claude/skills/doey-*.md 2>/dev/null
# Remove any orphaned skills directory if empty
rmdir ~/.claude/skills 2>/dev/null || true

# ── Step 2: Agent definitions ─────────────────────────────────────────
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

# Remove orphaned doey-* agents no longer in the repo
for installed in ~/.claude/agents/doey-*.md; do
  [[ -f "$installed" ]] || continue
  local_name="$(basename "$installed")"
  if [[ ! -f "$SCRIPT_DIR/agents/$local_name" ]]; then
    rm -f "$installed"
    detail "removed orphan: $local_name"
  fi
done

# ── Step 3: Slash commands ───────────────────────────────────────────
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

# Show command names in a compact line
CMD_NAMES=""
for f in "${cmd_files[@]}"; do
  NAME=$(basename "$f" .md)
  if [ -z "$CMD_NAMES" ]; then
    CMD_NAMES="/$NAME"
  else
    CMD_NAMES="$CMD_NAMES, /$NAME"
  fi
done
detail "$CMD_NAMES"

# Remove orphaned doey-* commands no longer in the repo
for installed in ~/.claude/commands/doey-*.md; do
  [[ -f "$installed" ]] || continue
  local_name="$(basename "$installed")"
  if [[ ! -f "$SCRIPT_DIR/commands/$local_name" ]]; then
    rm -f "$installed"
    detail "removed orphan: $local_name"
  fi
done

# ── Step 4: CLI script ───────────────────────────────────────────────

printf "  ${BRAND}[4/5]${RESET} Installing doey command..."
{
  cp "$SCRIPT_DIR/shell/doey.sh" ~/.local/bin/doey
  chmod +x ~/.local/bin/doey
  cp "$SCRIPT_DIR/shell/tmux-statusbar.sh" "$HOME/.local/bin/tmux-statusbar.sh"
  chmod +x "$HOME/.local/bin/tmux-statusbar.sh"
  cp "$SCRIPT_DIR/shell/pane-border-status.sh" "$HOME/.local/bin/pane-border-status.sh"
  chmod +x "$HOME/.local/bin/pane-border-status.sh"
} && step_ok || { step_fail; die "Failed to install doey to ~/.local/bin."; }
detail "~/.local/bin/doey"

# Check if ~/.local/bin is on PATH
PATH_OK=true
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  PATH_OK=false
  echo ""
  warn_msg "~/.local/bin is not in your PATH"
  printf "     ${DIM}Add to your shell config (~/.zshrc or ~/.bashrc):${RESET}\n"
  printf "     ${BRAND}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}\n"
fi

# ── Step 5: Context audit ───────────────────────────────────────────
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

# ── Summary ───────────────────────────────────────────────────────────
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
