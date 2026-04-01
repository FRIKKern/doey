# Hetzner Cloud Setup Guide

> Deploy Doey on Hetzner Cloud — 16 GB for ~€9/mo. Start a task, detach, come back later.

## Prerequisites

```bash
# SSH key
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# Hetzner CLI
brew install hcloud                    # macOS
# Linux: curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin

# API token: console.hetzner.cloud > Security > API Tokens > Generate (Read & Write)
export HCLOUD_TOKEN="your-token-here"
```

**Claude auth:** Anthropic API key (`sk-ant-...`) or Claude Max (OAuth — requires `ssh -t`).

## Sizing Guide

Each agent uses 200–400 MB RAM:

| Plan | RAM | vCPUs | Max agents | Price |
|------|-----|-------|------------|-------|
| `cx23` | 4 GB | 2 | ~5 | ~€4/mo |
| `cx33` | 8 GB | 4 | ~10 | ~€7/mo |
| `cx43` | 16 GB | 8 | ~20 | ~€9/mo |
| `cx53` | 32 GB | 16 | ~40+ | ~€18/mo |

> Plans with 1–2 GB RAM **will crash** when launching even a basic Doey team. Use `cx23` minimum.

## 1. Provision

```bash
# Upload SSH key (one-time)
hcloud ssh-key create --name doey-key --public-key-from-file ~/.ssh/id_ed25519.pub

# Create server — Helsinki is closest to Scandinavia, adjust as needed
hcloud server create \
  --name doey-server \
  --type cx43 \
  --image ubuntu-24.04 \
  --location hel1 \
  --ssh-key doey-key

HETZNER_IP=$(hcloud server ip doey-server)
echo "Server IP: $HETZNER_IP"

# Wait for SSH to be ready (~10s, Hetzner boots fast)
sleep 10
ssh -o StrictHostKeyChecking=accept-new root@$HETZNER_IP echo "Connected"
```

## 2. Configure Server

Creates `doey` user, hardens SSH, enables firewall + swap. Hetzner Ubuntu uses `ssh.service` (not `sshd.service`).

```bash
ssh root@$HETZNER_IP 'bash -s' << 'SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq

# Create doey user with passwordless sudo
useradd -m -s /bin/bash -G sudo doey
echo "doey ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/doey
mkdir -p /home/doey/.ssh
cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh
chmod 700 /home/doey/.ssh && chmod 600 /home/doey/.ssh/authorized_keys

# Harden SSH
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh.service   # Note: ssh.service, not sshd.service on Hetzner

# Firewall: SSH + mosh only
ufw --force enable && ufw allow OpenSSH && ufw allow 60000:61000/udp

# Swap — 4G swapfile for burst headroom on 16GB plans
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Dependencies — unzip is required by fnm (Node.js version manager)
apt-get install -y -qq tmux git curl unzip jq htop mosh locales
locale-gen en_US.UTF-8
SETUP
```

Verify: `ssh doey@$HETZNER_IP echo "OK"` — root login is now disabled, use `doey@` from here.

## 3. Install Node.js, Claude Code, Doey

```bash
ssh doey@$HETZNER_IP 'bash -s' << 'INSTALL'
set -euo pipefail

# Node.js via fnm (requires unzip, installed in step 2)
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env)"
fnm install --lts

# Claude Code
npm install -g @anthropic-ai/claude-code

# Doey
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
ssh doey@$HETZNER_IP "echo 'export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\"' >> ~/.bashrc"
```

**OAuth / Claude Max:** `ssh -t doey@$HETZNER_IP "source ~/.bashrc && claude auth"` — follow the URL prompt.

**Verify:**

```bash
ssh doey@$HETZNER_IP 'source ~/.bashrc && claude -p "say hello" --max-turns 1'
```

## 5. Launch

```bash
ssh doey@$HETZNER_IP 'bash -s' << 'LAUNCH'
source ~/.bashrc
cd ~ && git clone https://github.com/YOUR_ORG/YOUR_PROJECT.git
cd YOUR_PROJECT && doey init && doey
LAUNCH
```

