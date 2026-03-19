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

Other distros: replace the first line with your package manager (`yum install -y` / `pacman -S`).

### SSH Usage

```bash
ssh user@your-server
cd ~/your-project && doey   # starts or reattaches
# Ctrl+B, D to detach — team keeps running
```

For persistent sessions via systemd, see the [Linode guide](linode-setup.md#6-persistent-sessions-systemd) -- the unit file works on any Linux server.

### Cloud Providers

Any Linux VPS with tmux and Node.js works. Never commit API keys -- use env vars or `claude auth`.

| Provider | Instance | Notes |
|----------|----------|-------|
| **Hetzner** | CX22 (~€3.29/mo) | EU/US, no egress fees |
| **DigitalOcean** | Basic Droplet ($6/mo) | Simple UI |
| **AWS** | t3.micro (free tier) | 12 months free |
| **Linode** | Nanode ($5/mo) | [Full guide](linode-setup.md) |

### Troubleshooting

| Issue | Fix |
|-------|-----|
| tmux too old (< 2.4) | Install from source or backports |
| `node` not found | `source ~/.bashrc` (fnm PATH) |
| Locale/UTF-8 errors | `sudo locale-gen en_US.UTF-8` |
| `doey` not found | `export PATH="$HOME/.local/bin:$PATH"` |
| Workers fail to start | Verify `claude --version` works |
