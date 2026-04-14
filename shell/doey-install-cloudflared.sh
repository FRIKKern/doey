#!/usr/bin/env bash
# doey-install-cloudflared.sh — single source of truth for installing cloudflared.
#
# Design notes: see /tmp/doey/doey/results/cloudflared_auto_plan.md sections 4, 6, 7, 8.
#
# Sourceable (provides `_doey_install_cloudflared` and
# `_doey_install_cloudflared_interactive`) AND directly executable:
#
#     bash shell/doey-install-cloudflared.sh            # interactive, direct-binary
#     bash shell/doey-install-cloudflared.sh --yes      # non-interactive, direct-binary
#     bash shell/doey-install-cloudflared.sh --system   # prompt, package-manager path
#
# Default path: download the official release binary to ~/.local/bin/cloudflared.
# NO sudo. NO writes outside ~/.local/bin/. NEVER reads or writes ~/.cloudflared/.
#
# TODO (masterplan §8 risk #3 + #5): pin a specific CLOUDFLARED_VERSION and SHA256
# per platform, and verify the downloaded binary before moving it into place. This
# MVP slice uses the unverified `latest` release URL — acceptable for Phase 1–2.

case "${BASH_SOURCE[0]:-$0}" in
    "$0") set -euo pipefail ;;
esac

# Locate and source doey-platform.sh for detection helpers.
_dic_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "${_dic_script_dir}/doey-platform.sh"

_DOEY_CF_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

_dic_log() { printf '  %s\n' "$*"; }
_dic_err() { printf '  ✗ %s\n' "$*" >&2; }
_dic_ok()  { printf '  ✓ %s\n' "$*"; }

# ---- URL resolution -------------------------------------------------------

# Echo the release asset URL + local filename suffix for a given distro/arch.
# Prints two tab-separated fields: "<url>\t<is_tgz:0|1>"
_dic_asset_url() {
    local distro="$1" arch="$2" url="" is_tgz=0
    case "$distro" in
        macos)
            case "$arch" in
                amd64) url="${_DOEY_CF_RELEASE_BASE}/cloudflared-darwin-amd64.tgz"; is_tgz=1 ;;
                arm64) url="${_DOEY_CF_RELEASE_BASE}/cloudflared-darwin-amd64.tgz"; is_tgz=1 ;;
                *) return 1 ;;
            esac
            ;;
        debian|ubuntu|fedora|rhel|arch|alpine|linux-unknown)
            case "$arch" in
                amd64) url="${_DOEY_CF_RELEASE_BASE}/cloudflared-linux-amd64" ;;
                arm64) url="${_DOEY_CF_RELEASE_BASE}/cloudflared-linux-arm64" ;;
                386)   url="${_DOEY_CF_RELEASE_BASE}/cloudflared-linux-386" ;;
                arm)   url="${_DOEY_CF_RELEASE_BASE}/cloudflared-linux-arm" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    printf '%s\t%s\n' "$url" "$is_tgz"
}

# ---- Downloader -----------------------------------------------------------

_dic_fetch() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        _dic_err "Neither curl nor wget is available — cannot download cloudflared."
        return 1
    fi
}

_dic_trash() {
    local target="$1"
    [ -e "$target" ] || return 0
    if command -v trash >/dev/null 2>&1; then
        trash "$target" 2>/dev/null || rm -f "$target"
    else
        rm -f "$target"
    fi
}

# ---- Install: direct binary (default, no sudo) ----------------------------

