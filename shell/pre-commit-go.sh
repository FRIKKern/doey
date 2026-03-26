#!/bin/bash
set -euo pipefail

# Pre-commit hook: compile Go TUI binary when tui/ files change.
# Bash 3.2 compatible. Does not block non-Go commits.

# Only trigger when tui/ files are staged
if ! git diff --cached --name-only | grep -qE '^tui/'; then
    exit 0
fi

# Don't block commits if Go isn't installed
if ! command -v go >/dev/null 2>&1; then
    echo "Warning: Go not installed — skipping TUI binary build"
    exit 0
fi

echo "Building doey-tui binary..."

# Ensure bin/ exists
mkdir -p bin

# Build the binary
(cd tui && go build -o ../bin/doey-tui ./cmd/doey-tui/)

# Stage the compiled binary
git add bin/doey-tui

echo "doey-tui binary built and staged."
