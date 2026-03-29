# Linode Setup Guide

> Deploy Doey on a Linode VPS — start a task, detach, come back to find work done.

## Prerequisites

```bash
# Local machine
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
pip install linode-cli
linode-cli configure   # API token: cloud.linode.com/profile/tokens
```

Also need: **Anthropic API key** (`sk-ant-...`) or **Claude Max** (OAuth).

## 1. Provision

Doey is network-bound — a Nanode ($5/mo) handles most workloads. Upgrade to `g6-standard-1` (2 GB, $12/mo) or `g6-standard-2` (4 GB, $24/mo) if needed.

```bash
ROOT_PASS="$(openssl rand -base64 24)"
echo "Root password: $ROOT_PASS"   # Save this

linode-cli linodes create \
  --type g6-nanode-1 --region us-east --image linode/ubuntu24.04 \
  --label doey-server --root_pass "$ROOT_PASS" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)" --json

LINODE_IP=$(linode-cli linodes list --label doey-server --json | jq -r '.[0].ipv4[0]')
echo "Server IP: $LINODE_IP"

# Wait for boot (~60s)
while [ "$(linode-cli linodes list --label doey-server --json | jq -r '.[0].status')" != "running" ]; do sleep 5; done

ssh -o StrictHostKeyChecking=accept-new root@$LINODE_IP echo "Connected"
```

## 2. Configure Server

Creates `doey` user, hardens SSH, enables firewall + swap, installs dependencies.

```bash
ssh root@$LINODE_IP 'bash -s' << 'SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq

useradd -m -s /bin/bash -G sudo doey
echo "doey ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/doey
mkdir -p /home/doey/.ssh
cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh
chmod 700 /home/doey/.ssh && chmod 600 /home/doey/.ssh/authorized_keys

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

ufw --force enable && ufw allow OpenSSH && ufw allow 60000:61000/udp

fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

apt-get install -y -qq tmux git curl unzip jq htop mosh locales
locale-gen en_US.UTF-8
SETUP
```

Verify: `ssh doey@$LINODE_IP echo "OK"` — root login is now disabled, use `doey@` from here.

## 3. Install Node.js, Claude Code, Doey

```bash
ssh doey@$LINODE_IP 'bash -s' << 'INSTALL'
set -euo pipefail
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env)"
fnm install --lts

npm install -g @anthropic-ai/claude-code

cd ~ && git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh
grep -q '\.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
doey doctor
INSTALL
```

## 4. Authentication

**API Key (recommended):**

```bash
ANTHROPIC_KEY="sk-ant-YOUR_KEY_HERE"
ssh doey@$LINODE_IP "echo 'export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\"' >> ~/.bashrc"
```

**OAuth (alternative):** `ssh -t doey@$LINODE_IP "source ~/.bashrc && claude auth"` — follow the URL prompt.

**Verify:** `ssh doey@$LINODE_IP 'source ~/.bashrc && claude -p "say hello" --max-turns 1'`

## 5. Launch

```bash
ssh doey@$LINODE_IP 'bash -s' << 'LAUNCH'
source ~/.bashrc
cd ~ && git clone https://github.com/YOUR_ORG/YOUR_PROJECT.git
cd YOUR_PROJECT && doey init && doey
LAUNCH
```

- **Reattach:** `ssh -t doey@$LINODE_IP "cd ~/YOUR_PROJECT && doey"`
- **Detach:** `Ctrl+B, D` — team keeps running

## 6. Persistent Sessions (systemd)

```bash
ssh doey@$LINODE_IP 'bash -s' << 'SYSTEMD'
set -euo pipefail
PROJECT="YOUR_PROJECT"   # Replace with your project directory name

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/doey.service << EOF
[Unit]
Description=Doey — Multi-agent Claude Code team
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=HOME=%h
Environment=PATH=%h/.local/bin:%h/.local/share/fnm/aliases/default/bin:/usr/local/bin:/usr/bin:/bin
# Environment=ANTHROPIC_API_KEY=sk-ant-YOUR_KEY   # if using API key
WorkingDirectory=%h/$PROJECT
ExecStart=/usr/bin/tmux new-session -d -s doey-$PROJECT %h/.local/bin/doey
ExecStop=/usr/bin/tmux kill-session -t doey-$PROJECT
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

chmod 600 ~/.config/systemd/user/doey.service
sudo loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user enable doey
systemctl --user start doey
SYSTEMD
```

<details>
<summary><strong>Full Automation Script (Steps 1–5)</strong></summary>

Usage: `ANTHROPIC_KEY="sk-ant-..." ./doey-linode-setup.sh`

