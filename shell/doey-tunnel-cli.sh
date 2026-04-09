#!/usr/bin/env bash
set -euo pipefail

# doey-tunnel-cli.sh — User-facing CLI handlers for the tunnel feature.
#
# Sourced by shell/doey.sh. Exposes:
#   doey_tunnel_setup   — one-time install + auth for Tailscale (or chosen provider)
#   doey_tunnel_status  — show provider, hostname, watcher PID, detected URLs
#   doey_tunnel_up      — start the port-watcher daemon
#   doey_tunnel_down    — stop the watcher (leaves the underlying tunnel up)
#
# Depends on helpers sourced by doey.sh: _env_val, find_project, project_name_from_dir.
# Falls back to inline logic when those helpers are not present (e.g. sourced standalone).

# ── Internal helpers ─────────────────────────────────────────────────

# Print to stderr. Usage: _t_err "message"
_t_err() { printf '%s\n' "$*" >&2; }

# Resolve the project name used by /tmp/doey/<project>/.
# Honors $PROJECT_NAME from sourcing context first, then $DOEY_PROJECT, then pwd-derived.
_t_project_name() {
  if [ -n "${PROJECT_NAME:-}" ]; then
    printf '%s' "$PROJECT_NAME"
    return 0
  fi
  if [ -n "${DOEY_PROJECT:-}" ]; then
    printf '%s' "$DOEY_PROJECT"
    return 0
  fi
  if type project_name_from_dir >/dev/null 2>&1; then
    project_name_from_dir "$(pwd)"
    return 0
  fi
  # Last-ditch fallback: basename of pwd, sanitized minimally.
  local _raw="${PWD##*/}"
  [ -n "$_raw" ] || _raw="default"
  printf '%s' "$_raw"
}

# Resolve the runtime directory /tmp/doey/<project>.
# Honors $DOEY_RUNTIME first (set by on-session-start.sh in a live pane),
# then tmux session env if tmux is available, then derives from project name.
_t_runtime_dir() {
  if [ -n "${DOEY_RUNTIME:-}" ] && [ -d "$DOEY_RUNTIME" ]; then
    printf '%s' "$DOEY_RUNTIME"
    return 0
  fi
  local _pn
  _pn="$(_t_project_name)"
  printf '%s' "/tmp/doey/${_pn}"
}

# Read a single key from an env file using _env_val if available, or a pure-bash loop.
# Usage: _t_env_val <file> <KEY> [default]
_t_env_val() {
  if type _env_val >/dev/null 2>&1; then
    _env_val "$@"
    return 0
  fi
  local _f="$1" _k="$2" _d="${3:-}" _line
  if [ ! -f "$_f" ]; then
    [ -n "$_d" ] && printf '%s\n' "$_d"
    return 0
  fi
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "${_k}="*)
        _line="${_line#*=}"
        _line="${_line//\"/}"
        printf '%s\n' "$_line"
        return 0
        ;;
    esac
  done < "$_f"
  [ -n "$_d" ] && printf '%s\n' "$_d"
  return 0
}

# Check whether a PID is alive. Returns 0 if alive.
_t_pid_alive() {
  local _p="${1:-}"
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null
}

