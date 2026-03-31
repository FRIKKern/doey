#!/bin/bash
set -euo pipefail

# Pre-commit hook: verify Go TUI compiles when tui/ files change.
# Bash 3.2 compatible. Does not block non-Go commits.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only trigger when tui/ files are staged
if ! git diff --cached --name-only | grep -qE '^tui/'; then
    exit 0
fi

# Discover Go via shared helper (inline fallback if helper not available)
_GO_BIN=""
if [ -f "${SCRIPT_DIR}/doey-go-helpers.sh" ]; then
    source "${SCRIPT_DIR}/doey-go-helpers.sh" 2>/dev/null || true
    if type _find_go_bin >/dev/null 2>&1; then
        _find_go_bin
        _GO_BIN="${GO_BIN:-}"
    fi
fi
if [ -z "$_GO_BIN" ]; then
    # Inline fallback: check common Go install locations
    if command -v go >/dev/null 2>&1; then
        _GO_BIN="go"
    else
        for _godir in /usr/local/go/bin /opt/homebrew/bin /snap/go/current/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
            if [ -x "$_godir/go" ]; then
                _GO_BIN="$_godir/go"
                export PATH="$_godir:$PATH"
                break
            fi
        done
    fi
fi

# Don't block commits if Go isn't installed
if [ -z "$_GO_BIN" ]; then
    echo "WARNING: Go toolchain not found — skipping build check. Install Go to enable build gate." >&2
    exit 0
fi

echo "Checking Go build..."

if ! (cd tui && "$_GO_BIN" build ./...); then
    echo "ERROR: Go build failed. Fix compilation errors before committing." >&2
    exit 1
fi

echo "Go build check passed."
