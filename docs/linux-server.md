# Linux Server Deployment

> Part of [Claude Code TMUX Team](../README.md)

Running Claude Code TMUX Team on a Linux server is one of the best use cases — your team of agents keeps working even after you disconnect from SSH. Start a task, detach, close your laptop, and come back later to find the work done.

### Prerequisites

| Distro | Install essentials |
|--------|-------------------|
| **Ubuntu / Debian** | `sudo apt update && sudo apt install -y tmux git curl` |
| **Amazon Linux / RHEL** | `sudo yum install -y tmux git curl` |
| **Arch Linux** | `sudo pacman -S tmux git curl` |

**Node.js 18+** — install via [fnm](https://github.com/Schniz/fnm) (recommended):

```bash
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc        # or restart your shell
fnm install --lts
```

**Claude Code CLI:**

```bash
npm install -g @anthropic-ai/claude-code
```

**Authenticate:**

```bash
claude auth
```

### Quick Setup (< 5 Minutes)

Copy-paste this entire block on a fresh Ubuntu/Debian server to go from zero to a running team:

```bash
# 1. Install system dependencies
sudo apt update && sudo apt install -y tmux git curl

# 2. Install Node.js via fnm
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc
fnm install --lts

# 3. Install Claude Code CLI and authenticate
npm install -g @anthropic-ai/claude-code
claude auth

# 4. Install claude-code-tmux-team
git clone https://github.com/frikk-gyldendal/claude-code-tmux-team.git
cd claude-code-tmux-team && ./install.sh

# 5. Init your project and launch
cd ~/your-project
ct init
ct
```

### Headless / SSH Usage

The core workflow is simple — SSH in, launch (or reattach), work, detach, disconnect:

```bash
# From your local machine
ssh user@your-server

# On the server — start or reattach
cd ~/your-project
ct

# Give the Manager a task, then detach when ready
# Ctrl+B, D  →  detaches from tmux (team keeps running)

# Disconnect SSH — the team continues working
exit
```

Reconnect anytime — `ct` auto-reattaches to the running session:

```bash
ssh user@your-server
cd ~/your-project
ct                       # picks up right where you left off
```

<details>
<summary><strong>Running as a Background Service (Advanced)</strong></summary>

You can configure a systemd user service to auto-start a claude-team session on boot.

Create `~/.config/systemd/user/claude-team.service`:

```ini
[Unit]
Description=Claude Code TMUX Team
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=HOME=%h
Environment=PATH=%h/.local/bin:%h/.fnm/aliases/default/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=%h/your-project
ExecStart=/usr/bin/tmux new-session -d -s claude-team "%h/.local/bin/claude-team"
ExecStop=/usr/bin/tmux kill-session -t claude-team
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

Enable and start:

```bash
# Enable lingering so user services run without an active login
sudo loginctl enable-linger $USER

systemctl --user daemon-reload
systemctl --user enable claude-team
systemctl --user start claude-team

# Check status
systemctl --user status claude-team
```

> This is optional. Most users will prefer the manual SSH + detach workflow above.

</details>

### Cloud Providers

Claude Team is network-bound (API calls to Anthropic), not CPU/RAM-intensive — even the smallest instances work. Any Linux VPS with tmux and Node.js is enough.

<details>
<summary><strong>Hetzner Cloud (~€3.29/mo)</strong></summary>

1. Create a **CX22** server with **Ubuntu 24.04** (Falkenstein, Nuremberg, Helsinki, or Ashburn)
2. SSH into the server
3. Run the Quick Setup block from above

```bash
ssh root@your-hetzner-ip

# Then run the Quick Setup script (see above), starting with:
sudo apt update && sudo apt install -y tmux git curl
# ... rest of the Quick Setup block
```

EU and US datacenters available. No egress fees.

</details>

<details>
<summary><strong>DigitalOcean ($6/mo)</strong></summary>

1. Create a **Basic Droplet** with **Ubuntu 24.04**
2. SSH into the droplet
3. Run the Quick Setup block from above

```bash
ssh root@your-droplet-ip

# Then run the Quick Setup script (see above), starting with:
sudo apt update && sudo apt install -y tmux git curl
# ... rest of the Quick Setup block
```

Simple UI, great for getting started quickly.

</details>

<details>
<summary><strong>AWS EC2 (free tier eligible)</strong></summary>

1. Launch a **t3.micro** instance with the **Ubuntu 24.04** AMI
2. Configure the security group to allow **SSH (port 22)** from your IP
3. SSH into the instance with your key pair
4. Run the Quick Setup block from above

```bash
ssh -i your-key.pem ubuntu@your-ec2-ip

# Then run the Quick Setup script (see above), starting with:
sudo apt update && sudo apt install -y tmux git curl
# ... rest of the Quick Setup block
```

Free tier gives you 12 months of t3.micro at no cost.

</details>

**Security reminders:**

- **Never commit API keys** — use environment variables or a `.env` file (already in `.gitignore`)
- Set `ANTHROPIC_API_KEY` in your shell profile or use `claude auth` for session-based auth
- Use SSH key authentication — disable password auth in `sshd_config` for production servers

### Next Steps

Once the team is running, follow the [Quick Start](../README.md#quick-start) in the main README for usage instructions — giving the Manager tasks, monitoring workers, and using slash commands.

### Platform Notes

- **macOS notifications are not available on Linux.** The status hook sends desktop notifications via `osascript` on macOS when the Manager completes a task. On Linux, these notifications are silently skipped — all other functionality works identically.

### Troubleshooting (Linux)

| Issue | Fix |
|-------|-----|
| **tmux version too old** (< 2.4) | Install from source or use a backports repo: `sudo apt install -t bullseye-backports tmux` |
| **`node` not found after fnm install** | Run `source ~/.bashrc` or open a new shell — fnm needs the PATH update |
| **Locale / UTF-8 errors** (garbled ASCII art) | `sudo apt install -y locales && sudo locale-gen en_US.UTF-8 && export LANG=en_US.UTF-8` |
| **`ct` / `claude-team` command not found** | Ensure `~/.local/bin` is on your PATH: `export PATH="$HOME/.local/bin:$PATH"` |
| **Workers fail to start** | Check that `claude` CLI works standalone first: `claude --version` |