# Prompt user for y/N confirmation. Default No. Returns 0 if yes.
_t_confirm() {
  local _prompt="$1" _reply=""
  printf '%s [y/N] ' "$_prompt"
  IFS= read -r _reply || return 1
  case "$_reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── doey tunnel setup ────────────────────────────────────────────────

doey_tunnel_setup() {
  local _conf_dir="${HOME}/.config/doey"
  local _conf_file="${_conf_dir}/tunnel.conf"

  printf '\n'
  printf '  Doey tunnel setup (provider: tailscale)\n'
  printf '  ---------------------------------------\n\n'

  # Step 1: detect or install tailscale
  if ! command -v tailscale >/dev/null 2>&1; then
    local _os
    _os="$(uname -s 2>/dev/null || echo unknown)"
    if [ "$_os" != "Linux" ]; then
      _t_err "tailscale binary not found and automatic install is only supported on Linux."
      _t_err "Install manually: https://tailscale.com/download"
      return 2
    fi
    printf '  tailscale is not installed.\n'
    printf '  Install command: curl -fsSL https://tailscale.com/install.sh | sh\n'
    printf '  This requires sudo. You may be prompted for your password.\n\n'
    if ! _t_confirm "  Run the installer now?"; then
      printf '\n  Install skipped. Re-run `doey tunnel setup` when ready.\n\n'
      return 1
    fi
    printf '\n  Installing tailscale...\n'
    if ! curl -fsSL https://tailscale.com/install.sh | sh; then
      _t_err "tailscale install script failed. See output above."
      return 2
    fi
    printf '  Install complete.\n\n'
  else
    printf '  tailscale is already installed: %s\n\n' "$(command -v tailscale)"
  fi

  # Step 2: run `tailscale up` so the user can click the login URL on their laptop.
  printf '  Running: sudo tailscale up\n'
  printf '  Follow the login URL printed below on your laptop browser.\n\n'
  if ! sudo tailscale up; then
    _t_err "tailscale up failed. Check network/sudo access and try again."
    return 2
  fi

  # Step 3: fetch the MagicDNS hostname (or fall back to tailscale IP).
  local _hostname=""
  if command -v jq >/dev/null 2>&1; then
    _hostname="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null || true)"
    # Strip trailing dot from FQDN.
    _hostname="${_hostname%.}"
    # jq prints literal "null" on missing field — treat as empty.
    [ "$_hostname" = "null" ] && _hostname=""
  fi
  if [ -z "$_hostname" ]; then
    _hostname="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$_hostname" ]; then
    _t_err "Could not determine tailscale hostname or IP after 'tailscale up'."
    _t_err "Run 'tailscale status' manually to debug."
    return 2
  fi

  # Step 4: persist provider choice.
  mkdir -p "$_conf_dir"
  {
    printf 'TUNNEL_PROVIDER=tailscale\n'
    printf 'TUNNEL_HOSTNAME=%s\n' "$_hostname"
  } > "$_conf_file"

  printf '\n'
  printf '  Tunnel hostname: %s\n' "$_hostname"
  printf '  Wrote: %s\n' "$_conf_file"
  printf '\n'
  printf '  Next: run `doey tunnel up` to start the port watcher.\n\n'
  return 0
}

# ── doey tunnel status ───────────────────────────────────────────────

doey_tunnel_status() {
  local _runtime
  _runtime="$(_t_runtime_dir)"
  local _conf_file="${HOME}/.config/doey/tunnel.conf"
  local _tunnel_env="${_runtime}/tunnel.env"
  local _pid_file="${_runtime}/port-watcher.pid"

  printf '\n'
  printf '  Doey tunnel status\n'
  printf '  ------------------\n\n'

  # Provider + hostname — prefer runtime tunnel.env (live state), fall back to user conf.
  local _provider="" _hostname=""
  if [ -f "$_tunnel_env" ]; then
    _provider="$(_t_env_val "$_tunnel_env" TUNNEL_PROVIDER)"
    _hostname="$(_t_env_val "$_tunnel_env" TUNNEL_HOSTNAME)"
    # tunnel.env may use TUNNEL_URL for legacy providers (cloudflared/ngrok/bore).
    if [ -z "$_hostname" ]; then
      _hostname="$(_t_env_val "$_tunnel_env" TUNNEL_URL)"
    fi
  fi
  if [ -z "$_provider" ] && [ -f "$_conf_file" ]; then
    _provider="$(_t_env_val "$_conf_file" TUNNEL_PROVIDER)"
  fi
  if [ -z "$_hostname" ] && [ -f "$_conf_file" ]; then
    _hostname="$(_t_env_val "$_conf_file" TUNNEL_HOSTNAME)"
  fi

  if [ -z "$_provider" ]; then
    printf '  Provider : (none — run `doey tunnel setup`)\n'
  else
    printf '  Provider : %s\n' "$_provider"
  fi
  if [ -n "$_hostname" ]; then
    printf '  Hostname : %s\n' "$_hostname"
  else
    printf '  Hostname : (unknown)\n'
  fi
  printf '  Runtime  : %s\n' "$_runtime"

  # Watcher PID.
  local _watcher_pid=""
  if [ -f "$_pid_file" ]; then
    _watcher_pid="$(head -1 "$_pid_file" 2>/dev/null || true)"
  fi
  if [ -n "$_watcher_pid" ] && _t_pid_alive "$_watcher_pid"; then
    printf '  Watcher  : running (PID %s)\n' "$_watcher_pid"
  else
    printf '  Watcher  : not running\n'
    printf '\n  Run `doey tunnel up` to start the port watcher.\n\n'
    return 0
  fi

  # Detected ports — parse TUNNEL_PORTS_LIST=port:proc,port:proc,...
  local _ports_env="${_runtime}/tunnel-ports.env"
  local _ports_list=""
  if [ -f "$_ports_env" ]; then
    _ports_list="$(_t_env_val "$_ports_env" TUNNEL_PORTS_LIST)"
  fi

  printf '\n'
  if [ -z "$_ports_list" ]; then
    printf '  No dev-server ports detected yet.\n\n'
    return 0
  fi

  printf '  Detected dev servers:\n'
  local _item _port _proc _old_ifs="$IFS"
  IFS=','
  for _item in $_ports_list; do
    [ -n "$_item" ] || continue
    _port="${_item%%:*}"
    _proc="${_item#*:}"
    [ "$_proc" = "$_item" ] && _proc=""
    if [ -n "$_hostname" ]; then
      if [ -n "$_proc" ]; then
        printf '    http://%s:%s  (%s)\n' "$_hostname" "$_port" "$_proc"
      else
        printf '    http://%s:%s\n' "$_hostname" "$_port"
      fi
    else
      if [ -n "$_proc" ]; then
        printf '    port %s  (%s)\n' "$_port" "$_proc"
      else
        printf '    port %s\n' "$_port"
      fi
    fi
  done
  IFS="$_old_ifs"
  printf '\n'
  return 0
}

