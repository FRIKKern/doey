# Linode Setup Guide

> Part of [Doey](../README.md) — deploy your AI team on a Linode VPS

This guide is designed to be executed entirely via CLI — either by you or by Claude Code. Every step uses commands, no web UI required.

Run Doey on a Linode server so your team keeps working after you disconnect. Start a task, detach, close your laptop, come back to find the work done.

---

## Prerequisites

Before starting, ensure the following are available on the **local machine**:

```bash
# Check for SSH key (generate if missing)
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# Install Linode CLI
pip install linode-cli

# Configure Linode CLI (requires a Linode API token from cloud.linode.com/profile/tokens)
linode-cli configure

# Verify
linode-cli --version
```

You also need one of:
- **Anthropic API key** (`sk-ant-...`) — recommended for servers
- **Claude Max subscription** — uses OAuth, needs interactive auth on first run

---

## Step 1 — Provision the Linode

Doey is network-bound (API calls), not CPU/RAM-intensive. A Nanode ($5/mo) handles most workloads.

| Plan | Type ID | RAM | Monthly |
|------|---------|-----|---------|
| Nanode 1 GB | `g6-nanode-1` | 1 GB | $5 |
| Linode 2 GB | `g6-standard-1` | 2 GB | $12 |
| Linode 4 GB | `g6-standard-2` | 4 GB | $24 |

```bash
# Generate a root password
ROOT_PASS="$(openssl rand -base64 24)"
echo "Root password: $ROOT_PASS"   # Save this somewhere safe

# Create the Linode
linode-cli linodes create \
  --type g6-nanode-1 \
  --region us-east \
  --image linode/ubuntu24.04 \
  --label doey-server \
  --root_pass "$ROOT_PASS" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)" \
  --json

# Get the IP address
LINODE_IP=$(linode-cli linodes list --label doey-server --json | jq -r '.[0].ipv4[0]')
echo "Server IP: $LINODE_IP"
```

Wait for the Linode to boot (~60 seconds):

```bash
# Poll until running
while true; do
  STATUS=$(linode-cli linodes list --label doey-server --json | jq -r '.[0].status')
  echo "Status: $STATUS"
  [ "$STATUS" = "running" ] && break
  sleep 5
done
```

Verify SSH access:

```bash
ssh -o StrictHostKeyChecking=accept-new root@$LINODE_IP echo "Connected"
```

---

## Step 2 — Configure the Server

Everything from here runs on the remote server. You can either SSH in manually or have Claude Code run these via `ssh root@$LINODE_IP "command"`.

### One-shot server setup script

This single command handles: system updates, non-root user, SSH hardening, firewall, swap, and all dependencies.

```bash
ssh root@$LINODE_IP 'bash -s' << 'SETUP'
set -euo pipefail

echo "=== System updates ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq

echo "=== Create user: doey ==="
useradd -m -s /bin/bash -G sudo doey
echo "doey ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/doey
mkdir -p /home/doey/.ssh
cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh
chmod 700 /home/doey/.ssh
chmod 600 /home/doey/.ssh/authorized_keys

echo "=== Harden SSH ==="
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

echo "=== Firewall ==="
ufw --force enable
ufw allow OpenSSH

echo "=== Swap (2 GB) ==="
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo "=== Install packages ==="
apt-get install -y -qq tmux git curl jq htop mosh locales
locale-gen en_US.UTF-8

echo "=== Allow mosh through firewall ==="
ufw allow 60000:61000/udp

echo "=== Done ==="
free -h
ufw status
SETUP
```

Verify you can SSH as the new user:

```bash
ssh -o StrictHostKeyChecking=accept-new doey@$LINODE_IP echo "User login OK"
```

> **Note:** Root login is now disabled. Use `doey@$LINODE_IP` for all subsequent commands.

---

## Step 3 — Install Node.js, Claude Code, and Doey

Run as the `doey` user:

