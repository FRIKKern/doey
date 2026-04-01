#!/bin/bash
set -euo pipefail
# Pre-commit hook: verify Go TUI compiles when tui/ files change.
# Bash 3.2 compatible. Does not block non-Go commits.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git diff --cached --name-only | grep -qE '^tui/' || exit 0

# Discover Go via shared helper (inline fallback if unavailable)
_GO_BIN="" _HELPERS_LOADED=0
_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
for _helper_path in \
    "${_PROJECT_ROOT}/shell/doey-go-helpers.sh" \
    "${HOME}/.local/bin/doey-go-helpers.sh" \
    "${SCRIPT_DIR}/doey-go-helpers.sh"; do
    [ -f "$_helper_path" ] || continue
    source "$_helper_path" 2>/dev/null || true
    if type _find_go_bin >/dev/null 2>&1; then
        _GO_BIN="$(_find_go_bin)" || true; _HELPERS_LOADED=1
    fi
    break
done
if [ -z "$_GO_BIN" ]; then
    if command -v go >/dev/null 2>&1; then _GO_BIN="go"
    else
        for _godir in /usr/local/go/bin /opt/homebrew/bin /snap/go/current/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
            [ -x "$_godir/go" ] && { _GO_BIN="$_godir/go"; export PATH="$_godir:$PATH"; break; }
        done
    fi
fi
if [ -z "$_GO_BIN" ]; then
    echo "WARNING: Go toolchain not found — skipping build check." >&2; exit 0
fi

echo "Building Go binaries..."

if [ "$_HELPERS_LOADED" = 1 ] && type _build_all_go_binaries >/dev/null 2>&1; then
    # Use shared helper — builds all targets to ~/.local/bin/
    if ! _build_all_go_binaries; then
        echo "ERROR: Go build failed. Fix compilation errors before committing." >&2
        exit 1
    fi
else
    # Fallback: build each known target explicitly
    _tui_dir="${_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}/tui"
    _build_failed=0
    for _target in "doey-tui|./cmd/doey-tui/" "doey-remote-setup|./cmd/doey-remote-setup/"; do
        _name="${_target%%|*}"
        _pkg="${_target#*|}"
        if ! (cd "$_tui_dir" && "$_GO_BIN" build -o "${HOME}/.local/bin/${_name}" "$_pkg"); then
            echo "FAILED: ${_name}" >&2
            _build_failed=1
        fi
    done
    if [ "$_build_failed" = 1 ]; then
        echo "ERROR: Go build failed. Fix compilation errors before committing." >&2
        exit 1
    fi
fi

echo "Go build passed — binaries up to date."