# ── doey tunnel up ───────────────────────────────────────────────────

doey_tunnel_up() {
  local _runtime
  _runtime="$(_t_runtime_dir)"
  local _conf_file="${HOME}/.config/doey/tunnel.conf"
  local _pid_file="${_runtime}/port-watcher.pid"
  local _log_file="${_runtime}/port-watcher.log"

  if [ ! -f "$_conf_file" ]; then
    _t_err "No tunnel provider configured."
    _t_err "Run: doey tunnel setup"
    return 1
  fi

  mkdir -p "$_runtime"

  # Refuse if already running.
  if [ -f "$_pid_file" ]; then
    local _existing
    _existing="$(head -1 "$_pid_file" 2>/dev/null || true)"
    if [ -n "$_existing" ] && _t_pid_alive "$_existing"; then
      printf '  Port watcher already running (PID %s)\n' "$_existing"
      return 0
    fi
    # Stale — remove and continue.
    rm -f "$_pid_file"
  fi

  # Locate the watcher script next to this file.
  local _script_dir _watcher
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _watcher="${_script_dir}/doey-port-watcher.sh"

  if [ ! -f "$_watcher" ]; then
    _t_err "Port watcher script not found: $_watcher"
    _t_err "Reinstall doey or run: doey update"
    return 2
  fi

  # Invoking `doey tunnel up` IS the opt-in. Export the guard so the child
  # watcher (which honors DOEY_TUNNEL_ENABLED as an auto-start gate) runs.
  export DOEY_TUNNEL_ENABLED=1
  # The watcher hard-requires PROJECT_NAME for its runtime-dir derivation.
  # Export both so the spawned child inherits them regardless of how the
  # CLI was invoked (in-tmux pane with env, or a bare shell outside a session).
  export PROJECT_NAME="${PROJECT_NAME:-$(_t_project_name)}"
  export PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

  # Spawn the watcher detached from the current shell.
  # nohup + & keeps it running after the CLI exits.
  nohup bash "$_watcher" "$_runtime" >"$_log_file" 2>&1 &
  local _new_pid=$!

  # Small sanity check — give it a moment to start, then verify.
  sleep 1
  if ! _t_pid_alive "$_new_pid"; then
    _t_err "Port watcher failed to start. See $_log_file"
    return 2
  fi

  printf '%s\n' "$_new_pid" > "$_pid_file"
  printf '\n'
  printf '  Port watcher started (PID %s)\n' "$_new_pid"
  printf '  Log: %s\n' "$_log_file"
  printf '  Run `doey tunnel status` to see detected ports.\n\n'
  return 0
}

# ── doey tunnel down ─────────────────────────────────────────────────

doey_tunnel_down() {
  local _runtime
  _runtime="$(_t_runtime_dir)"
  local _pid_file="${_runtime}/port-watcher.pid"

  if [ ! -f "$_pid_file" ]; then
    printf '  Port watcher is not running.\n'
    printf '  (Tailscale, if configured, is still up. Run `sudo tailscale down` to disconnect.)\n'
    return 0
  fi

  local _pid
  _pid="$(head -1 "$_pid_file" 2>/dev/null || true)"

  if [ -z "$_pid" ] || ! _t_pid_alive "$_pid"; then
    rm -f "$_pid_file"
    printf '  Port watcher was not running (stale PID file removed).\n'
    return 0
  fi

  kill "$_pid" 2>/dev/null || true

  # Wait up to 2s for graceful exit.
  local _i=0
  while [ "$_i" -lt 4 ]; do
    _t_pid_alive "$_pid" || break
    sleep 0.5 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done

  if _t_pid_alive "$_pid"; then
    kill -9 "$_pid" 2>/dev/null || true
  fi

  rm -f "$_pid_file"
  printf '\n'
  printf '  Port watcher stopped.\n'
  printf '  Tailscale is still up — run `sudo tailscale down` to disconnect.\n\n'
  return 0
}