```bash
ssh doey@$LINODE_IP 'bash -s' << 'INSTALL'
set -euo pipefail

echo "=== Install fnm + Node.js ==="
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env)"
fnm install --lts
node --version
npm --version

echo "=== Install Claude Code ==="
npm install -g @anthropic-ai/claude-code
claude --version

echo "=== Clone and install Doey ==="
cd ~
git clone https://github.com/FRIKKern/doey.git
cd doey
./install.sh

echo "=== Add PATH entries to .bashrc ==="
grep -q '\.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

echo "=== Verify ==="
export PATH="$HOME/.local/bin:$PATH"
doey doctor

echo "=== Installation complete ==="
INSTALL
```

---

## Step 4 — Set Up Authentication

Claude Code needs an API key or OAuth token. For headless servers, an API key is simplest.

**Option A — API Key (recommended):**

```bash
# Replace with your actual key
ANTHROPIC_KEY="sk-ant-YOUR_KEY_HERE"

ssh doey@$LINODE_IP "grep -q ANTHROPIC_API_KEY ~/.bashrc || echo 'export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\"' >> ~/.bashrc"
```

**Option B — OAuth (interactive):**

```bash
ssh -t doey@$LINODE_IP "source ~/.bashrc && claude auth"
# This prints a URL — open it in your local browser, complete auth, paste code back
```

Verify authentication works:

```bash
ssh doey@$LINODE_IP 'source ~/.bashrc && claude -p "say hello" --max-turns 1'
```

---

## Step 5 — Launch Doey

### Initialize a project

```bash
# Clone your project on the server first
ssh doey@$LINODE_IP 'bash -s' << 'LAUNCH'
source ~/.bashrc

# Clone your project (replace with your repo)
cd ~
git clone https://github.com/YOUR_ORG/YOUR_PROJECT.git
cd YOUR_PROJECT

# Register with Doey
doey init

# Launch the team (detached — won't block your SSH session)
doey
LAUNCH
```

### Attach to the running session

```bash
ssh -t doey@$LINODE_IP "cd ~/YOUR_PROJECT && doey"
```

### Detach without stopping

Press `Ctrl+B`, then `D`. The team continues running.

### Reattach later

```bash
ssh -t doey@$LINODE_IP "cd ~/YOUR_PROJECT && doey"
```

---

## Step 6 — Persistent Sessions (systemd)

Auto-start Doey on boot and restart on failure:

```bash
ssh doey@$LINODE_IP 'bash -s' << 'SYSTEMD'
set -euo pipefail

# Replace YOUR_PROJECT with your actual project directory name
PROJECT_DIR="YOUR_PROJECT"
PROJECT_NAME="YOUR_PROJECT"

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
WorkingDirectory=%h/$PROJECT_DIR
ExecStart=/usr/bin/tmux new-session -d -s doey-$PROJECT_NAME %h/.local/bin/doey
ExecStop=/usr/bin/tmux kill-session -t doey-$PROJECT_NAME
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

# If using API key, add it to the service
# Add this line to [Service] section:
# Environment=ANTHROPIC_API_KEY=sk-ant-YOUR_KEY

chmod 600 ~/.config/systemd/user/doey.service
sudo loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user enable doey
systemctl --user start doey
systemctl --user status doey
SYSTEMD
```

---

<details>
<summary><strong>Step 7 — Full Automation Script</strong></summary>

Here's a single script that does everything from steps 1-5. Save it locally and run it, or have Claude Code execute it:

```bash
#!/usr/bin/env bash
# doey-linode-setup.sh — Fully automated Doey deployment on Linode
#
# Usage:
#   ANTHROPIC_KEY="sk-ant-..." ./doey-linode-setup.sh
#   ANTHROPIC_KEY="sk-ant-..." ./doey-linode-setup.sh --project git@github.com:org/repo.git
#
set -euo pipefail

ANTHROPIC_KEY="${ANTHROPIC_KEY:?Set ANTHROPIC_KEY env var}"
PROJECT_REPO="${1:---project}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
LINODE_TYPE="${LINODE_TYPE:-g6-nanode-1}"
LINODE_REGION="${LINODE_REGION:-us-east}"
LINODE_LABEL="${LINODE_LABEL:-doey-server}"

echo "=== Creating Linode ($LINODE_TYPE in $LINODE_REGION) ==="
ROOT_PASS="$(openssl rand -base64 24)"

linode-cli linodes create \
  --type "$LINODE_TYPE" \
  --region "$LINODE_REGION" \
  --image linode/ubuntu24.04 \
  --label "$LINODE_LABEL" \
  --root_pass "$ROOT_PASS" \
  --authorized_keys "$(cat "$SSH_KEY")" \
  --json > /dev/null

LINODE_IP=$(linode-cli linodes list --label "$LINODE_LABEL" --json | jq -r '.[0].ipv4[0]')
echo "IP: $LINODE_IP"

echo "=== Waiting for boot ==="
while [ "$(linode-cli linodes list --label "$LINODE_LABEL" --json | jq -r '.[0].status')" != "running" ]; do
  sleep 5
done
sleep 10  # Extra time for SSH to come up

echo "=== Configuring server ==="
ssh -o StrictHostKeyChecking=accept-new root@"$LINODE_IP" 'bash -s' << 'SERVER'
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
apt-get install -y -qq tmux git curl jq htop mosh locales
locale-gen en_US.UTF-8
SERVER

echo "=== Installing Node.js + Claude Code + Doey ==="
ssh doey@"$LINODE_IP" 'bash -s' << TOOLS
set -euo pipefail
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="\$HOME/.local/share/fnm:\$PATH"
eval "\$(fnm env)"
fnm install --lts
npm install -g @anthropic-ai/claude-code
cd ~ && git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh
grep -q '\.local/bin' ~/.bashrc || echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
echo 'export ANTHROPIC_API_KEY="$ANTHROPIC_KEY"' >> ~/.bashrc
TOOLS

echo ""
echo "=== Done! ==="
echo "Server: $LINODE_IP"
echo ""
echo "Connect:  ssh -t doey@$LINODE_IP"
echo "Launch:   ssh -t doey@$LINODE_IP 'cd ~/your-project && doey'"
echo "Mosh:     mosh doey@$LINODE_IP"
```

</details>

---

## Monitoring & Maintenance

All commands run via SSH — no need to be attached to the tmux session:

```bash
# Check if Doey session is running
ssh doey@$LINODE_IP "tmux list-sessions"

# Server resource usage
ssh doey@$LINODE_IP "free -h && df -h / && du -sh /tmp/doey/ 2>/dev/null"

# Update Doey
ssh doey@$LINODE_IP "cd ~/doey && git pull && ./install.sh"

# Update Claude Code
ssh doey@$LINODE_IP "source ~/.bashrc && npm update -g @anthropic-ai/claude-code"

# System updates
ssh doey@$LINODE_IP "sudo apt update && sudo apt upgrade -y"

# Clean runtime files
ssh doey@$LINODE_IP "source ~/.bashrc && doey purge"

# Restart workers (from inside session, via Manager)
# /doey-clear workers
```

---

## Managing the Linode

```bash
# List your Linodes
linode-cli linodes list

# Reboot
linode-cli linodes reboot $(linode-cli linodes list --label doey-server --json | jq -r '.[0].id')

# Resize (e.g., upgrade to 2 GB)
linode-cli linodes resize \
  $(linode-cli linodes list --label doey-server --json | jq -r '.[0].id') \
  --type g6-standard-1

# Delete (destroys the server — irreversible)
linode-cli linodes delete $(linode-cli linodes list --label doey-server --json | jq -r '.[0].id')

# Enable backups ($2/mo for Nanode)
linode-cli linodes backups-enable $(linode-cli linodes list --label doey-server --json | jq -r '.[0].id')
```

---

<details>
<summary><strong>Exposing Services & Web Access</strong></summary>

When Doey workers build web apps, APIs, or anything with a local server, you need a way to access `localhost:3000` (or whatever port) on the Linode from your browser. There are three approaches, from simplest to most production-ready.