- **Reattach:** `ssh -t doey@$HETZNER_IP "cd ~/YOUR_PROJECT && doey"`
- **Detach:** `Ctrl+B, D` — team keeps running

## 6. Persistent Sessions (systemd)

```bash
ssh doey@$HETZNER_IP 'bash -s' << 'SYSTEMD'
set -euo pipefail
PROJECT="YOUR_PROJECT"

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

## Resizing

```bash
# Scale up (server must be off)
hcloud server shutdown doey-server
hcloud server change-type doey-server --server-type cx53 && hcloud server poweron doey-server

# Scale down (--keep-disk: can't shrink below current disk usage)
hcloud server shutdown doey-server
hcloud server change-type doey-server --server-type cx33 --keep-disk && hcloud server poweron doey-server
```

Hetzner resizes are near-instant (no migration wait).

<details>
<summary><strong>Full Automation Script (Steps 1–5)</strong></summary>

Usage: `ANTHROPIC_KEY="sk-ant-..." HCLOUD_TOKEN="your-token" ./doey-hetzner-setup.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ANTHROPIC_KEY="${ANTHROPIC_KEY:?Set ANTHROPIC_KEY env var}"
HCLOUD_TOKEN="${HCLOUD_TOKEN:?Set HCLOUD_TOKEN env var}"
export HCLOUD_TOKEN
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
SERVER_TYPE="${SERVER_TYPE:-cx43}"
LOCATION="${LOCATION:-hel1}"
SERVER_NAME="${SERVER_NAME:-doey-server}"

# Upload SSH key (ignore if exists)
hcloud ssh-key create --name doey-key --public-key-from-file "$SSH_KEY" 2>/dev/null || true

# Step 1: Provision
hcloud server create --name "$SERVER_NAME" --type "$SERVER_TYPE" --image ubuntu-24.04 --location "$LOCATION" --ssh-key doey-key
HETZNER_IP=$(hcloud server ip "$SERVER_NAME")
echo "Server IP: $HETZNER_IP"
sleep 10

# Step 2: Configure
ssh -o StrictHostKeyChecking=accept-new root@"$HETZNER_IP" 'bash -s' << 'SERVER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
useradd -m -s /bin/bash -G sudo doey
echo "doey ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/doey
mkdir -p /home/doey/.ssh && cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh && chmod 700 /home/doey/.ssh && chmod 600 /home/doey/.ssh/authorized_keys
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh.service
ufw --force enable && ufw allow OpenSSH && ufw allow 60000:61000/udp
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
apt-get install -y -qq tmux git curl unzip jq htop mosh locales && locale-gen en_US.UTF-8
SERVER

# Steps 3–4: Install and auth
ssh doey@"$HETZNER_IP" 'bash -s' << TOOLS
set -euo pipefail
curl -fsSL https://fnm.vercel.app/install | bash
export PATH="\$HOME/.local/share/fnm:\$PATH" && eval "\$(fnm env)" && fnm install --lts
npm install -g @anthropic-ai/claude-code
cd ~ && git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh
grep -q '\.local/bin' ~/.bashrc || echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
echo 'export ANTHROPIC_API_KEY="$ANTHROPIC_KEY"' >> ~/.bashrc
TOOLS

