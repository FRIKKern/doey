#!/usr/bin/env bash
# doey-go-helpers.sh — Shared Go build functions for Doey
# Sourceable library: _find_go_bin, _go_binary_stale, _build_go_binary,
#   _build_all_go_binaries, _check_go_freshness
# Bash 3.2 compatible. No associative arrays, no mapfile, no pipe-ampersand.
set -euo pipefail

# ── Double-source guard ──────────────────────────────────────────────
[ -n "${_DOEY_GO_HELPERS_LOADED:-}" ] && return 0
_DOEY_GO_HELPERS_LOADED=1

# ── Path detection ───────────────────────────────────────────────────
_GO_HELPERS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GO_HELPERS_PROJECT_DIR="$(cd "$_GO_HELPERS_SCRIPT_DIR/.." && pwd)"

# ── Known Go binary targets ─────────────────────────────────────────
# Format: name|module_dir|build_target|output_path
_DOEY_GO_TARGETS="doey-tui|tui|./cmd/doey-tui/|${HOME}/.local/bin/doey-tui
doey-ctl|tui|./cmd/doey-ctl/|${HOME}/.local/bin/doey-ctl
doey-router|tui|./cmd/doey-router/|${HOME}/.local/bin/doey-router
doey-remote-setup|tui|./cmd/doey-remote-setup/|${HOME}/.local/bin/doey-remote-setup
doey-loading|tui|./cmd/doey-loading/|${HOME}/.local/bin/doey-loading
doey-daemon|tui|./cmd/doey-daemon/|${HOME}/.local/bin/doey-daemon
doey-term|tui|./cmd/doey-term/|${HOME}/.local/bin/doey-term
doey-masterplan-tui|tui|./cmd/doey-masterplan-tui/|${HOME}/.local/bin/doey-masterplan-tui
doey-scaffy|tui|./cmd/scaffy/|${HOME}/.local/bin/doey-scaffy"

# ── _print_go_install_hint ───────────────────────────────────────────
# Print a platform-aware Go install hint to stderr. Detects common
# package managers via command -v and prints the matching install
# command. Falls back to https://go.dev/dl/ when no manager is found.
# The phrase "Go is required" is always emitted so install-time tests
# can grep for it. Pure stdout/stderr — never exits.
_print_go_install_hint() {
    printf 'Go is required to build doey-tui and the masterplan TUI.\n' >&2
    printf 'Detected platform: %s\n' "$(uname -s)" >&2
    if command -v brew >/dev/null 2>&1; then
        printf '  brew install go\n' >&2
    elif command -v apt-get >/dev/null 2>&1; then
        printf '  sudo apt-get install -y golang-go\n' >&2
    elif command -v dnf >/dev/null 2>&1; then
        printf '  sudo dnf install -y golang\n' >&2
    elif command -v pacman >/dev/null 2>&1; then
        printf '  sudo pacman -S --noconfirm go\n' >&2
    elif command -v apk >/dev/null 2>&1; then
        printf '  sudo apk add go\n' >&2
    elif command -v zypper >/dev/null 2>&1; then
        printf '  sudo zypper install -y go\n' >&2
    elif command -v nix-env >/dev/null 2>&1; then
        printf '  nix-env -iA nixpkgs.go\n' >&2
    else
        printf '  Download from: https://go.dev/dl/\n' >&2
    fi
}

