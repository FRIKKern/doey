#!/usr/bin/env bash
# doey-remote.sh — Remote server management functions shared across Doey scripts.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_remote_sourced:-}" = "1" ] && return 0
__doey_remote_sourced=1

# ── Tunnel Configuration ─────────────────────────────────────────────
DOEY_TUNNEL_ENABLED="${DOEY_TUNNEL_ENABLED:-false}"
DOEY_TUNNEL_PROVIDER="${DOEY_TUNNEL_PROVIDER:-auto}"
DOEY_TUNNEL_PORTS="${DOEY_TUNNEL_PORTS:-}"
DOEY_TUNNEL_DOMAIN="${DOEY_TUNNEL_DOMAIN:-}"

# ── Tunnel Functions ─────────────────────────────────────────────────

# Detect whether the current session is running remotely (SSH, container, etc.)
_detect_remote() {
  if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    echo "true"
  elif [ -f "/.dockerenv" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# Start tunnel if enabled and running remotely
_maybe_start_tunnel() {
  local runtime_dir="$1" is_remote="$2"
  [ "$DOEY_TUNNEL_ENABLED" = "true" ] && [ "$is_remote" = "true" ] || return 0
  local tunnel_script="${DOEY_DIR}/shell/doey-tunnel.sh"
  [ -f "$tunnel_script" ] && bash "$tunnel_script" "$runtime_dir" >> "${runtime_dir}/tunnel.log" 2>&1 &
}

# ── Hetzner Cloud CLI ────────────────────────────────────────────────

_doey_ensure_hcloud() {
  # Already installed? Done.
  command -v hcloud >/dev/null 2>&1 && return 0

  printf '\n'
  doey_warn "hcloud CLI not found."
  printf "  The Hetzner Cloud CLI is required for remote server management.\n\n"

  # Detect OS
  local os_type=""
  case "$(uname -s)" in
    Darwin*) os_type="macos" ;;
    Linux*)  os_type="linux" ;;
    *)       os_type="unknown" ;;
  esac

  # Ask user
  local install_method=""
  if [ "$os_type" = "macos" ]; then
    if command -v brew >/dev/null 2>&1; then
      install_method="brew"
      printf "  Install hcloud via Homebrew? [Y/n] "
    else
      doey_error "Homebrew not found."
      printf "  Install hcloud manually:\n"
      printf "  ${BOLD}brew install hcloud${RESET} (after installing Homebrew) or\n"
      printf "  See https://github.com/hetznercloud/cli/releases\n"
      return 1
    fi
  elif [ "$os_type" = "linux" ]; then
    install_method="script"
    printf "  Install hcloud via official install script? [Y/n] "
  else
    doey_error "Unsupported OS."
    printf "  Install hcloud manually from:\n"
    printf "  https://github.com/hetznercloud/cli/releases\n"
    return 1
  fi

  local reply=""
  read -r reply
  case "$reply" in
    [Nn]*)
      printf "\n  To install hcloud manually:\n"
      if [ "$os_type" = "macos" ]; then
        printf "    ${BOLD}brew install hcloud${RESET}\n"
      else
        printf "    ${BOLD}curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin/${RESET}\n"
      fi
      printf "  Then re-run: ${BOLD}doey remote setup <project>${RESET}\n\n"
      return 1
      ;;
  esac

  # Install
  printf "\n"
  if [ "$install_method" = "brew" ]; then
    doey_info "Running: brew install hcloud ..."
    if ! brew install hcloud 2>&1 | sed 's/^/  /'; then
      doey_error "brew install failed."
      return 1
    fi
  elif [ "$install_method" = "script" ]; then
    doey_info "Downloading hcloud from GitHub releases..."
    local arch=""
    case "$(uname -m)" in
      x86_64|amd64)  arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *)
        doey_error "Unsupported architecture: $(uname -m)"
        return 1
        ;;
    esac
    local tmp_dir=""
    tmp_dir="$(mktemp -d)"
    local url="https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-${arch}.tar.gz"
    if ! curl -sSL "$url" -o "${tmp_dir}/hcloud.tar.gz" 2>&1; then
      doey_error "Download failed."
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! tar xzf "${tmp_dir}/hcloud.tar.gz" -C "$tmp_dir" 2>&1; then
      doey_error "Extract failed."
      rm -rf "$tmp_dir"
      return 1
    fi
    # Try /usr/local/bin first, fall back to ~/.local/bin
    local install_dir="/usr/local/bin"
    if [ ! -w "$install_dir" ]; then
      install_dir="$HOME/.local/bin"
      mkdir -p "$install_dir"
    fi
    if ! mv "${tmp_dir}/hcloud" "${install_dir}/hcloud" 2>/dev/null; then
      doey_info "Trying with sudo..."
      if ! sudo mv "${tmp_dir}/hcloud" "/usr/local/bin/hcloud"; then
        doey_error "Install failed. Move hcloud to your PATH manually."
        printf "  Binary is at: ${tmp_dir}/hcloud\n"
        return 1
      fi
      install_dir="/usr/local/bin"
    fi
    chmod +x "${install_dir}/hcloud"
    rm -rf "$tmp_dir"
    # Ensure install_dir is in PATH for this session
    case ":$PATH:" in
      *":${install_dir}:"*) ;;
      *) export PATH="${install_dir}:${PATH}" ;;
    esac
    doey_info "Installed to ${install_dir}/hcloud"
  fi

  # Verify
  if ! command -v hcloud >/dev/null 2>&1; then
    doey_error "hcloud still not found on PATH after install."
    printf "  You may need to restart your shell or add it to your PATH.\n"
    return 1
  fi

  local hcloud_ver=""
  hcloud_ver="$(hcloud version 2>/dev/null | head -1 || echo "unknown")"
  doey_success "hcloud installed: ${hcloud_ver}"
  printf '\n'
  return 0
}

