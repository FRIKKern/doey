#!/bin/bash
set -euo pipefail

# Pre-commit hook: verify Go TUI compiles when tui/ files change.
# Bash 3.2 compatible. Does not block non-Go commits.

# Only trigger when tui/ files are staged
if ! git diff --cached --name-only | grep -qE '^tui/'; then
    exit 0
fi

# Discover Go — common install locations
for _godir in /snap/go/current/bin /usr/local/go/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
    if [ -x "$_godir/go" ]; then
        export PATH="$_godir:$PATH"
        break
    fi
done

# Don't block commits if Go isn't installed
if ! command -v go >/dev/null 2>&1; then
    echo "WARNING: Go toolchain not found — skipping build check. Install Go to enable build gate." >&2
    exit 0
fi

echo "Checking Go build..."

if ! (cd tui && go build ./...); then
    echo "ERROR: Go build failed. Fix compilation errors before committing." >&2
    exit 1
fi

echo "Go build check passed."