```bash
#!/usr/bin/env bash
# Automates Steps 1–5: provision, configure, install, auth, print launch instructions.
set -euo pipefail
ANTHROPIC_KEY="${ANTHROPIC_KEY:?Set ANTHROPIC_KEY env var}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
LINODE_TYPE="${LINODE_TYPE:-g6-nanode-1}"
LINODE_REGION="${LINODE_REGION:-us-east}"
LINODE_LABEL="${LINODE_LABEL:-doey-server}"

# Step 1: Provision
ROOT_PASS="$(openssl rand -base64 24)"
linode-cli linodes create \
  --type "$LINODE_TYPE" --region "$LINODE_REGION" --image linode/ubuntu24.04 \
  --label "$LINODE_LABEL" --root_pass "$ROOT_PASS" \
  --authorized_keys "$(cat "$SSH_KEY")" --json > /dev/null
LINODE_IP=$(linode-cli linodes list --label "$LINODE_LABEL" --json | jq -r '.[0].ipv4[0]')
while [ "$(linode-cli linodes list --label "$LINODE_LABEL" --json | jq -r '.[0].status')" != "running" ]; do sleep 5; done
sleep 10

# Step 2: Configure server (user, SSH hardening, firewall, swap, deps)
ssh -o StrictHostKeyChecking=accept-new root@"$LINODE_IP" 'bash -s' << 'SERVER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
useradd -m -s /bin/bash -G sudo doey
echo "doey ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/doey
mkdir -p /home/doey/.ssh && cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh && chmod 700 /home/doey/.ssh && chmod 600 /home/doey/.ssh/authorized_keys
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
ufw --force enable && ufw allow OpenSSH && ufw allow 60000:61000/udp
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
apt-get install -y -qq tmux git curl unzip jq htop mosh locales && locale-gen en_US.UTF-8
SERVER

# Steps 3–4: Install Node.js, Claude Code, Doey, and set API key
ssh doey@"$LINODE_IP" 'bash -s' << TOOLS
set -euo pipefail
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="\$HOME/.local/share/fnm:\$PATH" && eval "\$(fnm env)" && fnm install --lts
npm install -g @anthropic-ai/claude-code
cd ~ && git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh
grep -q '\.local/bin' ~/.bashrc || echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
echo 'export ANTHROPIC_API_KEY="$ANTHROPIC_KEY"' >> ~/.bashrc
TOOLS

echo "Done! IP: $LINODE_IP"
echo "Launch: ssh -t doey@$LINODE_IP 'cd ~/your-project && doey'"
```

</details>

## Operations

```bash
ssh doey@$LINODE_IP "cd ~/doey && git pull && ./install.sh"                 # Update Doey
ssh doey@$LINODE_IP "source ~/.bashrc && npm update -g @anthropic-ai/claude-code"  # Update Claude
ssh doey@$LINODE_IP "source ~/.bashrc && doey purge"                        # Clean runtime
ssh doey@$LINODE_IP "free -h && df -h / && du -sh /tmp/doey/ 2>/dev/null"   # Check resources
```

## Security Notes

- API keys in `~/.bashrc` — for production, use a secrets manager or `chmod 600` env file
- Firewall allows only SSH (22) + mosh (60000–61000/udp); root login and password auth disabled
- Never commit API keys to git

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `linode-cli` not found | `pip install linode-cli && linode-cli configure` |
| SSH connection refused | Linode still booting — wait 30s, retry |
| Can't SSH as doey | Root setup may have failed — SSH as root (if still enabled) and check `/home/doey/.ssh/` |
| `node` not found | `source ~/.bashrc` (fnm needs shell init) |
| `doey` not found | `export PATH="$HOME/.local/bin:$PATH"` |
| Claude auth fails | Check `echo $ANTHROPIC_API_KEY` or re-run `claude auth` |
| Workers "Not logged in" | Run `claude --version` to verify auth works |
| tmux session not found | `doey list` to check registered projects, `doey init` if needed |
| Out of memory | Verify swap: `free -h`. Consider upgrading to 2 GB plan |
| Disk full | `doey purge` + `du -sh /tmp/doey/ ~/` |
| SSH disconnects | Use mosh: `mosh doey@$LINODE_IP` |
| systemd service fails | `journalctl --user -u doey -f` |
| Locale/UTF-8 errors | `sudo locale-gen en_US.UTF-8` |

## Golden Image

<details>
<summary><strong>Create, spawn, and tear down golden images</strong></summary>

**Create:**
```bash
# Clean for snapshotting
ssh doey@$LINODE_IP 'bash -s' << 'CLEAN'
sed -i '/ANTHROPIC_API_KEY/d' ~/.bashrc
ls ~/ | grep -v doey | while read dir; do [ -d "$HOME/$dir/.git" ] && rm -rf "$HOME/$dir"; done
rm -rf /tmp/doey/* ~/.claude/.credentials 2>/dev/null || true
> ~/.claude/doey/projects && > ~/.bash_history
CLEAN

ID=$(linode-cli linodes list --label doey-server --json | jq -r '.[0].id')
linode-cli linodes shutdown "$ID"
while [ "$(linode-cli linodes list --label doey-server --json | jq -r '.[0].status')" != "offline" ]; do sleep 3; done
linode-cli images create \
  --disk_id "$(linode-cli linodes disks-list "$ID" --json | jq -r '.[0].id')" \
  --label "doey-golden" --description "Ubuntu 24.04 + Node.js + Claude Code + Doey" --json
linode-cli linodes boot "$ID"
```

**Spawn from image:**
```bash
IMAGE_ID="private/12345678"   # from: linode-cli images list --is_public false
linode-cli linodes create \
  --type g6-nanode-1 --region us-east --image "$IMAGE_ID" \
  --label "doey-team-2" --root_pass "$(openssl rand -base64 24)" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)" --json
```

**Tear down fleet:**
```bash
linode-cli linodes list --json | jq -r '.[] | select(.label | startswith("doey-fleet")) | .id' \
  | while read id; do linode-cli linodes delete "$id"; done
```

</details>
