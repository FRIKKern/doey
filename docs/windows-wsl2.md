# Windows Installation (WSL2)

> Part of [Doey](../README.md)

Doey runs natively on Windows through WSL2 (Windows Subsystem for Linux). No dual-boot or VM needed — WSL2 gives you a real Linux kernel inside Windows with full tmux support.

### Prerequisites

- Windows 10 (version 2004+) or Windows 11
- Admin access for WSL2 installation

### Step 1: Install WSL2

```
wsl --install
```

This installs Ubuntu by default. Restart your PC when prompted.

After restart, Ubuntu will open automatically — set up your Unix username and password.

### Step 2: Install Dependencies

Once inside the WSL2 Ubuntu terminal, it's standard Linux from here:

```bash
sudo apt update && sudo apt install -y tmux git curl

# Install Node.js via fnm
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc
fnm install --lts
```

### Step 3: Install Claude Code & Doey

```bash
npm install -g @anthropic-ai/claude-code
claude auth

# Install Doey
curl -fsSL https://raw.githubusercontent.com/frikk-gyldendal/claude-code-tmux-team/main/web-install.sh | bash
```

### Step 4: Launch

```bash
cd /path/to/your/project
doey init
doey
```

That's it — from here, the experience is identical to macOS and Linux. Follow the [Quick Start](../README.md#quick-start) in the main README for usage instructions.

### Tips for WSL2 Users

- **Access Windows files** from WSL2 at `/mnt/c/Users/YourName/...` — but working inside the Linux filesystem (`~/`) is significantly faster
- **Windows Terminal** is the best way to use WSL2 — it supports tabs, splits, and renders the tmux grid cleanly. Install it from the Microsoft Store if you don't have it.
- **VS Code integration** — run `code .` from WSL2 to open VS Code with the WSL remote extension
- **Clipboard** works between Windows and WSL2 automatically
- **RAM allocation** — WSL2 uses up to 50% of system RAM by default. For a 10-worker team, 8GB+ total system RAM is comfortable. You can limit WSL2 memory in `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=4GB
```
