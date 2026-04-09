#!/usr/bin/env bash
set -euo pipefail

# doey-tunnel.sh — Manage tunnel lifecycle for remote Doey sessions.
# Usage: doey-tunnel.sh <RUNTIME_DIR>
# Logs to stdout; caller redirects to tunnel.log.

RUNTIME_DIR="${1:?Usage: doey-tunnel.sh <RUNTIME_DIR>}"

# Source session environment for SESSION_NAME
if [ -f "${RUNTIME_DIR}/session.env" ]; then
    # shellcheck disable=SC1091
    . "${RUNTIME_DIR}/session.env"
fi
SESSION_NAME="${SESSION_NAME:-doey}"

# Tunnel config from environment
TUNNEL_PROVIDER="${DOEY_TUNNEL_PROVIDER:-auto}"
TUNNEL_PORTS="${DOEY_TUNNEL_PORTS:-3000}"
TUNNEL_DOMAIN="${DOEY_TUNNEL_DOMAIN:-}"

TUNNEL_ENV="${RUNTIME_DIR}/tunnel.env"

# --- Helpers ---

_read_tunnel_pid() {
    grep '^TUNNEL_PID=' "$TUNNEL_ENV" 2>/dev/null | head -1 | cut -d= -f2-
}

# --- Tailscale provider helpers ---
# Tailscale tunnels at the IP layer via a system-level daemon (tailscaled),
# so there is no per-port child process to spawn or supervise. These helpers
# only inspect the daemon and derive a clickable URL.

_tunnel_tailscale_available() {
    command -v tailscale >/dev/null 2>&1
}

_tunnel_tailscale_hostname() {
    # Returns the magic-DNS hostname (no trailing dot) on stdout, empty on failure.
    if command -v jq >/dev/null 2>&1; then
        tailscale status --json 2>/dev/null \
            | jq -r '.Self.DNSName // empty' 2>/dev/null \
            | sed 's/\.$//'
    else
        tailscale ip -4 2>/dev/null | head -n 1
    fi
}

_tunnel_tailscale_url() {
    # Args: $1=port. Echoes a clickable URL or empty.
    local port="${1:?port required}"
    local host
    host="$(_tunnel_tailscale_hostname)"
    [ -n "$host" ] || return 1
    printf 'http://%s:%s\n' "$host" "$port"
}

_tunnel_tailscale_status() {
    # 0 if tailscaled is connected, 1 otherwise
    tailscale status >/dev/null 2>&1
}

# --- Idempotency: exit early if tunnel already running ---

if [ -f "$TUNNEL_ENV" ]; then
    existing_pid=$(_read_tunnel_pid)
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        echo "[tunnel] Already running (PID $existing_pid), exiting."
        exit 0
    fi
    # Stale tunnel.env — remove and continue
    rm -f "$TUNNEL_ENV"
fi

# --- Tool detection ---

_detect_tunnel_tool() {
    if [ "$TUNNEL_PROVIDER" != "auto" ]; then
        if command -v "$TUNNEL_PROVIDER" >/dev/null 2>&1; then
            echo "$TUNNEL_PROVIDER"
        else
            echo ""
        fi
        return
    fi
    # Auto-detect priority: tailscale > cloudflared > ssh-stub.
    # Tailscale wins only when the daemon is actually connected — an
    # installed-but-unauthed binary should fall through to cloudflared.
    if _tunnel_tailscale_available && _tunnel_tailscale_status; then
        echo "tailscale"
        return
    fi
    if command -v cloudflared >/dev/null 2>&1; then
        echo "cloudflared"
        return
    fi
    # TODO(phase-3): SSH -L fallback provider — for users on hosts without
    # tailscale or cloudflared, derive an `ssh -L` recipe from the live
    # listening ports and emit it as the tunnel "URL" (instructional, not a
    # spawned process).
    echo ""
}

# --- Start tunnel ---

# Tailscale is special: there is no child process to fork. Compose the URL
# from the daemon's existing state and write tunnel.env. Returns 0 on
# success, 1 on tailscaled failure (with TUNNEL_ERROR recorded in env).
_start_tunnel_tailscale() {
    local port="$1"
    local ts_host="" ts_url="" ts_now=""

    if ! _tunnel_tailscale_status; then
        echo "[tunnel] tailscaled is not connected — run: sudo tailscale up"
        ts_now=$(date +%s)
        cat > "$TUNNEL_ENV" <<EOF
TUNNEL_ERROR=tailscaled_not_connected
TUNNEL_PROVIDER=tailscale
TUNNEL_STARTED=${ts_now}
EOF
        return 1
    fi

    ts_host=$(_tunnel_tailscale_hostname 2>/dev/null || true)
    if [ -z "$ts_host" ]; then
        echo "[tunnel] Could not derive tailscale hostname or IP"
        ts_now=$(date +%s)
        cat > "$TUNNEL_ENV" <<EOF
TUNNEL_ERROR=no_tailscale_hostname
TUNNEL_PROVIDER=tailscale
TUNNEL_STARTED=${ts_now}
EOF
        return 1
    fi

    ts_url="http://${ts_host}:${port}"
    ts_now=$(date +%s)
    cat > "$TUNNEL_ENV" <<EOF
TUNNEL_URL=${ts_url}
TUNNEL_HOSTNAME=${ts_host}
TUNNEL_PID=0
TUNNEL_PROVIDER=tailscale
TUNNEL_PORT=${port}
TUNNEL_STARTED=${ts_now}
EOF
    echo "[tunnel] URL: $ts_url"
    echo "[tunnel] Wrote $TUNNEL_ENV"
    if [ -n "${SESSION_NAME:-}" ]; then
        tmux set-environment -t "$SESSION_NAME" DOEY_TUNNEL_URL "$ts_url" 2>/dev/null || true
    fi
    return 0
}

