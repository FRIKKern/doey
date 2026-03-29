#!/usr/bin/env bash
# doey-go-check.sh — Dev-mode Go install helper for Doey TUI
# Sourceable library: check_go_install() and is_doey_repo()
# Advisory only — never exits non-zero or blocks startup.
set -euo pipefail

# Default minimum Go version (overridden by tui/go.mod if available)
_DOEY_GO_MIN_VERSION="1.24.2"

# Check if we're running inside the Doey source repo
# Returns 0 if yes, 1 if no
is_doey_repo() {
    local dir="${1:-.}"
    [ -f "${dir}/tui/go.mod" ] && [ -f "${dir}/shell/doey.sh" ] && [ -f "${dir}/install.sh" ]
}

# Parse Go version from tui/go.mod if available
# Falls back to _DOEY_GO_MIN_VERSION
_doey_go_required_version() {
    local dir="${1:-.}"
    local gomod="${dir}/tui/go.mod"
    if [ -f "$gomod" ]; then
        local ver
        ver=$(sed -n 's/^go[[:space:]][[:space:]]*//p' "$gomod" | head -1)
        if [ -n "$ver" ]; then
            printf '%s' "$ver"
            return 0
        fi
    fi
    printf '%s' "$_DOEY_GO_MIN_VERSION"
}

# Split "major.minor.patch" into _VER_MAJOR _VER_MINOR _VER_PATCH (bash 3.2 safe)
_doey_split_ver() {
    local v="$1"
    _VER_MAJOR="${v%%.*}"; v="${v#*.}"
    _VER_MINOR="${v%%.*}"; _VER_PATCH="${v#*.}"
    [ "$_VER_PATCH" = "$_VER_MINOR" ] && _VER_PATCH=0
}

# Compare two version strings (major.minor.patch)
# Returns 0 if $1 >= $2, 1 otherwise
_doey_version_gte() {
    local a_major a_minor a_patch b_major b_minor b_patch
    _doey_split_ver "$1"; a_major=$_VER_MAJOR; a_minor=$_VER_MINOR; a_patch=$_VER_PATCH
    _doey_split_ver "$2"; b_major=$_VER_MAJOR; b_minor=$_VER_MINOR; b_patch=$_VER_PATCH

    if [ "$a_major" -gt "$b_major" ] 2>/dev/null; then return 0; fi
    if [ "$a_major" -lt "$b_major" ] 2>/dev/null; then return 1; fi
    if [ "$a_minor" -gt "$b_minor" ] 2>/dev/null; then return 0; fi
    if [ "$a_minor" -lt "$b_minor" ] 2>/dev/null; then return 1; fi
    if [ "$a_patch" -ge "$b_patch" ] 2>/dev/null; then return 0; fi
    return 1
}

# Check Go installation and version
# Prints advisory warnings if Go is missing or too old
# Always returns 0 (non-blocking)
check_go_install() {
    local dir="${1:-.}"
    local required
    required=$(_doey_go_required_version "$dir")

    if ! command -v go >/dev/null 2>&1; then
        echo "Go is not installed. The TUI dashboard requires Go ${required}. Install: brew install go (or visit https://go.dev/dl/). Falling back to shell dashboard." >&2
        return 0
    fi

    # Extract version number from "go version go1.24.2 darwin/arm64"
    local go_version_raw current
    go_version_raw=$(go version 2>/dev/null || true)
    current=$(printf '%s' "$go_version_raw" | sed 's/.*go\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/')

    if [ -z "$current" ]; then
        echo "Could not determine Go version. The TUI dashboard requires Go ${required}." >&2
        return 0
    fi

    if ! _doey_version_gte "$current" "$required"; then
        echo "Go ${current} is installed but Doey TUI needs ${required}. Run: brew install go (or visit https://go.dev/dl/)" >&2
        return 0
    fi

    return 0
}

# Guard: no top-level execution when sourced
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # Running directly — run check for testing
    check_go_install "${1:-.}"
fi