echo ""
echo "========================================="
echo "  Doey server ready!"
echo "  IP: $HETZNER_IP"
echo "  Location: $LOCATION"
echo "  Plan: $SERVER_TYPE"
echo "  SSH: ssh doey@$HETZNER_IP"
echo "  Launch: ssh -t doey@$HETZNER_IP 'cd ~/your-project && doey'"
echo "========================================="
```

</details>

## Operations

```bash
ssh doey@$HETZNER_IP "cd ~/doey && git pull && ./install.sh"                        # Update Doey
ssh doey@$HETZNER_IP "source ~/.bashrc && npm update -g @anthropic-ai/claude-code"  # Update Claude Code
ssh doey@$HETZNER_IP "source ~/.bashrc && doey purge"                               # Clean runtime data
ssh doey@$HETZNER_IP "free -h && df -h / && du -sh /tmp/doey/ 2>/dev/null"          # Check resources
```

## Security Notes

- API keys in `~/.bashrc` — for production, use a secrets manager or `chmod 600` env file. Never commit keys to git
- Firewall: SSH (22) + mosh (60000–61000/udp) only; root login and password auth disabled. Hetzner's default firewall is permissive — `ufw` rules above handle it
- Rotate any API tokens shared in chat logs or terminals

## Troubleshooting

| Issue | Fix |
|-------|-----|
| SSH connection refused | Wait ~10s and retry (Hetzner boots fast) |
| SSH hangs / times out | Likely OOM — `hcloud server reboot doey-server` or resize |
| `sshd.service` not found | Hetzner uses `ssh.service` — `systemctl restart ssh.service` |
| `node` not found | `source ~/.bashrc` (fnm needs shell init) |
| `doey` not found | `export PATH="$HOME/.local/bin:$PATH"` |
| fnm install fails | Missing `unzip` — `sudo apt-get install -y unzip` |
| Claude auth fails | Check `echo $ANTHROPIC_API_KEY` or re-run `claude auth` with `ssh -t` |
| Skills missing | `cd ~/doey && ./install.sh` |
| Out of memory | Shutdown → resize to cx53 → poweron (see [Resizing](#resizing)) |
| Disk full | `doey purge` + `du -sh /tmp/doey/ ~/` |
| SSH disconnects | `mosh doey@$HETZNER_IP` |
| systemd service fails | `journalctl --user -u doey -f` |

## Snapshots

Cheaper than golden images:

```bash
# Create snapshot (~€0.01/GB/mo)
hcloud server shutdown doey-server
hcloud server create-image doey-server --type snapshot --description "doey-golden"
hcloud server poweron doey-server

# Spawn from snapshot
hcloud server create --name doey-team-2 --type cx43 --image <snapshot-id> --location hel1 --ssh-key doey-key

# Tear down
hcloud server delete doey-team-2
```

## Headless Chrome + DevTools MCP

Headless Chrome lets Claude inspect and debug web apps via DevTools MCP — no local browser needed.

**Install:**

```bash
sudo apt-get install -y fonts-liberation libgbm-dev libnss3 libatk-bridge2.0-0 libxkbcommon0
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
sudo dpkg -i /tmp/chrome.deb || sudo apt-get install -f -y
rm /tmp/chrome.deb
```

**Launch:**

```bash
google-chrome --headless --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 \
  --window-size=1920,1080 &
# Optionally append a URL (e.g. http://localhost:3000) to open it directly
```

**Configure MCP** (add to `.claude/settings.json` or project settings):

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["@anthropic-ai/chrome-devtools-mcp@latest", "--cdp-url=http://localhost:9222"]
    }
  }
}
```

**Verify:** `curl -s http://localhost:9222/json/version | jq .`

**Background service (optional):**

```bash
cat > ~/.config/systemd/user/chrome-headless.service << 'EOF'
[Unit]
Description=Headless Chrome for DevTools MCP
After=network.target

[Service]
ExecStart=/usr/bin/google-chrome --headless --no-sandbox --disable-gpu --remote-debugging-port=9222 --window-size=1920,1080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now chrome-headless
```

Port 9222 is localhost-only — not exposed to the internet.

## SSH Tunneling

Add to `~/.ssh/config` (Windows: `C:\Users\YOU\.ssh\config`):

```
Host doey
    HostName YOUR_HETZNER_IP
    User doey
    LocalForward 3000 localhost:3000
    LocalForward 8080 localhost:8080
    LocalForward 9222 localhost:9222
```

`ssh doey` auto-forwards ports. DevTools on `:9222` → `chrome://inspect` > Configure > `localhost:9222`.

**File transfer:** `scp local-file.txt doey:~/` · `scp doey:~/output.png ./` · `rsync -avz ./src/ doey:~/project/src/`

**Survive disconnects:** `mosh doey` or `Ctrl+B, D` (tmux detach).