_start_tunnel() {
    local tool="$1"
    local port="$2"
    local log_file="${RUNTIME_DIR}/tunnel-output.tmp"

    echo "[tunnel] Starting $tool on port $port"

    # Tailscale: no child process to spawn — daemon is system-level.
    # Skip the child-spawn / wait-for-URL / health-check machinery entirely.
    if [ "$tool" = "tailscale" ]; then
        _start_tunnel_tailscale "$port"
        return $?
    fi

    case "$tool" in
        cloudflared)
            local cf_args="tunnel --url http://localhost:${port} --no-autoupdate"
            if [ -n "$TUNNEL_DOMAIN" ]; then
                cf_args="${cf_args} --hostname ${TUNNEL_DOMAIN}"
            fi
            # shellcheck disable=SC2086
            cloudflared $cf_args > "$log_file" 2>&1 &
            ;;
        ngrok)
            ngrok http "$port" --log=stdout > "$log_file" 2>&1 &
            ;;
        bore)
            bore local "$port" --to bore.pub > "$log_file" 2>&1 &
            ;;
        *)
            echo "[tunnel] Unknown provider: $tool"
            return 1
            ;;
    esac

    local pid=$!
    echo "[tunnel] Background PID: $pid"

    # Wait for output to contain a URL
    local url=""
    local attempts=0
    while [ $attempts -lt 15 ]; do
        sleep 1
        attempts=$((attempts + 1))

        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[tunnel] Process died during startup"
            return 1
        fi

        case "$tool" in
            cloudflared)
                url=$(grep -o 'https://[a-zA-Z0-9._-]*\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1) || true
                ;;
            ngrok)
                url=$(grep -o 'https://[a-zA-Z0-9._-]*\.ngrok[a-zA-Z0-9._-]*' "$log_file" 2>/dev/null | head -1) || true
                ;;
            bore)
                url=$(grep -o 'listening on [^ ]*' "$log_file" 2>/dev/null | head -1 | sed 's/listening on //') || true
                ;;
        esac

        if [ -n "$url" ]; then
            break
        fi
    done

    if [ -z "$url" ]; then
        echo "[tunnel] Warning: could not parse URL after ${attempts}s (tunnel may still be starting)"
        url="pending"
    fi

    local ts
    ts=$(date +%s)

    # Write tunnel.env
    cat > "$TUNNEL_ENV" <<EOF
TUNNEL_URL=${url}
TUNNEL_PID=${pid}
TUNNEL_PROVIDER=${tool}
TUNNEL_PORT=${port}
TUNNEL_STARTED=${ts}
EOF

    echo "[tunnel] URL: $url"
    echo "[tunnel] Wrote $TUNNEL_ENV"

    # Export to tmux session
    if [ "$url" != "pending" ]; then
        tmux set-environment -t "$SESSION_NAME" DOEY_TUNNEL_URL "$url" 2>/dev/null || true
    fi
}

# --- Stop tunnel ---

_stop_tunnel() {
    if [ ! -f "$TUNNEL_ENV" ]; then
        return
    fi

    local pid
    pid=$(_read_tunnel_pid)

    if [ -n "$pid" ]; then
        echo "[tunnel] Stopping PID $pid"
        kill "$pid" 2>/dev/null || true
        # Wait briefly for clean shutdown
        local i=0
        while [ $i -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
        done
        # Force kill if still alive
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$TUNNEL_ENV"
    rm -f "${RUNTIME_DIR}/tunnel-output.tmp"
    tmux set-environment -t "$SESSION_NAME" -u DOEY_TUNNEL_URL 2>/dev/null || true
    echo "[tunnel] Stopped and cleaned up"
}

# --- Health check loop ---

_health_check() {
    while true; do
        sleep 30

        if [ ! -f "$TUNNEL_ENV" ]; then
            echo "[tunnel] tunnel.env missing, exiting health check"
            return
        fi

        local pid
        pid=$(_read_tunnel_pid)

        if [ -z "$pid" ]; then
            echo "[tunnel] No PID in tunnel.env, exiting health check"
            return
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[tunnel] Process $pid died, restarting tunnel"
            rm -f "$TUNNEL_ENV"

            local tool port
            tool=$(_detect_tunnel_tool)
            # Re-read port from the old env before it was removed
            port="${TUNNEL_PORTS%%,*}"
            port="${port%% *}"
            port="${port:-3000}"

            _start_tunnel "$tool" "$port"
        fi
    done
}

# --- Main ---

tool=$(_detect_tunnel_tool)
if [ -z "$tool" ]; then
    echo "[tunnel] No tunnel provider available (auto-checked: tailscale, cloudflared)."
    echo "[tunnel] Run \`doey tunnel setup\` to install Tailscale, or install cloudflared."
    cat > "$TUNNEL_ENV" <<EOF
TUNNEL_ERROR=no_tunnel_tool_found
TUNNEL_STARTED=$(date +%s)
EOF
    exit 0
fi

echo "[tunnel] Detected tool: $tool"

# Determine port: first entry from DOEY_TUNNEL_PORTS
port="${TUNNEL_PORTS%%,*}"
port="${port%% *}"
port="${port:-3000}"

# Tailscale: no child to supervise, no cleanup on exit (decision Q5 — the
# system-level daemon must outlive `doey stop`). Start, write env, exit.
if [ "$tool" = "tailscale" ]; then
    _start_tunnel "$tool" "$port" || true
    exit 0
fi

# Start tunnel (cloudflared / ngrok / bore — explicit user override only)
_start_tunnel "$tool" "$port"

# Trap EXIT for cleanup
trap _stop_tunnel EXIT

# Enter health check loop
_health_check
