# Hetzner Cloud Setup Guide

> Deploy Doey on Hetzner Cloud — 16 GB for ~€9/mo. Start a task, detach, come back to find work done.

## Why Hetzner?

Hetzner's shared `cx` plans offer the best price/performance for Doey workloads. A 16 GB server costs ~€9/mo vs ~$96/mo on Linode or DigitalOcean — roughly 10x cheaper for the same specs.

| Provider | 16 GB plan | Price |
|----------|------------|-------|
| **Hetzner** (cx43) | 16 GB, 8 vCPU | **~€9/mo** |
| Linode (g6-standard-6) | 16 GB, 6 vCPU | $96/mo |
| DigitalOcean | 16 GB, 8 vCPU | $96/mo |

> **Note:** The shared `cx` plans are only available in EU datacenters (Helsinki, Nuremberg, Falkenstein). US locations (Ashburn, Hillsboro) only offer `cpx` shared plans (~€30/mo for 16 GB). Since Doey is SSH-based and sessions are detached, EU latency is a non-issue.

## Prerequisites

**SSH key:**

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

**Hetzner CLI (`hcloud`):**

```bash
# macOS
brew install hcloud

# Linux
curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin

# Windows (Git Bash)
curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-windows-amd64.zip -o /tmp/hcloud.zip
unzip /tmp/hcloud.zip -d /tmp/hcloud
cp /tmp/hcloud/hcloud.exe ~/.local/bin/
```

**Hetzner API token:**

