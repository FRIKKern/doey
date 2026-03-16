# Linux Server Deployment

> Part of [Doey](../README.md)

Running Doey on a Linux server is ideal — your team keeps working after you disconnect. Start a task, detach, close your laptop, come back to find the work done.

### Prerequisites

| Distro | Install essentials |
|--------|-------------------|
| **Ubuntu / Debian** | `sudo apt update && sudo apt install -y tmux git curl` |
| **Amazon Linux / RHEL** | `sudo yum install -y tmux git curl` |
| **Arch Linux** | `sudo pacman -S tmux git curl` |

**Node.js 18+** via [fnm](https://github.com/Schniz/fnm):

```bash
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc
fnm install --lts
```

**Claude Code CLI:** `npm install -g @anthropic-ai/claude-code` then `claude auth`

### Quick Setup (< 5 Minutes)

Copy-paste on a fresh Ubuntu/Debian server:

```bash
sudo apt update && sudo apt install -y tmux git curl
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc && fnm install --lts
npm install -g @anthropic-ai/claude-code && claude auth
git clone https://github.com/frikk-gyldendal/doey.git
cd doey && ./install.sh
cd ~/your-project && doey init && doey
```

### Headless / SSH Usage

```bash
ssh user@your-server
cd ~/your-project
doey                     # starts or reattaches
# Give Manager a task, then: Ctrl+B, D (detach)
exit                     # team keeps running
```

Reconnect: `ssh user@server && cd ~/your-project && doey`

<details>
<summary><strong>Background Service (systemd)</strong></summary>

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
ExecStart=/usr/bin/tmux new-session -d -s doey "%h/.local/bin/doey"
ExecStop=/usr/bin/tmux kill-session -t doey
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

Doey is network-bound (API calls), not CPU/RAM-intensive. Any Linux VPS with tmux and Node.js works.

<details>
<summary><strong>Hetzner (~€3.29/mo), DigitalOcean ($6/mo), AWS EC2 (free tier)</strong></summary>

All providers: create smallest Ubuntu 24.04 instance, SSH in, run the Quick Setup block above.

- **Hetzner:** CX22, EU/US datacenters, no egress fees
- **DigitalOcean:** Basic Droplet, simple UI
- **AWS:** t3.micro, free tier eligible (12 months)

</details>

**Security:** Never commit API keys. Use env vars or `claude auth`. Use SSH key auth.

### Platform Notes

- Notifications use `notify-send` on Linux (install `libnotify-bin` if missing). On macOS, `osascript` is used. All other functionality works identically.

### Troubleshooting

| Issue | Fix |
|-------|-----|
| tmux too old (< 2.4) | Install from source or backports |
| `node` not found | `source ~/.bashrc` or new shell (fnm PATH) |
| Locale/UTF-8 errors | `sudo apt install -y locales && sudo locale-gen en_US.UTF-8` |
| `doey` not found | `export PATH="$HOME/.local/bin:$PATH"` |
| Workers fail to start | Verify `claude --version` works standalone |
