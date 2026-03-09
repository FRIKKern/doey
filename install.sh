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

# 4. Install the claude-team script
mkdir -p ~/.local/bin
cp "$SCRIPT_DIR/shell/claude-team.sh" ~/.local/bin/claude-team
chmod +x ~/.local/bin/claude-team
echo "  ✓ Installed claude-team to ~/.local/bin/claude-team"

# 5. Check if ~/.local/bin is on PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  echo ""
  echo "  ⚠  ~/.local/bin is not in your PATH."
  echo "     Add this to your shell config (~/.zshrc or ~/.bashrc):"
  echo ""
  echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

echo ""
echo "Done! Start the team with:"
echo "  claude-team          # in current directory, default 6x2 grid"
echo "  claude-team 4x3      # custom grid"
echo ""
echo "Optional: Add project-level commands by copying commands/ to your project:"
echo "  cp -r $SCRIPT_DIR/commands/ <your-project>/.claude/commands/"