_install_cf_binary() {
    local distro arch asset url is_tgz
    distro=$(_doey_detect_distro)
    arch=$(_doey_detect_arch)

    if [ "$arch" = "unknown" ]; then
        _dic_err "Unsupported architecture: $(uname -m 2>/dev/null || echo unknown)"
        return 1
    fi

    if ! asset=$(_dic_asset_url "$distro" "$arch"); then
        _dic_err "No direct-binary asset for distro=$distro arch=$arch"
        return 1
    fi
    url=${asset%%$'\t'*}
    is_tgz=${asset##*$'\t'}

    local bin_dir dest partial
    bin_dir=$(_doey_local_bin)
    mkdir -p "$bin_dir"
    dest="${bin_dir}/cloudflared"
    partial="${dest}.partial.$$"

    _dic_log "→ Downloading cloudflared for ${distro}-${arch}..."
    if ! _dic_fetch "$url" "$partial"; then
        _dic_err "Download failed: could not reach ${url}"
        _dic_trash "$partial"
        return 1
    fi

    if [ "$is_tgz" = "1" ]; then
        local extract_dir
        extract_dir="${partial}.d"
        mkdir -p "$extract_dir"
        if ! tar -xzf "$partial" -C "$extract_dir" 2>/dev/null; then
            _dic_err "Failed to extract tarball"
            _dic_trash "$partial"
            _dic_trash "$extract_dir"
            return 1
        fi
        local inner
        inner=$(find "$extract_dir" -type f -name cloudflared | head -1)
        if [ -z "$inner" ] || [ ! -f "$inner" ]; then
            _dic_err "Tarball did not contain a cloudflared binary"
            _dic_trash "$partial"
            _dic_trash "$extract_dir"
            return 1
        fi
        _dic_trash "$partial"
        partial="$inner"
    fi

    _dic_log "→ Installing to ${dest}..."
    chmod +x "$partial" || true
    if ! mv "$partial" "$dest"; then
        _dic_err "Could not move binary into ${dest}"
        _dic_trash "$partial"
        return 1
    fi

    # macOS: strip quarantine xattr so Gatekeeper does not block first run.
    if [ "$distro" = "macos" ] && command -v xattr >/dev/null 2>&1; then
        xattr -d com.apple.quarantine "$dest" 2>/dev/null || true
    fi

    # Confirm the binary is runnable and $PATH-visible.
    local ver
    ver=$("$dest" --version 2>/dev/null | head -1 || echo "installed")
    _dic_ok "cloudflared installed (${ver})"

    case ":${PATH}:" in
        *":${bin_dir}:"*) : ;;
        *) _dic_log "Note: ${bin_dir} is not on your PATH. Add it to your shell rc." ;;
    esac
    return 0
}

# ---- Install: package manager (--system, may sudo) -----------------------

_install_cf_system() {
    local distro
    distro=$(_doey_detect_distro)

    if is_unattended; then
        _dic_err "Refusing --system install in unattended mode (would require sudo)."
        return 2
    fi

    case "$distro" in
        macos)
            if ! command -v brew >/dev/null 2>&1; then
                _dic_err "Homebrew not found — re-run without --system to use the direct binary."
                return 1
            fi
            _dic_log "→ Installing via brew tap cloudflare/cloudflare/cloudflared..."
            brew install cloudflare/cloudflare/cloudflared
            ;;
        debian|ubuntu)
            _dic_err "Debian/Ubuntu --system install is not wired in this MVP slice."
            _dic_err "Run without --system to use the no-sudo direct-binary path."
            return 1
            ;;
        fedora|rhel)
            _dic_err "Fedora/RHEL --system install is not wired in this MVP slice."
            _dic_err "Run without --system to use the no-sudo direct-binary path."
            return 1
            ;;
        *)
            _dic_err "No --system path for distro=$distro — use the direct binary."
            return 1
            ;;
    esac

    local ver
    ver=$(cloudflared --version 2>/dev/null | head -1 || echo "installed")
    _dic_ok "cloudflared installed (${ver})"
}

# ---- Public entrypoints ---------------------------------------------------

# Non-interactive: install using the chosen path. Idempotent.
# Args: --system (optional)
_doey_install_cloudflared() {
    local use_system=0 arg
    for arg in "$@"; do
        case "$arg" in
            --system) use_system=1 ;;
        esac
    done

    if command -v cloudflared >/dev/null 2>&1; then
        _dic_ok "cloudflared already installed ($(cloudflared --version 2>/dev/null | head -1 || echo present))"
        return 0
    fi

    if [ "$use_system" = "1" ]; then
        _install_cf_system
        return $?
    fi
    _install_cf_binary
    return $?
}