1. Go to [console.hetzner.cloud](https://console.hetzner.cloud)
2. Create or select a project
3. **Security** > **API Tokens** > **Generate API Token**
4. Permissions: **Read & Write**
5. Copy the token (shown only once)

```bash
export HCLOUD_TOKEN="your-token-here"
```

**Claude auth** — one of:

- **Anthropic API key** (`sk-ant-...`)
- **Claude Max** (OAuth — requires interactive SSH)

## Sizing Guide

Each Claude Code agent uses 200–400 MB RAM. Choose your plan based on team size:

| Plan | RAM | vCPUs | Max agents | Price |
|------|-----|-------|------------|-------|
| `cx23` | 4 GB | 2 | ~5 | ~€4/mo |
| `cx33` | 8 GB | 4 | ~10 | ~€7/mo |
| `cx43` | 16 GB | 8 | ~20 | ~€9/mo |
| `cx53` | 32 GB | 16 | ~40+ | ~€18/mo |

> A Nanode/small plan (1–2 GB) **will crash** when launching even a basic Doey team. Don't try it.

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

Creates `doey` user, hardens SSH, enables firewall + swap, installs dependencies.

> **Important:** Hetzner Ubuntu uses `ssh.service` (not `sshd.service`). The script below handles this correctly.

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

**API Key (recommended for headless):**

```bash
ANTHROPIC_KEY="sk-ant-YOUR_KEY_HERE"
ssh doey@$HETZNER_IP "echo 'export ANTHROPIC_API_KEY=\"$ANTHROPIC_KEY\"' >> ~/.bashrc"
```

**OAuth / Claude Max (requires interactive terminal):**

```bash
ssh -t doey@$HETZNER_IP "source ~/.bashrc && claude auth"
```

Follow the URL prompt in your browser to complete login.

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
- **Quick connect** — save on your desktop as `doey-server.bat` (Windows) or `doey-server.sh` (Mac/Linux):

```bat
@echo off
title Doey Server
ssh -t doey@YOUR_HETZNER_IP
```

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

Hetzner makes resizing easy. You can scale up or down:

```bash
# Scale up (server must be off)
hcloud server shutdown doey-server
hcloud server change-type doey-server --server-type cx53   # 32 GB
hcloud server poweron doey-server

# Scale down (only if disk fits — can't shrink below current disk usage)
hcloud server shutdown doey-server
hcloud server change-type doey-server --server-type cx33 --keep-disk  # keep disk size, change RAM/CPU only
hcloud server poweron doey-server
```

> Unlike Linode, Hetzner resizes are near-instant (no migration wait).

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

- API keys in `~/.bashrc` — for production, use a secrets manager or `chmod 600` env file sourced separately
- Firewall allows only SSH (22) + mosh (60000–61000/udp); root login and password auth disabled
- Never commit API keys to git
- Rotate any API tokens you may have shared in chat logs or terminals
- Hetzner's default firewall is permissive — the `ufw` rules above handle this at the OS level

## Troubleshooting

| Issue | Fix |
|-------|-----|
| **SSH connection refused** | Server still booting — Hetzner boots in ~10s, wait and retry |
| **SSH hangs / times out** | Server likely OOM — reboot via `hcloud server reboot doey-server`, consider resizing |
| **`sshd.service` not found** | Hetzner Ubuntu uses `ssh.service` — use `systemctl restart ssh.service` |
| **`node` not found** | `source ~/.bashrc` (fnm needs shell init) |
| **`doey` not found** | `export PATH="$HOME/.local/bin:$PATH"` |
| **fnm install fails** | Missing `unzip` — run `sudo apt-get install -y unzip` then retry |
| **Claude auth fails** | Check `echo $ANTHROPIC_API_KEY` or re-run `claude auth` with `ssh -t` |
| **Skills missing after crash** | Re-run `cd ~/doey && ./install.sh` to reinstall |
| **Out of memory** | `hcloud server shutdown doey-server && hcloud server change-type doey-server --server-type cx53 && hcloud server poweron doey-server` |
| **Disk full** | `doey purge` + `du -sh /tmp/doey/ ~/` |
| **SSH disconnects** | Use mosh: `mosh doey@$HETZNER_IP` |
| **systemd service fails** | `journalctl --user -u doey -f` |

## Snapshots

Hetzner snapshots are cheaper than running golden images:

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

Run a headless browser on the server so Claude can inspect, screenshot, and debug your web apps via Chrome DevTools MCP — no local browser needed.

**Install Chrome and dependencies:**

```bash
# System libraries for Chrome's rendering engine
sudo apt-get install -y fonts-liberation libgbm-dev libnss3 libatk-bridge2.0-0 libxkbcommon0

# Chrome (stable)
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
sudo dpkg -i /tmp/chrome.deb || sudo apt-get install -f -y
rm /tmp/chrome.deb
```

**Launch headless Chrome with remote debugging:**

```bash
# Basic — opens about:blank, ready for navigation
google-chrome --headless --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 \
  --window-size=1920,1080 &

# Or point it at your dev server
google-chrome --headless --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 \
  --window-size=1920,1080 \
  http://localhost:3000 &
```

**What this gives Claude (via DevTools MCP):**

| Capability | Works headless? |
|------------|----------------|
| Screenshots (full page / element) | Yes |
| DOM inspection | Yes |
| CSS inspection / modification | Yes |
| Console logs / errors | Yes |
| Network requests / responses | Yes |
| Performance profiling | Yes |
| JavaScript execution | Yes |
| Mobile device emulation | Yes |
| Accessibility audits | Yes |

Screenshots are rendered pixel-perfect — headless Chrome uses the same rendering engine as desktop Chrome.

**Configure Chrome DevTools MCP:**

Add to your Claude Code MCP settings (`.claude/settings.json` or project settings):

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

**Verify it works:**

```bash
# Check Chrome is running and accepting connections
curl -s http://localhost:9222/json/version | jq .
```

**Run Chrome as a background service (optional):**

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

**Firewall note:** Port 9222 is only exposed on `localhost` — it's not accessible from the internet. This is intentional and secure. Claude connects via MCP on the same machine.

> **Why not Browserbase?** You could use Browserbase or similar cloud browser services, but running headless Chrome directly on the server is free, has zero latency (same machine), and gives you full control. Cloud browsers add value for captcha solving, session recording, or when you can't install Chrome — but on a Hetzner VPS you can.

## Working on a Headless Server

No GUI, no desktop, no browser window — just a terminal. One trick makes it feel like a local machine: **SSH tunneling**. It forwards remote ports to your local browser so OAuth flows, dev servers, and DevTools all just work.

### Set Up SSH Config (Do This Once)

Add to your SSH config so every connection automatically forwards the ports you need:

**Windows** (`C:\Users\YOU\.ssh\config`):

```
Host doey
    HostName YOUR_HETZNER_IP
    User doey
    LocalForward 3000 localhost:3000
    LocalForward 8080 localhost:8080
    LocalForward 9222 localhost:9222
```

**macOS / Linux** (`~/.ssh/config`):

```
Host doey
    HostName YOUR_HETZNER_IP
    User doey
    LocalForward 3000 localhost:3000
    LocalForward 8080 localhost:8080
    LocalForward 9222 localhost:9222
```

Now just `ssh doey` — ports are always forwarded. No flags to remember.

### What This Unlocks

Everything that "needs a browser" now works through `localhost` on your local machine:

| Task | On the server | In your local browser |
|------|--------------|----------------------|
| **View dev server** | `npx next dev -p 3000` | `http://localhost:3000` |
| **OAuth login** (GitHub, Claude) | `gh auth login` / `claude auth` | Complete the flow at `localhost` |
| **Chrome DevTools** | Headless Chrome on `:9222` | `chrome://inspect` > Configure > `localhost:9222` |
| **Any web UI** | Run it on any forwarded port | `http://localhost:<port>` |

No firewall changes needed — tunneled ports never touch the public internet.

### The Smooth Flow

**Tab 1** — SSH in, start Claude/Doey:

```powershell
ssh doey
cd ~/my-project && doey
```

**Tab 2** — SSH in (ports auto-forward), run your dev server:

```powershell
ssh doey
cd ~/my-project && npx next dev -p 3000
```

**Your local browser** — visit `http://localhost:3000` to see it live.

**Claude** — uses headless Chrome on `:9222` via DevTools MCP to inspect the same page, take screenshots, check the DOM. All on the same machine, zero latency.

```
[ Your PC ]                        [ Hetzner Server ]
  Browser ──tunnel:3000──────────▶ Next.js (:3000)
  chrome://inspect ──tunnel:9222─▶ Headless Chrome (:9222) ──▶ Next.js
  Terminal (Claude Code) ────SSH─▶ Claude ──DevTools MCP──▶ Headless Chrome
```

### Quick Reference

**Multiple terminals** — open new PowerShell/Terminal tabs and `ssh doey` again, or use tmux:

```bash
tmux new -s dev          # new session
Ctrl+B, %               # vertical split
Ctrl+B, "               # horizontal split
Ctrl+B, D               # detach (keeps running)
tmux attach -t dev       # reattach later
```

**Running web servers:**

```bash
npx next dev -p 3000                        # Next.js
npx vite --host 0.0.0.0 --port 3000         # Vite
python3 -m http.server 3000 --bind 0.0.0.0  # Static files
```

With SSH tunneling: visit `localhost:3000` locally. Without: visit `http://YOUR_HETZNER_IP:3000` (requires `sudo ufw allow 3000`).

**File transfer:**

```bash
scp local-file.txt doey:~/                           # upload
scp doey:~/output.png ./                             # download
rsync -avz ./my-project/ doey:~/my-project/          # sync directory
```

> With the SSH config above, `doey:` works as a shorthand everywhere — scp, rsync, VS Code Remote SSH.

**Survive disconnects:**

```bash
mosh doey                # roaming-proof SSH alternative (uses UDP)
```

Or just use tmux — detach with `Ctrl+B, D`, reattach with `tmux attach` next time you connect.

> **Production tip:** For sharing your site publicly, don't expose dev server ports. Use Nginx/Caddy as a reverse proxy, point a domain at your IP, and add HTTPS via Let's Encrypt.