# Ensure hcloud is authenticated (has an active context with a valid token).
# If not, interactively prompt the user to paste their API token.
_doey_ensure_hcloud_auth() {
  # Already authenticated — skip
  if hcloud server list >/dev/null 2>&1; then
    return 0
  fi

  printf '\n'
  doey_warn "hcloud is not authenticated."
  printf "  You need a Hetzner Cloud API token.\n"
  printf "  Create one at: ${BOLD}https://console.hetzner.cloud${RESET}\n"
  printf "  (Project → Security → API Tokens → Generate)\n\n"

  local token=""
  printf "  API Token: "
  read -rs token
  printf "\n"

  if [ -z "$token" ]; then
    doey_error "No token provided. Aborting."
    return 1
  fi

  # Create hcloud context with the provided token
  if ! echo "$token" | hcloud context create doey 2>&1 | sed 's/^/  /'; then
    doey_error "Failed to create hcloud context."
    printf "  Check that your token is valid and try again.\n"
    return 1
  fi

  # Verify the token actually works
  if ! hcloud server list >/dev/null 2>&1; then
    doey_error "Authentication failed — token may be invalid or expired."
    printf "  Delete the context with: ${BOLD}hcloud context delete doey${RESET}\n"
    printf "  Then re-run: ${BOLD}doey remote setup <project>${RESET}\n"
    return 1
  fi

  doey_success "Authenticated with Hetzner Cloud."
  printf '\n'
  return 0
}

# ── Remote Commands ──────────────────────────────────────────────────

