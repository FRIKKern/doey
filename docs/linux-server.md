# Linux Server Deployment

> Start a task, detach, close your laptop, come back to find work done.

### Prerequisites

| Distro | Install essentials |
|--------|-------------------|
| **Ubuntu / Debian** | `sudo apt update && sudo apt install -y tmux git curl` |
| **Amazon Linux / RHEL** | `sudo yum install -y tmux git curl` |
| **Arch Linux** | `sudo pacman -S tmux git curl` |

**Node.js 18+** via [fnm](https://github.com/Schniz/fnm):

```bash
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc && fnm install --lts
```

**Claude Code:** `npm install -g @anthropic-ai/claude-code && claude auth`

### Quick Setup (Ubuntu/Debian)

```bash
sudo apt update && sudo apt install -y tmux git curl
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc && fnm install --lts
npm install -g @anthropic-ai/claude-code && claude auth
git clone https://github.com/FRIKKern/doey.git
cd doey && ./install.sh
cd ~/your-project && doey init && doey
```

### SSH Usage

```bash
ssh user@your-server
cd ~/your-project
doey                     # starts or reattaches
# Ctrl+B, D to detach — team keeps running
```

Reconnect: `ssh user@server && cd ~/your-project && doey`

<details>
<summary><strong>systemd Service</strong></summary>

Create `~/.config/systemd/user/doey.service`:

```ini
[Unit]
Description=Doey
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=HOME=%h
Environment=PATH=%h/.local/bin:%h/.fnm/aliases/default/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=%h/your-project
ExecStart=%h/.local/bin/doey
ExecStop=/usr/bin/tmux kill-session -t doey-myproject
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

```bash
sudo loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user enable doey && systemctl --user start doey
```

</details>

### Cloud Providers

Doey is network-bound — any Linux VPS with tmux and Node.js works.

| Provider | Instance | Notes |
|----------|----------|-------|
| **Hetzner** | CX22 (~€3.29/mo) | EU/US, no egress fees |
| **DigitalOcean** | Basic Droplet ($6/mo) | Simple UI |
| **AWS** | t3.micro (free tier) | 12 months free |

For Linode, see [linode-setup.md](linode-setup.md). Never commit API keys — use env vars or `claude auth`.

### Notes

- macOS notifications (`osascript`) silently skipped on Linux

### Troubleshooting

| Issue | Fix |
|-------|-----|
| tmux too old (< 2.4) | Install from source or backports |
| `node` not found | `source ~/.bashrc` (fnm PATH) |
| Locale/UTF-8 errors | `sudo apt install -y locales && sudo locale-gen en_US.UTF-8` |
| `doey` not found | `export PATH="$HOME/.local/bin:$PATH"` |
| Workers fail to start | Verify `claude --version` works |
