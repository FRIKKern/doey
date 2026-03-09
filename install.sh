#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# Install the TMUX Claude Team system
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing TMUX Claude Team..."
echo ""

# 1. Create directories
mkdir -p ~/.claude/agents
mkdir -p ~/.claude/skills
mkdir -p ~/.claude/agent-memory/tmux-manager
mkdir -p ~/.claude/agent-memory/tmux-watchdog

# 2. Copy agent definitions
cp "$SCRIPT_DIR/agents/"*.md ~/.claude/agents/
echo "  ✓ Installed agent definitions"

# 3. Copy skills (slash commands)
cp "$SCRIPT_DIR/skills/"*.md ~/.claude/skills/
echo "  ✓ Installed skills (slash commands)"

# 4. Source the shell function
SHELL_FUNC="$SCRIPT_DIR/shell/claude-team.sh"

# Detect shell config file
if [[ -f ~/.zshrc ]]; then
  SHELL_RC=~/.zshrc
elif [[ -f ~/.bashrc ]]; then
  SHELL_RC=~/.bashrc
else
  SHELL_RC=~/.profile
fi

# Add source line if not already present
if ! grep -q "claude-team.sh" "$SHELL_RC" 2>/dev/null; then
  echo "" >> "$SHELL_RC"
  echo "# TMUX Claude Team" >> "$SHELL_RC"
  echo "source \"$SHELL_FUNC\"" >> "$SHELL_RC"
  echo "  ✓ Added shell function to $SHELL_RC"
else
  echo "  ✓ Shell function already in $SHELL_RC"
fi

echo ""
echo "Done! Restart your shell or run:"
echo "  source $SHELL_RC"
echo ""
echo "Then start the team with:"
echo "  claude-team          # in current directory, default 6x2 grid"
echo "  claude-team 4x3      # custom grid"
echo ""
echo "Optional: Add project-level commands by copying commands/ to your project:"
echo "  cp -r $SCRIPT_DIR/commands/ <your-project>/.claude/commands/"