doey_remote() {
  local remotes_dir="$HOME/.config/doey/remotes"
  mkdir -p "$remotes_dir"

  local subcmd="${1:-list}"

  case "$subcmd" in
    list)
      # List all remotes
      local remote_files
      remote_files=$(ls "$remotes_dir"/*.remote 2>/dev/null || true)
      if [ -z "$remote_files" ]; then
        printf "\n  ${DIM}No remote servers configured.${RESET}\n\n"
        printf "  Usage: ${BOLD}doey remote <project>${RESET}  — provision & attach to a remote server\n"
        printf "         ${BOLD}doey remote stop <project>${RESET} — destroy a remote server\n"
        printf "         ${BOLD}doey remote status <project>${RESET} — show server status\n\n"
        return 0
      fi
      printf "\n  ${BOLD}%-20s %-16s %-10s %-10s %s${RESET}\n" "PROJECT" "SERVER_IP" "STATUS" "PROVIDER" "CREATED"
      printf "  ${DIM}%-20s %-16s %-10s %-10s %s${RESET}\n" "───────" "─────────" "──────" "────────" "───────"
      local f
      for f in $remote_files; do
        [ -f "$f" ] || continue
        local r_project r_ip r_status r_provider r_created
        r_project="$(basename "$f" .remote)"
        r_ip="$(grep '^SERVER_IP=' "$f" 2>/dev/null | cut -d= -f2- || echo "—")"
        r_status="$(grep '^STATUS=' "$f" 2>/dev/null | cut -d= -f2- || echo "unknown")"
        r_provider="$(grep '^PROVIDER=' "$f" 2>/dev/null | cut -d= -f2- || echo "—")"
        r_created="$(grep '^CREATED=' "$f" 2>/dev/null | cut -d= -f2- || echo "—")"
        printf "  %-20s %-16s %-10s %-10s %s\n" "$r_project" "$r_ip" "$r_status" "$r_provider" "$r_created"
      done
      printf "\n"
      ;;

    stop)
      local project="${2:-}"
      [ -z "$project" ] && { doey_error "Usage: doey remote stop <project>"; return 1; }
      local remote_file="$remotes_dir/${project}.remote"
      [ -f "$remote_file" ] || { doey_error "No remote config found for '$project'"; return 1; }

      if ! _doey_ensure_hcloud; then
        return 1
      fi

      local server_name
      server_name="$(grep '^SERVER_NAME=' "$remote_file" | cut -d= -f2-)"
      [ -z "$server_name" ] && { doey_error "No SERVER_NAME in $remote_file"; return 1; }

      doey_info "Deleting server ${server_name}..."
      if hcloud server delete "$server_name" 2>/dev/null; then
        doey_ok "Server deleted."
      else
        doey_warn "Server may already be deleted."
      fi

      doey_info "Removing SSH key..."
      hcloud ssh-key delete "doey-${project}" 2>/dev/null || true

      command -v trash >/dev/null 2>&1 && trash "$remote_file" || rm -f "$remote_file"
      doey_ok "Remote '$project' removed."
      printf '\n'
      ;;

    status)
      local project="${2:-}"
      [ -z "$project" ] && { doey_error "Usage: doey remote status <project>"; return 1; }
      local remote_file="$remotes_dir/${project}.remote"
      [ -f "$remote_file" ] || { doey_error "No remote config found for '$project'"; return 1; }

      if ! _doey_ensure_hcloud; then
        return 1
      fi

      printf "\n  ${BOLD}Remote: %s${RESET}\n\n" "$project"
      local key val
      while IFS='=' read -r key val; do
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue
        printf "  %-15s %s\n" "$key" "$val"
      done < "$remote_file"

      local server_name
      server_name="$(grep '^SERVER_NAME=' "$remote_file" | cut -d= -f2-)"
      if [ -n "$server_name" ]; then
        printf "\n  ${DIM}Live status from Hetzner:${RESET}\n"
        hcloud server describe "$server_name" 2>/dev/null | head -20 | sed 's/^/  /' || printf "  ${WARN}Could not query server (may be deleted)${RESET}\n"
      fi
      printf "\n"
      ;;

    *)
      # Positional arg = project name → provision or attach
      local project="$subcmd"
      _doey_remote_provision "$project"
      ;;
  esac
}

_doey_remote_provision() {
  local project="$1"
  if [ -z "$project" ] || ! echo "$project" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'; then
    doey_error "Invalid project name."
    printf "  Use only letters, numbers, hyphens, and underscores.\n"
    return 1
  fi
  local remotes_dir="$HOME/.config/doey/remotes"
  local remote_file="$remotes_dir/${project}.remote"
  local ssh_key="$remotes_dir/doey_ed25519"
  local server_name="doey-${project}"

  # Check prerequisites
  if ! _doey_ensure_hcloud; then
    return 1
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    doey_error "ssh not found."
    return 1
  fi

  # Ensure hcloud is authenticated (prompts interactively if needed)
  if ! _doey_ensure_hcloud_auth; then
    return 1
  fi

  # If .remote file exists, check if server is still running
  if [ -f "$remote_file" ]; then
    local existing_ip existing_name
    existing_ip="$(grep '^SERVER_IP=' "$remote_file" | cut -d= -f2-)"
    existing_name="$(grep '^SERVER_NAME=' "$remote_file" | cut -d= -f2-)"

    if [ -n "$existing_name" ] && hcloud server describe "$existing_name" >/dev/null 2>&1; then
      doey_ok "Server '$existing_name' is running at $existing_ip"
      doey_info "Attaching..."
      _doey_remote_attach "$project" "$existing_ip"
      return $?
    else
      doey_warn "Server from config is gone. Re-provisioning..."
      command -v trash >/dev/null 2>&1 && trash "$remote_file" || rm -f "$remote_file"
    fi
  fi

  # Generate SSH key if needed
  if [ ! -f "$ssh_key" ]; then
    doey_info "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "doey-remote" >/dev/null 2>&1
  fi

  # Upload SSH key to Hetzner (delete old one first if exists)
  hcloud ssh-key delete "doey-${project}" 2>/dev/null || true
  doey_info "Uploading SSH key to Hetzner..."
  if ! hcloud ssh-key create --name "doey-${project}" --public-key-from-file "${ssh_key}.pub" >/dev/null 2>&1; then
    doey_error "Failed to upload SSH key to Hetzner"
    return 1
  fi

  # Create server
  doey_info "Creating server '${server_name}' (cx22, Ubuntu 24.04, nbg1)..."
  local create_output
  if ! create_output=$(hcloud server create \
    --name "$server_name" \
    --type cx22 \
    --image ubuntu-24.04 \
    --location nbg1 \
    --ssh-key "doey-${project}" 2>&1); then
    doey_error "Failed to create server."
    printf "  Check hcloud output:\n"
    echo "$create_output" | sed 's/^/  /'
    return 1
  fi

  # Wait for IP
  doey_info "Waiting for server IP..."
  local server_ip=""
  local attempts=0
  while [ -z "$server_ip" ] || [ "$server_ip" = "-" ]; do
    if [ "$attempts" -ge 30 ]; then
      doey_error "Timed out waiting for server IP"
      return 1
    fi
    sleep 2
    server_ip="$(hcloud server ip "$server_name" 2>/dev/null || echo "")"
    attempts=$((attempts + 1))
  done
  doey_ok "Server ready at ${server_ip}"

  # Wait for SSH to become available
  doey_info "Waiting for SSH..."
  attempts=0
  while ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$ssh_key" root@"$server_ip" "echo ok" >/dev/null 2>&1; do
    if [ "$attempts" -ge 30 ]; then
      doey_error "Timed out waiting for SSH"
      return 1
    fi
    sleep 3
    attempts=$((attempts + 1))
  done

  # Copy and run provisioning script
  local provision_script="$HOME/.local/bin/doey-remote-provision.sh"
  if [ ! -f "$provision_script" ]; then
    doey_error "Provisioning script not found at $provision_script"
    printf "  Run ${BOLD}doey update${RESET} to install it.\n"
    return 1
  fi

  doey_info "Uploading provisioning script..."
  scp -o StrictHostKeyChecking=accept-new -i "$ssh_key" "$provision_script" root@"$server_ip":/tmp/doey-remote-provision.sh >/dev/null 2>&1

  doey_info "Provisioning server (this may take a few minutes)..."
  if ! ssh -o StrictHostKeyChecking=accept-new -i "$ssh_key" root@"$server_ip" "bash /tmp/doey-remote-provision.sh '$project'" 2>&1 | sed 's/^/  /'; then
    doey_error "Provisioning failed."
    return 1
  fi

  # Save state
  local server_id
  server_id="$(hcloud server describe "$server_name" -o format='{{.ID}}' 2>/dev/null || echo "unknown")"
  cat > "$remote_file" << REMOTE_EOF
SERVER_ID=$server_id
SERVER_IP=$server_ip
SERVER_NAME=$server_name
PROVIDER=hetzner
STATUS=running
CREATED=$(date +%Y-%m-%dT%H:%M:%S)
REMOTE_EOF

  doey_success "Server provisioned and ready!"
  _doey_remote_attach "$project" "$server_ip"
}

_doey_remote_attach() {
  local project="$1"
  local ip="$2"
  local ssh_key="$HOME/.config/doey/remotes/doey_ed25519"

  doey_info "Connecting to doey@${ip}..."
  printf '\n'
  ssh -t \
    -o StrictHostKeyChecking=accept-new \
    -i "$ssh_key" \
    doey@"$ip" \
    "cd '/home/doey/${project}' && doey"
}
