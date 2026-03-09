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
if [ -f ~/.claude/agents/tmux-manager.md ] && grep -q "claude-team.sh" ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null; then
  echo ""
  warn_msg "Claude Team appears to already be installed."
  printf "     ${DIM}Continuing will update all files to the latest version.${RESET}\n"
fi

echo ""

# ── Step 1: Directories ──────────────────────────────────────────────
printf "  ${BRAND}[1/4]${RESET} Creating directories..."
{
  mkdir -p ~/.claude/agents
  mkdir -p ~/.claude/skills
  mkdir -p ~/.claude/agent-memory/tmux-manager
  mkdir -p ~/.claude/agent-memory/tmux-watchdog
} && step_ok || { step_fail; die "Failed to create directories."; }

# ── Step 2: Agent definitions ─────────────────────────────────────────
AGENT_COUNT=$(find "$SCRIPT_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
printf "  ${BRAND}[2/4]${RESET} Installing agent definitions (${BOLD}%s${RESET})..." "$AGENT_COUNT"
{
  cp "$SCRIPT_DIR/agents/"*.md ~/.claude/agents/
} && step_ok || { step_fail; die "Failed to copy agent definitions."; }

for f in "$SCRIPT_DIR/agents/"*.md; do
  detail "$(basename "$f" .md)"
done

# ── Step 3: Skills (slash commands) ───────────────────────────────────
SKILL_COUNT=$(find "$SCRIPT_DIR/skills" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
printf "  ${BRAND}[3/4]${RESET} Installing skills (${BOLD}%s${RESET} commands)..." "$SKILL_COUNT"
{
  cp "$SCRIPT_DIR/skills/"*.md ~/.claude/skills/
} && step_ok || { step_fail; die "Failed to copy skills."; }

# Show skill names in a compact line
SKILL_NAMES=""
for f in "$SCRIPT_DIR/skills/"*.md; do
  NAME=$(basename "$f" .md)
  if [ -z "$SKILL_NAMES" ]; then
    SKILL_NAMES="$NAME"
  else
    SKILL_NAMES="$SKILL_NAMES, $NAME"
  fi
done
detail "$SKILL_NAMES"

# ── Step 4: Shell function ────────────────────────────────────────────
SHELL_FUNC="$SCRIPT_DIR/shell/claude-team.sh"

# Detect shell config file
if [[ -f ~/.zshrc ]]; then
  SHELL_RC=~/.zshrc
elif [[ -f ~/.bashrc ]]; then
  SHELL_RC=~/.bashrc
else
  SHELL_RC=~/.profile
fi

SHELL_RC_NAME=$(basename "$SHELL_RC")

if ! grep -q "claude-team.sh" "$SHELL_RC" 2>/dev/null; then
  printf "  ${BRAND}[4/4]${RESET} Installing shell function..."
  {
    echo "" >> "$SHELL_RC"
    echo "# TMUX Claude Team" >> "$SHELL_RC"
    echo "source \"$SHELL_FUNC\"" >> "$SHELL_RC"
  } && step_ok || { step_fail; die "Failed to update $SHELL_RC."; }
  detail "Added to ~/$SHELL_RC_NAME"
  SHELL_UPDATED=true
else
  printf "  ${BRAND}[4/4]${RESET} Shell function already configured..."
  step_ok
  detail "Already in ~/$SHELL_RC_NAME"
  SHELL_UPDATED=false
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
printf "${SUCCESS}┌────────────────────────────────────────────┐${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${SUCCESS}${BOLD}Installation complete!${RESET}                     ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${BOLD}Installed:${RESET}                                ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %s agent definitions                  ${SUCCESS}│${RESET}\n" "$AGENT_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} %s slash commands                     ${SUCCESS}│${RESET}\n" "$SKILL_COUNT"
printf "${SUCCESS}│${RESET}    ${DIM}•${RESET} claude-team shell function            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}  ${BOLD}Next steps:${RESET}                               ${SUCCESS}│${RESET}\n"
if [ "$SHELL_UPDATED" = true ]; then
  printf "${SUCCESS}│${RESET}    1. ${BRAND}source ~/%s${RESET}%-*s${SUCCESS}│${RESET}\n" "$SHELL_RC_NAME" $((21 - ${#SHELL_RC_NAME})) ""
else
  printf "${SUCCESS}│${RESET}    1. ${DIM}(shell already configured)${RESET}            ${SUCCESS}│${RESET}\n"
fi
printf "${SUCCESS}│${RESET}    2. ${BRAND}cd /your/project${RESET}                      ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}    3. ${BRAND}claude-team${RESET}                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}│${RESET}                                            ${SUCCESS}│${RESET}\n"
printf "${SUCCESS}└────────────────────────────────────────────┘${RESET}\n"
echo ""
