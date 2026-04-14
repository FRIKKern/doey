#!/usr/bin/env bash
# doey-platform.sh — shared platform detection helpers.
#
# Sourceable by other shell scripts. Bash 3.2 compatible. Idempotent.
# Exposes:
#   _doey_detect_distro  — prints: macos|debian|ubuntu|fedora|rhel|arch|alpine|linux-unknown|unknown
#   _doey_detect_arch    — prints: amd64|arm64|386|arm|unknown
#   is_unattended        — returns 0 if running without a user present
#   _doey_local_bin      — prints the user's local bin dir (XDG_BIN_HOME or ~/.local/bin)

[ -n "${_DOEY_PLATFORM_SOURCED:-}" ] && return 0 2>/dev/null || true
_DOEY_PLATFORM_SOURCED=1

# Only harden when executed directly; sourcing should not mutate caller shell opts.
case "${BASH_SOURCE[0]:-$0}" in
    "$0") set -euo pipefail ;;
esac

_doey_detect_distro() {
    local uname_s
    uname_s=$(uname -s 2>/dev/null || echo unknown)
    case "$uname_s" in
        Darwin) echo macos; return 0 ;;
        Linux) : ;;
        *) echo unknown; return 0 ;;
    esac

    # Parse /etc/os-release line-by-line. Never `source` it — untrusted content
    # plus `set -e` is a footgun.
    local id="" id_like=""
    if [ -r /etc/os-release ]; then
        local line key val
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ID=*)
                    val=${line#ID=}
                    val=${val%\"}
                    val=${val#\"}
                    id=$val
                    ;;
                ID_LIKE=*)
                    val=${line#ID_LIKE=}
                    val=${val%\"}
                    val=${val#\"}
                    id_like=$val
                    ;;
            esac
        done < /etc/os-release
    fi

    case "$id" in
        debian) echo debian; return 0 ;;
        ubuntu) echo ubuntu; return 0 ;;
        fedora) echo fedora; return 0 ;;
        rhel|centos|rocky|almalinux) echo rhel; return 0 ;;
        arch|manjaro|endeavouros) echo arch; return 0 ;;
        alpine) echo alpine; return 0 ;;
    esac

    # Fall back on ID_LIKE — space-separated list.
    local like
    for like in $id_like; do
        case "$like" in
            debian) echo debian; return 0 ;;
            ubuntu) echo ubuntu; return 0 ;;
            fedora) echo fedora; return 0 ;;
            rhel|centos) echo rhel; return 0 ;;
            arch) echo arch; return 0 ;;
            alpine) echo alpine; return 0 ;;
        esac
    done

    echo linux-unknown
}

_doey_detect_arch() {
    local m
    m=$(uname -m 2>/dev/null || echo unknown)
    case "$m" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        i386|i686) echo 386 ;;
        armv6l|armv7l|arm) echo arm ;;
        *) echo unknown ;;
    esac
}

is_unattended() {
    [ "${CI:-}" = "true" ] && return 0
    [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ] && return 0
    [ "${DOEY_NO_TUNNEL_INSTALL:-0}" = "1" ] && return 0
    [ ! -t 0 ] && return 0
    return 1
}

_doey_local_bin() {
    printf '%s\n' "${XDG_BIN_HOME:-$HOME/.local/bin}"
}
