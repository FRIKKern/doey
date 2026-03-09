#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Install the TMUX Claude Team system
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
printf "${BRAND}│${RESET}  ${BOLD}Claude Team Installer${RESET}                      ${BRAND}│${RESET}\n"
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
if [ -f ~/.claude/agents/tmux-manager.md ] && [ -f ~/.local/bin/claude-team ]; then
  echo ""
  warn_msg "Claude Team appears to already be installed."
  printf "     ${DIM}Continuing will update all files to the latest version.${RESET}\n"
fi

echo ""

# ── Step 1: Directories ──────────────────────────────────────────────
printf "  ${BRAND}[1/4]${RESET} Creating directories..."
{
  mkdir -p ~/.claude/agents
  mkdir -p ~/.claude/commands
  mkdir -p ~/.claude/claude-team
  mkdir -p ~/.claude/agent-memory/tmux-manager
  mkdir -p ~/.claude/agent-memory/tmux-watchdog
  mkdir -p ~/.local/bin
} && step_ok || { step_fail; die "Failed to create directories."; }

# Save repo location so /tmux-reinstall can find it later
echo "$SCRIPT_DIR" > ~/.claude/claude-team/repo-path

# Clean up stale files from previous installs
# Skills were moved from ~/.claude/skills/ to ~/.claude/commands/ in v0.2
rm -f ~/.claude/skills/tmux-*.md 2>/dev/null
# Remove any orphaned skills directory if empty
rmdir ~/.claude/skills 2>/dev/null || true

# ── Step 2: Agent definitions ─────────────────────────────────────────
AGENT_COUNT=$(find "$SCRIPT_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
printf "  ${BRAND}[2/4]${RESET} Installing agent definitions (${BOLD}%s${RESET})..." "$AGENT_COUNT"
{
  cp "$SCRIPT_DIR/agents/"*.md ~/.claude/agents/
} && step_ok || { step_fail; die "Failed to copy agent definitions."; }

for f in "$SCRIPT_DIR/agents/"*.md; do
  detail "$(basename "$f" .md)"
done

# ── Step 3: Slash commands ───────────────────────────────────────────
CMD_COUNT=$(find "$SCRIPT_DIR/commands" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
printf "  ${BRAND}[3/4]${RESET} Installing slash commands (${BOLD}%s${RESET})..." "$CMD_COUNT"
{
  cp "$SCRIPT_DIR/commands/"*.md ~/.claude/commands/
} && step_ok || { step_fail; die "Failed to copy commands."; }

# Show command names in a compact line
CMD_NAMES=""
for f in "$SCRIPT_DIR/commands/"*.md; do
  NAME=$(basename "$f" .md)
  if [ -z "$CMD_NAMES" ]; then
    CMD_NAMES="/$NAME"
  else
    CMD_NAMES="$CMD_NAMES, /$NAME"
  fi
done
detail "$CMD_NAMES"

# ── Step 4: CLI script ───────────────────────────────────────────────
printf "  ${BRAND}[4/4]${RESET} Installing claude-team command..."
{
  cp "$SCRIPT_DIR/shell/claude-team.sh" ~/.local/bin/claude-team
  chmod +x ~/.local/bin/claude-team
} && step_ok || { step_fail; die "Failed to install claude-team to ~/.local/bin."; }
detail "~/.local/bin/claude-team"

# Check if ~/.local/bin is on PATH
PATH_OK=true
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  PATH_OK=false
  echo ""
  warn_msg "~/.local/bin is not in your PATH"
  printf "     ${DIM}Add to your shell config (~/.zshrc or ~/.bashrc):${RESET}\n"
  printf "     ${BRAND}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}\n"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
printf "${SUCCESS}┌────────────────────────────────────────────┐${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${SUCCESS}${BOLD}Installation complete!${RESET}                     ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${BOLD}Installed:${RESET}                                ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %s agent definitions                  ${SUCCESS}│${RESET}\n" "$AGENT_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %s slash commands                     ${SUCCESS}│${RESET}\n" "$CMD_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} claude-team CLI                       ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${BOLD}Quick start:${RESET}                              ${SUCCESS}│${RESET}\n"
if [ "$PATH_OK" = false ]; then
  printf "${SUCCESS}│${RESET}    ${WARN}1. Add ~/.local/bin to PATH (see above)${RESET} ${SUCCESS}│${RESET}\n"
  printf "${SUCCESS}│${RESET}    2. ${BRAND}cd /your/project${RESET}                      ${SUCCESS}│${RESET}\n"
  printf "${SUCCESS}│${RESET}    3. ${BRAND}claude-team${RESET}                            ${SUCCESS}│${RESET}\n"
else
  printf "${SUCCESS}│${RESET}    1. ${BRAND}cd /your/project${RESET}                      ${SUCCESS}│${RESET}\n"
  printf "${SUCCESS}│${RESET}    2. ${BRAND}claude-team${RESET}                            ${SUCCESS}│${RESET}\n"
fi
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}└────────────────────────────────────────────┘${RESET}\n"
echo ""
