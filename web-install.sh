#!/usr/bin/env bash
set -euo pipefail

# Doey — Web Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/frikk-gyldendal/claude-code-tmux-team/main/web-install.sh | bash

REPO_URL="https://github.com/frikk-gyldendal/claude-code-tmux-team.git"
CLONE_DIR="${TMPDIR:-/tmp}/claude-code-tmux-team-install"

echo ""
echo "  Doey — Web Installer"
echo "  ======================================"
echo ""

# Clean up any previous install attempt
rm -rf "$CLONE_DIR"

# Clone the repo
echo "  Cloning repository..."
if git clone --depth 1 "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
  echo "  ✓ Repository cloned"
else
  echo "  ✗ Failed to clone repository"
  echo "    Make sure git is installed and you have network access."
  exit 1
fi

echo ""

# Run the real installer
bash "$CLONE_DIR/install.sh"

# Clean up
rm -rf "$CLONE_DIR"
