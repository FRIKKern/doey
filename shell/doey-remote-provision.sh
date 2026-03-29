#!/usr/bin/env bash
# doey-remote-provision.sh — Provision a fresh Ubuntu 24.04 server for Doey
# Usage: scp this to server, run as root: bash doey-remote-provision.sh <project-name>
set -euo pipefail

PROJECT="${1:?Usage: $0 <project-name>}"
DOEY_USER="doey"
DOEY_HOME="/home/${DOEY_USER}"
SWAP_SIZE="2G"

# --- Helpers ---

section() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
    echo ""
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# Must run as root
[ "$(id -u)" -eq 0 ] || fail "This script must be run as root"

# =============================================================================
# 1. System Setup
# =============================================================================
section "1/7 — System packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || fail "apt-get update failed"
apt-get upgrade -y -qq || fail "apt-get upgrade failed"
apt-get install -y -qq tmux git curl build-essential ufw jq unzip locales htop \
    || fail "Package install failed"
locale-gen en_US.UTF-8 || true

# Timezone
timedatectl set-timezone UTC
echo "  Timezone: $(timedatectl show --property=Timezone --value)"
echo "  Packages installed."

# =============================================================================
# 2. Security Hardening
# =============================================================================
section "2/7 — Security hardening"

# Create doey user (idempotent)
if id "${DOEY_USER}" &>/dev/null; then
    echo "  User '${DOEY_USER}' already exists, skipping creation."
else
    useradd -m -s /bin/bash -G sudo "${DOEY_USER}"
    echo "  Created user '${DOEY_USER}'."
fi

# Passwordless sudo
echo "${DOEY_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${DOEY_USER}
chmod 440 /etc/sudoers.d/${DOEY_USER}

# SSH keys — copy from root
mkdir -p "${DOEY_HOME}/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "${DOEY_HOME}/.ssh/authorized_keys"
    chown -R "${DOEY_USER}:${DOEY_USER}" "${DOEY_HOME}/.ssh"
    chmod 700 "${DOEY_HOME}/.ssh"
    chmod 600 "${DOEY_HOME}/.ssh/authorized_keys"
    echo "  SSH keys copied from root."
else
    echo "  WARNING: /root/.ssh/authorized_keys not found. Add keys manually."
fi

# Harden SSH config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh.service || fail "Failed to restart ssh.service"
echo "  SSH hardened: root login disabled, password auth disabled."

# Firewall
ufw --force enable
ufw allow OpenSSH
ufw allow 60000:61000/udp  # mosh
echo "  UFW enabled: SSH + mosh allowed."

# =============================================================================
# 3. Swap Setup
# =============================================================================
section "3/7 — Swap (${SWAP_SIZE})"

if [ -f /swapfile ]; then
    echo "  Swap file already exists, skipping."
else
    fallocate -l "${SWAP_SIZE}" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    # Persist across reboots
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "  Swap created and enabled."
fi

# Swappiness
sysctl vm.swappiness=10
if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi
echo "  Swappiness set to 10."

# =============================================================================
# 4. Node.js Setup
# =============================================================================
section "4/7 — Node.js 22.x"

# Install fnm (Fast Node Manager) for the doey user
sudo -u "${DOEY_USER}" bash -c '
    set -euo pipefail
    if command -v fnm &>/dev/null; then
        echo "  fnm already installed."
    else
        curl -fsSL https://fnm.vercel.app/install | bash
    fi
    export PATH="$HOME/.local/share/fnm:$PATH"
    eval "$(fnm env)"
    fnm install 22 || fnm install --lts
    node --version
    npm --version
' || fail "Node.js installation failed"

echo "  Node.js installed."

# =============================================================================
# 5. Claude Code Install
# =============================================================================
section "5/7 — Claude Code"

sudo -u "${DOEY_USER}" bash -c '
    set -euo pipefail
    export PATH="$HOME/.local/share/fnm:$PATH"
    eval "$(fnm env)"
    npm install -g @anthropic-ai/claude-code
    claude --version
' || fail "Claude Code installation failed"

echo "  Claude Code installed."

# =============================================================================
# 6. Doey Install
# =============================================================================
section "6/7 — Doey"

DOEY_REPO="${DOEY_HOME}/doey"

if [ -d "${DOEY_REPO}" ]; then
    echo "  Doey repo already exists, pulling latest."
    sudo -u "${DOEY_USER}" bash -c "cd ${DOEY_REPO} && git pull"
else
    sudo -u "${DOEY_USER}" git clone https://github.com/doeyai/doey.git "${DOEY_REPO}"
fi

sudo -u "${DOEY_USER}" bash -c "cd ${DOEY_REPO} && ./install.sh"

# Ensure PATH includes ~/.local/bin
sudo -u "${DOEY_USER}" bash -c '
    grep -q "\.local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
'

# Fix ownership (belt and suspenders)
chown -R "${DOEY_USER}:${DOEY_USER}" "${DOEY_HOME}"

echo "  Doey installed."

# =============================================================================
# 7. Project Init
# =============================================================================
section "7/7 — Project: ${PROJECT}"

PROJECT_DIR="${DOEY_HOME}/${PROJECT}"

if [ "${PROJECT}" = "doey" ]; then
    echo "  Project is doey itself — already cloned."
else
    if [ -d "${PROJECT_DIR}" ]; then
        echo "  Project directory already exists."
    else
        sudo -u "${DOEY_USER}" mkdir -p "${PROJECT_DIR}"
        sudo -u "${DOEY_USER}" bash -c "cd ${PROJECT_DIR} && git init"
        echo "  Created ${PROJECT_DIR} with git repo."
    fi
    chown -R "${DOEY_USER}:${DOEY_USER}" "${PROJECT_DIR}"
fi

# =============================================================================
# Done
# =============================================================================
section "Provisioning complete!"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo "  User:    ${DOEY_USER}"
echo "  Project: ${PROJECT_DIR}"
echo "  Node:    $(sudo -u ${DOEY_USER} bash -c 'export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env)"; node --version' 2>/dev/null || echo 'check manually')"
echo ""
echo "  Next steps:"
echo "    1. SSH in:   ssh ${DOEY_USER}@${SERVER_IP}"
echo "    2. Auth:     claude auth   (or set ANTHROPIC_API_KEY)"
echo "    3. Launch:   cd ~/${PROJECT} && doey"
echo ""
echo "  Root login is now DISABLED. Use: ssh ${DOEY_USER}@${SERVER_IP}"
echo ""

exit 0