# Interactive: prompt before installing. Respects unattended detection.
# Returns:
#   0 — cloudflared present (either already or newly installed)
#   1 — install failed
#   2 — refused (unattended without consent, or user answered N)
_doey_install_cloudflared_interactive() {
    local use_system=0 arg
    for arg in "$@"; do
        case "$arg" in
            --system) use_system=1 ;;
        esac
    done

    if command -v cloudflared >/dev/null 2>&1; then
        return 0
    fi

    if is_unattended; then
        if [ "${DOEY_TUNNEL_AUTO_INSTALL:-0}" = "1" ] && [ "$use_system" = "0" ]; then
            _dic_log "DOEY_TUNNEL_AUTO_INSTALL=1 — installing cloudflared direct-binary (no sudo)"
            _doey_install_cloudflared
            return $?
        fi
        _dic_err "cloudflared is not installed and this shell is unattended."
        _dic_log "To pre-install before the next run:"
        _dic_log "  bash \"\$(doey path)/shell/doey-install-cloudflared.sh\" --yes"
        _dic_log "Or set DOEY_TUNNEL_AUTO_INSTALL=1 to allow auto-install in CI."
        return 2
    fi

    printf '\n'
    printf '  %s\n' "⚠  cloudflared is not installed."
    printf '  %s\n' "Doey uses cloudflared to expose your local dev server through a"
    printf '  %s\n' "temporary https://*.trycloudflare.com URL. No Cloudflare account"
    if [ "$use_system" = "1" ]; then
        printf '  %s\n' "needed. --system path MAY invoke sudo."
    else
        printf '  %s\n' "needed, no sudo required — the binary installs to ~/.local/bin/."
    fi
    printf '\n'

    local prompt ans
    if [ "$use_system" = "1" ]; then
        prompt="  Install cloudflared now (system package, may sudo)? [y/N] "
    else
        prompt="  Install cloudflared now? [Y/n] "
    fi

    printf '%s' "$prompt"
    if ! IFS= read -r ans; then
        _dic_err "Could not read response — aborting."
        return 2
    fi

    if [ "$use_system" = "1" ]; then
        case "$ans" in
            y|Y|yes|YES) : ;;
            *) _dic_log "Skipped cloudflared install."; return 2 ;;
        esac
    else
        case "$ans" in
            n|N|no|NO) _dic_log "Skipped cloudflared install."; return 2 ;;
            *) : ;;
        esac
    fi

    if [ "$use_system" = "1" ]; then
        _doey_install_cloudflared --system
        return $?
    fi
    _doey_install_cloudflared
    return $?
}

# ---- Direct execution -----------------------------------------------------

_dic_main() {
    local use_system=0 assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
            --system) use_system=1 ;;
            --yes|-y) assume_yes=1 ;;
            -h|--help)
                cat <<'EOF'
Usage: doey-install-cloudflared.sh [--system] [--yes]

  --system   Install via brew/apt/dnf (may sudo). Default: direct binary (no sudo).
  --yes      Non-interactive: skip the Y/N prompt.

Installs cloudflared to ~/.local/bin/cloudflared by default. Idempotent: if
cloudflared is already on PATH, this script is a no-op.
EOF
                return 0
                ;;
        esac
    done

    if [ "$assume_yes" = "1" ]; then
        if [ "$use_system" = "1" ]; then
            _doey_install_cloudflared --system
        else
            _doey_install_cloudflared
        fi
        return $?
    fi

    if [ "$use_system" = "1" ]; then
        _doey_install_cloudflared_interactive --system
    else
        _doey_install_cloudflared_interactive
    fi
}

case "${BASH_SOURCE[0]:-$0}" in
    "$0")
        _dic_main "$@"
        exit $?
        ;;
esac