### Option A — SSH Port Forwarding (Quick, No Setup)

Forward a remote port to your local machine through SSH. No firewall changes, no domain needed.

```bash
# Forward remote port 3000 to local port 3000
ssh -L 3000:localhost:3000 doey@$LINODE_IP

# Forward multiple ports at once
ssh -L 3000:localhost:3000 -L 5173:localhost:5173 -L 8080:localhost:8080 doey@$LINODE_IP

# Background tunnel (no shell, just forwarding)
ssh -fNL 3000:localhost:3000 doey@$LINODE_IP
```

Then open `http://localhost:3000` on your machine. The tunnel stays open as long as the SSH session is alive.

**Kill a background tunnel:**

```bash
# Find and kill the tunnel process
ps aux | grep "ssh -fNL" | grep -v grep
kill <PID>
```

**Persistent tunnel with autossh** (auto-reconnects):

```bash
# Install autossh locally
brew install autossh        # macOS
# apt install autossh       # Linux

# Auto-reconnecting tunnel
autossh -M 0 -fNL 3000:localhost:3000 doey@$LINODE_IP
```

> Best for: development, testing, quick access. No domain needed, no ports exposed to the internet.

### Option B — Caddy Reverse Proxy + Domain (Production)

Expose services on a real domain with automatic HTTPS. [Caddy](https://caddyserver.com/) handles TLS certificates automatically via Let's Encrypt.

**1. Point your domain to the Linode:**

```bash
# If using Linode DNS Manager
linode-cli domains create --domain yourdomain.com --type master --soa_email you@email.com
DOMAIN_ID=$(linode-cli domains list --json | jq -r '.[] | select(.domain=="yourdomain.com") | .id')

# A record pointing to your Linode
linode-cli domains records-create "$DOMAIN_ID" \
  --type A --name "" --target "$LINODE_IP"

# Wildcard for subdomains (*.yourdomain.com)
linode-cli domains records-create "$DOMAIN_ID" \
  --type A --name "*" --target "$LINODE_IP"
```

Or set the A record at your registrar (Namecheap, Cloudflare, etc.) pointing to `$LINODE_IP`.

**2. Install and configure Caddy on the server:**

```bash
ssh doey@$LINODE_IP 'bash -s' << 'CADDY'
set -euo pipefail

# Install Caddy
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

# Create Caddyfile
sudo tee /etc/caddy/Caddyfile << 'CADDYFILE'
# Main app — reverse proxy to localhost:3000
app.yourdomain.com {
    reverse_proxy localhost:3000
}

# API — reverse proxy to localhost:8080
api.yourdomain.com {
    reverse_proxy localhost:8080
}

# Dev server (Vite, Next.js, etc.)
dev.yourdomain.com {
    reverse_proxy localhost:5173
}

# Catch-all: show a status page or redirect
yourdomain.com {
    respond "Doey server running" 200
}
CADDYFILE

sudo systemctl enable caddy
sudo systemctl restart caddy
CADDY
```

**3. Open firewall ports:**

```bash
ssh doey@$LINODE_IP 'sudo ufw allow 80 && sudo ufw allow 443'
```

Now `https://app.yourdomain.com` routes to whatever is running on port 3000. Caddy auto-provisions and renews TLS certificates.

**Add/remove proxied services dynamically:**

```bash
# Add a new subdomain proxy on the fly
ssh doey@$LINODE_IP "sudo tee -a /etc/caddy/Caddyfile << 'EOF'

newservice.yourdomain.com {
    reverse_proxy localhost:4000
}
EOF
sudo systemctl reload caddy"
```

> Best for: sharing work with others, staging environments, webhook receivers, demo sites.

### Option C — Tailscale (Private Network, Zero Config)

[Tailscale](https://tailscale.com/) creates a private mesh VPN between your devices. No ports exposed to the public internet, no domain needed — access the Linode's services via a private IP.

```bash
# Install Tailscale on the server
ssh doey@$LINODE_IP 'bash -s' << 'TAILSCALE'
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
TAILSCALE
# Follow the auth URL printed to the terminal

# Install Tailscale on your local machine
brew install tailscale       # macOS
tailscale up
```

Once both devices are on Tailscale:

```bash
# Get the Linode's Tailscale IP
ssh doey@$LINODE_IP "tailscale ip -4"
# e.g., 100.x.y.z

# Access services directly — no tunnels, no port forwarding
open http://100.x.y.z:3000
open http://100.x.y.z:5173
```

**Bonus — Tailscale Funnel** (public access without a domain):

```bash
# Expose port 3000 to the public internet via Tailscale's infrastructure
ssh doey@$LINODE_IP "sudo tailscale funnel 3000"
# Gives you a URL like https://doey-server.tail1234.ts.net/
```

> Best for: secure private access, team sharing without exposing ports, accessing multiple services without SSH tunnels.

### Option D — Web Terminal (Access Doey from a Browser)

Run [ttyd](https://github.com/nicedingding/ttyd) to access the Doey tmux session directly from a web browser — no SSH client needed.

```bash
ssh doey@$LINODE_IP 'bash -s' << 'TTYD'
set -euo pipefail

# Install ttyd
sudo apt install -y ttyd

# Create a systemd service for ttyd
sudo tee /etc/systemd/system/ttyd.service << 'EOF'
[Unit]
Description=ttyd — Web terminal
After=network.target

[Service]
Type=simple
User=doey
# Password-protected, writable, attach to existing tmux or start new
ExecStart=/usr/bin/ttyd --port 7681 --credential doey:CHANGE_THIS_PASSWORD --writable tmux attach -t doey || tmux new -s doey
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ttyd
sudo systemctl start ttyd
TTYD
```

**Expose via Caddy (recommended — adds HTTPS):**

```bash
ssh doey@$LINODE_IP "sudo tee -a /etc/caddy/Caddyfile << 'EOF'

terminal.yourdomain.com {
    reverse_proxy localhost:7681
}
EOF
sudo systemctl reload caddy"
```

Or via SSH tunnel (no domain needed):

```bash
ssh -L 7681:localhost:7681 doey@$LINODE_IP
# Open http://localhost:7681 in your browser
```

> Best for: iPad/tablet access, sharing a live view of Doey with teammates, quick access without an SSH client.

### Comparison

| Approach | Setup time | Domain needed | Public access | Security | Best for |
|----------|-----------|--------------|---------------|----------|----------|
| SSH tunnel | 0 min | No | No | Excellent | Dev/testing |
| Caddy + domain | 10 min | Yes | Yes | Good (HTTPS) | Production, demos |
| Tailscale | 5 min | No | Optional (Funnel) | Excellent | Teams, multi-service |
| Web terminal | 5 min | Optional | Optional | Good (password) | Browser-based access |

These can be combined — e.g., Tailscale for private access + Caddy for public-facing endpoints + ttyd behind Caddy for browser-based terminal access.

</details>

---

## Security Notes

- **API keys** are stored in `~/.bashrc` on the server. For production, consider using a secrets manager or environment file with restricted permissions (`chmod 600`)
- **Firewall** only allows SSH (22) and mosh (60000-61000/udp) — nothing else is exposed
- **Root login** and **password auth** are disabled — SSH keys only
- **Never** commit API keys to git

---

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
| systemd service fails | `journalctl --user -u doey -f` for logs |
| Locale/UTF-8 errors | `sudo locale-gen en_US.UTF-8` |

---

<details>
<summary><strong>Rapid Cloning — Snapshot a Golden Image</strong></summary>

Once you have a fully configured Doey server (steps 1-4 complete, everything works), snapshot it as a **golden image**. Then spin up new Doey instances in minutes — no setup, just clone, add API key, launch.

### Create the Golden Image

First, clean the server so the snapshot is generic (no project-specific data, no API keys):

```bash
ssh doey@$LINODE_IP 'bash -s' << 'CLEAN'
set -euo pipefail

# Remove API key from bashrc (each clone gets its own)
sed -i '/ANTHROPIC_API_KEY/d' ~/.bashrc

# Remove any cloned projects (clones will get their own)
ls ~/ | grep -v doey | while read dir; do
  [ -d "$HOME/$dir/.git" ] && rm -rf "$HOME/$dir"
done

# Clear Doey runtime data
rm -rf /tmp/doey/*

# Clear doey project registry (each clone registers its own)
> ~/.claude/doey/projects

# Clear shell history
history -c
> ~/.bash_history

# Clear Claude Code auth (each clone authenticates separately)
rm -rf ~/.claude/.credentials 2>/dev/null || true
CLEAN
```

Then create the image via CLI:

```bash
LINODE_ID=$(linode-cli linodes list --label doey-server --json | jq -r '.[0].id')

# Power off first (required for consistent snapshots)
linode-cli linodes shutdown "$LINODE_ID"

# Wait for shutdown
while [ "$(linode-cli linodes list --label doey-server --json | jq -r '.[0].status')" != "offline" ]; do
  sleep 3
done

# Create the image
linode-cli images create \
  --disk_id "$(linode-cli linodes disks-list "$LINODE_ID" --json | jq -r '.[0].id')" \
  --label "doey-golden" \
  --description "Ubuntu 24.04 + Node.js + Claude Code + Doey — ready to clone" \
  --json

# Power back on
linode-cli linodes boot "$LINODE_ID"
```

> **Note:** Custom images are free up to 6 GB on Linode, then $0.10/GB/month.

### Spawn a New Doey Instance from the Image

```bash
# List your custom images to get the image ID
linode-cli images list --is_public false --json | jq '.[] | {id, label}'

# Clone a new instance (takes ~60 seconds)
IMAGE_ID="private/12345678"   # from the list above

linode-cli linodes create \
  --type g6-nanode-1 \
  --region us-east \
  --image "$IMAGE_ID" \
  --label "doey-team-2" \
  --root_pass "$(openssl rand -base64 24)" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)" \
  --json

NEW_IP=$(linode-cli linodes list --label doey-team-2 --json | jq -r '.[0].ipv4[0]')
echo "New instance: $NEW_IP"
```

Wait for boot, then configure the clone:

```bash
# Wait for boot
while [ "$(linode-cli linodes list --label doey-team-2 --json | jq -r '.[0].status')" != "running" ]; do
  sleep 5
done
sleep 10

# Set API key + clone project + launch
ssh -o StrictHostKeyChecking=accept-new doey@"$NEW_IP" 'bash -s' << CLONE
set -euo pipefail
source ~/.bashrc

# Set API key
echo 'export ANTHROPIC_API_KEY="sk-ant-YOUR_KEY"' >> ~/.bashrc
source ~/.bashrc

# Clone your project
cd ~
git clone https://github.com/YOUR_ORG/YOUR_PROJECT.git
cd YOUR_PROJECT
doey init
CLONE

# Attach
ssh -t doey@"$NEW_IP" "cd ~/YOUR_PROJECT && doey"
```

### Batch Spawn Script

Spin up N Doey instances in parallel:

```bash
#!/usr/bin/env bash
# spawn-doey-fleet.sh — Create multiple Doey instances from golden image
#
# Usage: ANTHROPIC_KEY="sk-ant-..." ./spawn-doey-fleet.sh 5 private/12345678
#
set -euo pipefail

COUNT="${1:?Usage: $0 <count> <image_id>}"
IMAGE_ID="${2:?Usage: $0 <count> <image_id>}"
ANTHROPIC_KEY="${ANTHROPIC_KEY:?Set ANTHROPIC_KEY env var}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
REGION="${LINODE_REGION:-us-east}"
TYPE="${LINODE_TYPE:-g6-nanode-1}"

echo "Spawning $COUNT Doey instances from $IMAGE_ID..."

for i in $(seq 1 "$COUNT"); do
  LABEL="doey-fleet-$i"
  echo "Creating $LABEL..."
  linode-cli linodes create \
    --type "$TYPE" \
    --region "$REGION" \
    --image "$IMAGE_ID" \
    --label "$LABEL" \
    --root_pass "$(openssl rand -base64 24)" \
    --authorized_keys "$(cat "$SSH_KEY")" \
    --json > /dev/null &
done

wait
echo "All instances created. Waiting for boot..."
sleep 30

# Configure each instance
for i in $(seq 1 "$COUNT"); do
  LABEL="doey-fleet-$i"
  IP=$(linode-cli linodes list --label "$LABEL" --json | jq -r '.[0].ipv4[0]')
  echo "Configuring $LABEL ($IP)..."

  ssh -o StrictHostKeyChecking=accept-new doey@"$IP" \
    "echo 'export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\"' >> ~/.bashrc" &
done

wait
echo ""
echo "=== Fleet ready ==="
linode-cli linodes list --json | jq -r '.[] | select(.label | startswith("doey-fleet")) | "\(.label)\t\(.ipv4[0])\t\(.status)"'
```

### StackScript (Alternative)

For fully automated provisioning without a golden image, create a Linode StackScript:

```bash
linode-cli stackscripts create \
  --label "doey-setup" \
  --images "linode/ubuntu24.04" \
  --is_public false \
  --script '#!/bin/bash
# <UDF name="anthropic_key" label="Anthropic API Key" />
# <UDF name="project_repo" label="Git repo URL (optional)" default="" />

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq && apt-get upgrade -y -qq
useradd -m -s /bin/bash -G sudo doey
echo "doey ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/doey
mkdir -p /home/doey/.ssh
cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh
chmod 700 /home/doey/.ssh && chmod 600 /home/doey/.ssh/authorized_keys
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart sshd
ufw --force enable && ufw allow OpenSSH && ufw allow 60000:61000/udp
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
apt-get install -y -qq tmux git curl jq htop mosh locales
locale-gen en_US.UTF-8

su - doey << DOEY_SETUP
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="\$HOME/.local/share/fnm:\$PATH"
eval "\$(fnm env)"
fnm install --lts
npm install -g @anthropic-ai/claude-code
cd ~ && git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh
grep -q ".local/bin" ~/.bashrc || echo "export PATH=\"\\\$HOME/.local/bin:\\\$PATH\"" >> ~/.bashrc
echo "export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\"" >> ~/.bashrc
DOEY_SETUP
' --json
```

Then launch with the StackScript:

```bash
STACKSCRIPT_ID=$(linode-cli stackscripts list --json | jq -r '.[] | select(.label=="doey-setup") | .id')

linode-cli linodes create \
  --type g6-nanode-1 \
  --region us-east \
  --image linode/ubuntu24.04 \
  --label doey-auto \
  --root_pass "$(openssl rand -base64 24)" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)" \
  --stackscript_id "$STACKSCRIPT_ID" \
  --stackscript_data '{"anthropic_key": "sk-ant-YOUR_KEY"}' \
  --json
```

The server provisions itself completely — SSH in after ~3 minutes and it's ready.

### Tear Down a Fleet

```bash
# Delete all fleet instances
linode-cli linodes list --json \
  | jq -r '.[] | select(.label | startswith("doey-fleet")) | .id' \
  | while read id; do
      echo "Deleting Linode $id..."
      linode-cli linodes delete "$id"
    done
```

</details>

---

## Quick Reference

```bash
# Local — provision & connect
LINODE_IP=$(linode-cli linodes list --label doey-server --json | jq -r '.[0].ipv4[0]')
ssh -t doey@$LINODE_IP                              # Connect
mosh doey@$LINODE_IP                                 # Connect (unstable networks)

# Remote — manage Doey
cd ~/your-project && doey                            # Start or reattach
doey add                                             # Scale up workers
doey stop                                            # Stop the team
doey doctor                                          # Health check
doey purge                                           # Clean runtime files

# Inside tmux session
Ctrl+B, D                                            # Detach (team keeps running)
Ctrl+B, arrow keys                                   # Navigate panes
```
