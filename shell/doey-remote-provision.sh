#!/usr/bin/env bash
# doey-remote-provision.sh — Provision a fresh Ubuntu 24.04 server for Doey
# Usage: scp this to server, run as root: bash doey-remote-provision.sh <project-name>
set -euo pipefail

PROJECT="${1:?Usage: $0 <project-name>}"
DOEY_USER="doey"
DOEY_HOME="/home/${DOEY_USER}"
SWAP_SIZE="2G"

section() { printf '\n========================================\n  %s\n========================================\n\n' "$1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }
as_doey() { sudo -u "${DOEY_USER}" bash -c 'set -euo pipefail; export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env)"; '"$1"; }

[ "$(id -u)" -eq 0 ] || fail "This script must be run as root"
[ -f /etc/debian_version ] || fail "This script requires Debian or Ubuntu"

section "1/7 — System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || fail "apt-get update failed"
apt-get upgrade -y -qq || fail "apt-get upgrade failed"
apt-get install -y -qq tmux git curl build-essential ufw jq unzip locales htop \
    || fail "Package install failed"
locale-gen en_US.UTF-8 || true
timedatectl set-timezone UTC
echo "  Packages installed."

section "2/7 — Security hardening"
if id "${DOEY_USER}" >/dev/null 2>&1; then echo "  User '${DOEY_USER}' already exists."
else useradd -m -s /bin/bash -G sudo "${DOEY_USER}"; echo "  Created user '${DOEY_USER}'."; fi

echo "${DOEY_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${DOEY_USER}
chmod 440 /etc/sudoers.d/${DOEY_USER}

mkdir -p "${DOEY_HOME}/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "${DOEY_HOME}/.ssh/authorized_keys"
    chown -R "${DOEY_USER}:${DOEY_USER}" "${DOEY_HOME}/.ssh"
    chmod 700 "${DOEY_HOME}/.ssh"; chmod 600 "${DOEY_HOME}/.ssh/authorized_keys"
    echo "  SSH keys copied from root."
else echo "  WARNING: /root/.ssh/authorized_keys not found. Add keys manually."; fi

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh.service || fail "Failed to restart ssh.service"
echo "  SSH hardened: root login disabled, password auth disabled."
ufw allow OpenSSH
ufw allow 60000:61000/udp  # mosh
ufw --force enable
echo "  UFW enabled: SSH + mosh allowed."

section "3/7 — Swap (${SWAP_SIZE})"
if [ -f /swapfile ]; then echo "  Swap file already exists, skipping."
else
    fallocate -l "${SWAP_SIZE}" /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "  Swap created and enabled."
fi
sysctl vm.swappiness=10
grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
echo "  Swappiness set to 10."

section "4/7 — Node.js 22.x"
sudo -u "${DOEY_USER}" bash -c '
    set -euo pipefail
    command -v fnm >/dev/null 2>&1 || curl -fsSL https://fnm.vercel.app/install | bash
    export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env)"
    fnm install 22 || fnm install --lts
    node --version; npm --version
' || fail "Node.js installation failed"
echo "  Node.js installed."

section "5/7 — Claude Code"
as_doey 'npm install -g @anthropic-ai/claude-code; claude --version' \
  || fail "Claude Code installation failed"
echo "  Claude Code installed."

section "6/7 — Doey"
DOEY_REPO="${DOEY_HOME}/doey"
if [ -d "${DOEY_REPO}" ]; then
    echo "  Doey repo already exists, pulling latest."
    sudo -u "${DOEY_USER}" bash -c 'cd "$1" && git pull' -- "${DOEY_REPO}"
else
    sudo -u "${DOEY_USER}" git clone https://github.com/doeyai/doey.git "${DOEY_REPO}"
fi
sudo -u "${DOEY_USER}" bash -c 'cd "$1" && ./install.sh' -- "${DOEY_REPO}"
sudo -u "${DOEY_USER}" bash -c '
    grep -q "\.local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
    grep -q "fnm env" ~/.bashrc || echo "eval \"\$(fnm env 2>/dev/null)\"" >> ~/.bashrc
    grep -q "\.local/share/fnm" ~/.bashrc || echo "export PATH=\"\$HOME/.local/share/fnm:\$PATH\"" >> ~/.bashrc
'
chown -R "${DOEY_USER}:${DOEY_USER}" "${DOEY_HOME}"
echo "  Doey installed."

section "7/7 — Project: ${PROJECT}"
PROJECT_DIR="${DOEY_HOME}/${PROJECT}"
if [ "${PROJECT}" = "doey" ]; then echo "  Project is doey itself — already cloned."
else
    if [ -d "${PROJECT_DIR}" ]; then echo "  Project directory already exists."
    else
        sudo -u "${DOEY_USER}" mkdir -p "${PROJECT_DIR}"
        sudo -u "${DOEY_USER}" bash -c 'cd "$1" && git init' -- "${PROJECT_DIR}"
        echo "  Created ${PROJECT_DIR} with git repo."
    fi
    chown -R "${DOEY_USER}:${DOEY_USER}" "${PROJECT_DIR}"
fi

section "Provisioning complete!"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "  User:    ${DOEY_USER}"
echo "  Project: ${PROJECT_DIR}"
echo "  Node:    $(as_doey 'node --version' 2>/dev/null || echo 'check manually')"
echo ""
echo "  Next steps:"
echo "    1. SSH in:   ssh ${DOEY_USER}@${SERVER_IP}"
echo "    2. Auth:     claude auth   (or set ANTHROPIC_API_KEY)"
echo "    3. Launch:   cd ~/${PROJECT} && doey"
echo ""
echo "  Root login is now DISABLED. Use: ssh ${DOEY_USER}@${SERVER_IP}"
