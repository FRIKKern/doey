# Linode Setup Guide

> Part of [Doey](../README.md) — deploy your AI team on a Linode VPS

Run Doey on a Linode server so your team keeps working after you disconnect. Start a task, detach, close your laptop, come back to find the work done.

---

## Prerequisites

Before you start, make sure you have:

- **Anthropic API key** or a **Claude Max subscription** (for Claude Code authentication)
- **SSH key pair** on your local machine (`ssh-keygen -t ed25519` if you don't have one)
- A **Linode account** — [cloud.linode.com](https://cloud.linode.com)

---

## 1. Provision a Linode Instance

Doey is network-bound (API calls to Anthropic), not CPU/RAM-intensive. A small instance is all you need.

### Recommended Plans

| Plan | vCPUs | RAM | Storage | Monthly | Best for |
|------|-------|-----|---------|---------|----------|
| **Nanode 1 GB** | 1 | 1 GB | 25 GB | $5/mo | Solo use, small teams (2-4 workers) |
| **Linode 2 GB** | 1 | 2 GB | 50 GB | $12/mo | Medium teams (4-8 workers) |
| **Linode 4 GB** | 2 | 4 GB | 80 GB | $24/mo | Large teams, multiple projects |

The Nanode ($5/mo) works well for most use cases. Scale up if you plan to run many workers or clone large repos.

### Via Web UI

1. Log in to [cloud.linode.com](https://cloud.linode.com)
2. Click **Create Linode**
3. Choose **Ubuntu 24.04 LTS**
4. Select a region close to you (latency to Anthropic's API matters less than SSH latency to you)
5. Pick **Nanode 1 GB** (or larger)
6. Under **SSH Keys**, add your public key
7. Set a root password (backup auth — you'll disable password login)
8. Click **Create Linode**

### Via Linode CLI

Install the Linode CLI if you prefer the terminal:

```bash
pip install linode-cli
linode-cli configure
```

Then create your instance:

```bash
linode-cli linodes create \
  --type g6-nanode-1 \
  --region us-east \
  --image linode/ubuntu24.04 \
  --label doey-server \
  --root_pass "$(openssl rand -base64 24)" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)"
```

Note the IP address from the output.

---

## 2. Initial Server Configuration

SSH into your new server:

```bash
ssh root@YOUR_LINODE_IP
```

### Create a Non-Root User

```bash
adduser doey
usermod -aG sudo doey
```

Copy your SSH key to the new user:

```bash
mkdir -p /home/doey/.ssh
cp /root/.ssh/authorized_keys /home/doey/.ssh/
chown -R doey:doey /home/doey/.ssh
chmod 700 /home/doey/.ssh
chmod 600 /home/doey/.ssh/authorized_keys
```

### Harden SSH

```bash
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

> **Important:** Before closing this session, verify you can SSH in as the new user from a second terminal: `ssh doey@YOUR_LINODE_IP`

### Firewall

```bash
ufw allow OpenSSH
ufw enable
```

Type `y` when prompted. This blocks everything except SSH (port 22).

### Swap Space

The Nanode has only 1 GB RAM. Add swap as a safety net:

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

Verify:

```bash
free -h
# Should show 2.0G under Swap
```

### System Updates

```bash
apt update && apt upgrade -y
```

Now log out of root and reconnect as your user:

```bash
exit
ssh doey@YOUR_LINODE_IP
```

---

## 3. Install Dependencies

```bash
sudo apt update && sudo apt install -y tmux git curl jq
```

### Node.js 18+ (via fnm)

```bash
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc
fnm install --lts
```

Verify:

```bash
node --version   # Should show v20.x or v22.x
npm --version    # Should show 10.x+
```

> **Note:** Ubuntu 24.04 ships with bash 5.x, so the bash 3.2 compatibility concerns from macOS don't apply here.

---

## 4. Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

### Authentication

**Option A — API Key (recommended for servers):**

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

Add to your shell profile so it persists:

```bash
echo 'export ANTHROPIC_API_KEY="sk-ant-YOUR_KEY_HERE"' >> ~/.bashrc
source ~/.bashrc
```

**Option B — OAuth (interactive login):**

```bash
claude auth
```

This opens a browser-based flow. On a headless server, it will print a URL — open it on your local machine, complete the auth, and paste the code back.

Verify Claude Code works:

```bash
claude --version
claude "say hello"   # Quick test
```

---

## 5. Install Doey

```bash
cd ~
git clone https://github.com/FRIKKern/doey.git
cd doey
./install.sh
```

The installer will:
- Create directories (`~/.claude/agents/`, `~/.claude/commands/`, etc.)
- Install agent definitions (Window Manager, Session Manager, Watchdog, Test Driver)
- Install slash commands (23 total)
- Install the `doey` CLI to `~/.local/bin/doey`
- Run a context audit

If `~/.local/bin` isn't in your PATH, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify the installation:

```bash
doey doctor
```

You should see all green checkmarks:

```
  Doey — System Check

  ✓ tmux installed  tmux 3.4
  ✓ claude CLI installed  1.x.x
  ✓ ~/.local/bin is in PATH
  ✓ Agents installed
  ✓ Commands installed
  ✓ CLI installed
  ✓ Repo registered
  ✓ jq installed
```

---

## 6. Running Doey

### Initialize a Project

Navigate to the project you want to work on:

```bash
cd ~/your-project
doey init
```

### Launch the Team

```bash
doey
```

This starts a tmux session with the Window Manager, Watchdog, and Workers in a dynamic grid. You'll be attached to the session automatically.

### Give the Window Manager a Task

Click on the Window Manager pane (top-left, pane 0.0) and type your task:

```
Refactor all API endpoints to use the new validation middleware
```

The Window Manager will plan, break it into subtasks, and dispatch to workers.

### Detach (Keep Running)

Press `Ctrl+B`, then `D` to detach. The session continues running in the background.

### Reattach Later

```bash
ssh doey@YOUR_LINODE_IP
cd ~/your-project
doey                     # Auto-reattaches to running session
```

### Scale Workers

```bash
doey add                 # Add a column of workers to the running session
doey remove 3            # Remove worker column 3
```

### Stop the Team

```bash
doey stop
```

---

## 7. Persistent Sessions with systemd

For always-on operation, set up Doey as a systemd user service. This auto-starts Doey on boot and restarts it on failure.

Create the service file:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/doey.service << 'EOF'
[Unit]
Description=Doey — Multi-agent Claude Code team
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=HOME=%h
Environment=ANTHROPIC_API_KEY=sk-ant-YOUR_KEY_HERE
Environment=PATH=%h/.local/bin:%h/.fnm/aliases/default/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=%h/your-project
ExecStart=/usr/bin/tmux new-session -d -s doey-%i %h/.local/bin/doey
ExecStop=/usr/bin/tmux kill-session -t doey-%i
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
```

> **Important:** Replace `sk-ant-YOUR_KEY_HERE` with your actual API key and `your-project` with your project directory name.

> **Note:** The session name follows Doey's convention: `doey-<project-name>`. Make sure the `-s` flag in ExecStart and `-t` flag in ExecStop match your project name.

Enable and start:

```bash
sudo loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user enable doey
systemctl --user start doey
```

Check status:

```bash
systemctl --user status doey
```

Attach to the running session:

```bash
cd ~/your-project
doey
```

---

## 8. Monitoring & Maintenance

### Check Worker Status

From inside a Doey session, the Window Manager can use:
- `/doey-monitor` — Quick status check of all workers
- `/doey-team` — Full team overview
- `/doey-status` — View or set pane status

### Runtime Files

Doey stores runtime data in `/tmp/doey/<project>/`. This includes status files, messages, results, and research reports.

Clean stale files:

```bash
doey purge
```

### Disk Space

Monitor disk usage periodically:

```bash
df -h /
du -sh /tmp/doey/
du -sh ~/your-project/
```

The Nanode has 25 GB — watch for large repos or accumulated logs.

### Update Doey

```bash
doey update
```

Or manually:

```bash
cd ~/doey
git pull
./install.sh
```

After updating hooks, restart all workers with `/doey-restart-window` from the Window Manager pane.

---

## 9. Security Considerations

### API Key Storage

- **Never** commit API keys to git
- Store the key in `~/.bashrc` or use a secrets manager
- If using systemd, the key is in the service file — restrict permissions:

```bash
chmod 600 ~/.config/systemd/user/doey.service
```

### Firewall

The default UFW config only allows SSH. If you don't need any other ports open, you're good.

```bash
sudo ufw status
```

### SSH Keys Only

Password authentication is already disabled (from step 2). Verify:

```bash
grep PasswordAuthentication /etc/ssh/sshd_config
# Should show: PasswordAuthentication no
```

### Keep Updated

```bash
sudo apt update && sudo apt upgrade -y   # System packages
npm update -g @anthropic-ai/claude-code   # Claude Code
doey update                                # Doey itself
```

---

## 10. Troubleshooting

| Issue | Solution |
|-------|----------|
| `doey` command not found | `export PATH="$HOME/.local/bin:$PATH"` and add to `~/.bashrc` |
| `node` not found after SSH | `source ~/.bashrc` (fnm needs to initialize) |
| Claude auth fails | Re-run `claude auth` or check `ANTHROPIC_API_KEY` is exported |
| Workers show "Not logged in" | Run `claude` once in a regular terminal to authenticate |
| tmux too old | Ubuntu 24.04 ships tmux 3.4 — shouldn't be an issue. If using 22.04: `sudo apt install tmux` gives 3.2a (sufficient) |
| Session won't start | Check `doey doctor` — fix any red items |
| Workers stuck | Window Manager can run `/doey-restart-window` |
| Disk full | Run `doey purge` and check `du -sh /tmp/doey/` |
| SSH disconnects frequently | Use mosh (see Tips below) |
| systemd service won't start | Check logs: `journalctl --user -u doey -f` |
| Locale/UTF-8 errors | `sudo apt install -y locales && sudo locale-gen en_US.UTF-8` |

---

## 11. Tips

### Use mosh for Unstable Connections

[mosh](https://mosh.org/) handles roaming, intermittent connectivity, and high latency better than SSH:

```bash
# On the server
sudo apt install -y mosh
sudo ufw allow 60000:61000/udp

# From your local machine
brew install mosh        # macOS
mosh doey@YOUR_LINODE_IP
```

Then use `doey` as normal inside the mosh session.

### Multiple Terminals, Same Session

You can attach to the same tmux session from multiple SSH connections:

```bash
# Terminal 1
ssh doey@YOUR_LINODE_IP
cd ~/your-project && doey

# Terminal 2
ssh doey@YOUR_LINODE_IP
cd ~/your-project && doey   # Attaches to the same session
```

Both terminals see the same panes. Useful for watching workers on a large monitor while giving the Window Manager tasks from another.

### Resource Monitoring

Keep an eye on resource usage:

```bash
htop                        # Interactive process viewer (sudo apt install htop)
watch -n 5 free -h          # Memory usage every 5 seconds
```

### Quick Launch Aliases

Add to `~/.bashrc`:

```bash
alias ds="doey"             # Quick launch
alias dstop="doey stop"     # Quick stop
alias dlist="doey list"     # List projects
```

### Multiple Projects

You can run Doey for different projects simultaneously — each gets its own tmux session:

```bash
cd ~/project-a && doey      # Creates session doey-project-a
# Detach with Ctrl+B, D
cd ~/project-b && doey      # Creates session doey-project-b
```

List all running sessions:

```bash
doey list
tmux list-sessions
```

### Backups

Consider enabling Linode Backups ($2/mo for Nanode) from the Linode dashboard. This gives you automatic weekly + daily snapshots — useful if a worker makes unintended changes to your repo. You can also rely on git for code, but backups cover everything including config.

---

## Quick Reference

```bash
# Launch & manage
doey                         # Start or reattach
doey init                    # Register a project
doey add                     # Add workers
doey stop                    # Stop the team
doey doctor                  # Health check

# Inside a session
Ctrl+B, D                   # Detach (team keeps running)
Ctrl+B, arrow keys           # Navigate between panes

# Remote access
ssh doey@YOUR_LINODE_IP      # Connect
cd ~/your-project && doey    # Reattach
```
