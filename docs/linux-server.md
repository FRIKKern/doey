# Linux Server Deployment

> Start a task, detach, close your laptop, come back to find work done.

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

**Other distros:** Replace the first line with your package manager (`yum install -y` / `pacman -S`).

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

Create `~/.config/systemd/user/doey.service`. Replace `your-project` with your project directory name in **both** `WorkingDirectory` and `ExecStop` — Doey derives the tmux session name from the project directory basename, so `~/your-project` always becomes session `doey-your-project`.

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
ExecStop=/usr/bin/tmux kill-session -t doey-your-project
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

Any Linux VPS with tmux and Node.js works. Never commit API keys.

| Provider | Instance | Notes |
|----------|----------|-------|
| **Hetzner** | CX22 (~€3.29/mo) | EU/US, no egress fees |
| **DigitalOcean** | Basic Droplet ($6/mo) | Simple UI |
| **AWS** | t3.micro (free tier) | 12 months free |

Guides: [Hetzner](hetzner-setup.md) · [Linode](linode-setup.md).

### Troubleshooting

| Issue | Fix |
|-------|-----|
| tmux too old (< 2.4) | Install from source or backports |
| `node` not found | `source ~/.bashrc` (fnm PATH) |
| Locale/UTF-8 errors | `sudo locale-gen en_US.UTF-8` |
| `doey` not found | `export PATH="$HOME/.local/bin:$PATH"` |
| Workers fail | `claude --version` to verify auth |
| macOS notifications | `osascript` silently skipped on Linux |