# ── _find_go_bin ─────────────────────────────────────────────────────
# Find the Go binary across common install locations.
# Prints path on stdout. Returns 0 if found, 1 if not.
_find_go_bin() {
    # Fast path: already on PATH
    local go_path
    go_path="$(command -v go 2>/dev/null || true)"
    if [ -n "$go_path" ] && [ -x "$go_path" ]; then
        printf '%s' "$go_path"
        return 0
    fi

    # Check common install locations
    local candidate
    for candidate in \
        /usr/local/go/bin/go \
        /opt/homebrew/bin/go \
        /snap/go/current/bin/go \
        "${HOME}/go/bin/go" \
        "${HOME}/.local/go/bin/go" \
        /usr/local/bin/go \
        /usr/bin/go; do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

# ── _file_mtime ──────────────────────────────────────────────────────
# Cross-platform file modification time (epoch seconds).
# macOS uses stat -f, Linux uses stat -c.
_file_mtime() {
    stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || printf '0'
}

# ── _go_binary_stale ────────────────────────────────────────────────
# Check if a binary is older than any .go source file in a directory.
# Args: $1=binary_path  $2=source_directory
# Returns 0 if binary is stale (missing or older), 1 if up-to-date.
_go_binary_stale() {
    local binary="$1"
    local src_dir="$2"

    # Missing binary is always stale
    if [ ! -f "$binary" ]; then
        return 0
    fi

    # Missing source dir — can't be stale if there's no source
    if [ ! -d "$src_dir" ]; then
        return 1
    fi

    local bin_mtime
    bin_mtime="$(_file_mtime "$binary")"

    # Find any .go file newer than the binary (bash 3.2 safe: use find + while read)
    local src_file src_mtime
    while IFS= read -r src_file; do
        [ -z "$src_file" ] && continue
        src_mtime="$(_file_mtime "$src_file")"
        if [ "$src_mtime" -gt "$bin_mtime" ] 2>/dev/null; then
            return 0
        fi
    done <<EOF
$(find "$src_dir" -name '*.go' -type f 2>/dev/null)
EOF

    # Also check go.mod and go.sum
    local extra
    for extra in "${src_dir}/go.mod" "${src_dir}/go.sum"; do
        if [ -f "$extra" ]; then
            src_mtime="$(_file_mtime "$extra")"
            if [ "$src_mtime" -gt "$bin_mtime" ] 2>/dev/null; then
                return 0
            fi
        fi
    done

    return 1
}

# ── _build_go_binary ────────────────────────────────────────────────
# Build a single Go binary.
# Args: $1=module_dir (relative to project)  $2=build_target  $3=output_path
# Returns exit code from go build, or 1 if Go not found.
_build_go_binary() {
    local module_dir="$1"
    local build_target="$2"
    local output_path="$3"

    local go_bin
    if ! go_bin="$(_find_go_bin)"; then
        echo "Error: Go not found. Cannot build ${output_path##*/}." >&2
        return 1
    fi

    local abs_module_dir="${_GO_HELPERS_PROJECT_DIR}/${module_dir}"
    if [ ! -d "$abs_module_dir" ]; then
        echo "Error: Module directory not found: ${abs_module_dir}" >&2
        return 1
    fi

    # Ensure output directory exists
    local out_dir
    out_dir="$(dirname "$output_path")"
    mkdir -p "$out_dir"

    # Build from module directory
    (cd "$abs_module_dir" && "$go_bin" build -o "$output_path" "$build_target")
}

# ── _build_all_go_binaries ──────────────────────────────────────────
# Build all known Go binary targets.
# Returns 0 if all succeed, 1 if any fail.
_build_all_go_binaries() {
    local failed=0
    local line name module_dir build_target output_path

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Parse pipe-delimited fields (bash 3.2 safe)
        name="${line%%|*}"; line="${line#*|}"
        module_dir="${line%%|*}"; line="${line#*|}"
        build_target="${line%%|*}"; line="${line#*|}"
        output_path="$line"

        if _build_go_binary "$module_dir" "$build_target" "$output_path"; then
            echo "Built: ${name} -> ${output_path}" >&2
        else
            echo "FAILED: ${name}" >&2
            failed=1
        fi
    done <<EOF
${_DOEY_GO_TARGETS}
EOF

    return "$failed"
}

# ── _check_go_freshness ─────────────────────────────────────────────
# Check if all Go binaries are fresh (up-to-date with source).
# Echoes names of stale binaries.
# Returns 0 if all fresh, 1 if any stale.
_check_go_freshness() {
    local any_stale=0
    local line name module_dir build_target output_path src_dir

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line%%|*}"; line="${line#*|}"
        module_dir="${line%%|*}"; line="${line#*|}"
        build_target="${line%%|*}"; line="${line#*|}"
        output_path="$line"

        src_dir="${_GO_HELPERS_PROJECT_DIR}/${module_dir}"
        if _go_binary_stale "$output_path" "$src_dir"; then
            echo "stale: ${name} (${output_path})"
            any_stale=1
        fi
    done <<EOF
${_DOEY_GO_TARGETS}
EOF

    return "$any_stale"
}
