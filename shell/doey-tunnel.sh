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
    local _pid=""
    while IFS='=' read -r k v; do
        case "$k" in TUNNEL_PID) _pid="$v" ;; esac
    done < "$TUNNEL_ENV"
    printf '%s' "$_pid"
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
    # Auto-detect in priority order
    local tool
    for tool in cloudflared ngrok bore; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "$tool"
            return
        fi
    done
    echo ""
}

# --- Start tunnel ---

_start_tunnel() {
    local tool="$1"
    local port="$2"
    local log_file="${RUNTIME_DIR}/tunnel-output.tmp"

    echo "[tunnel] Starting $tool on port $port"

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
    echo "[tunnel] No tunnel tool found (checked: cloudflared, ngrok, bore)"
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

# Start tunnel
_start_tunnel "$tool" "$port"

# Trap EXIT for cleanup
trap _stop_tunnel EXIT

# Enter health check loop
_health_check
