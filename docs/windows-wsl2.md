# Windows Installation (WSL2)

> Part of [Doey](../README.md)

Doey runs on Windows through WSL2. No dual-boot needed — WSL2 provides a real Linux kernel with full tmux support.

### Prerequisites

- Windows 10 (2004+) or Windows 11
- Admin access for WSL2

### Setup

**1. Install WSL2:** `wsl --install` (installs Ubuntu by default, restart when prompted)

**2. Install dependencies** (inside WSL2 Ubuntu):
```bash
sudo apt update && sudo apt install -y tmux git curl
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc && fnm install --lts
```

**3. Install Claude Code & Doey:**
```bash
npm install -g @anthropic-ai/claude-code && claude auth
curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash
```

**4. Launch:**
```bash
cd /path/to/your/project
doey init && doey
```

From here, usage is identical to macOS/Linux. See [Quick Start](../README.md#quick-start).

### Tips

- Work inside Linux filesystem (`~/`) for best performance; Windows files at `/mnt/c/...` are slower
- **Windows Terminal** renders the tmux grid best (install from Microsoft Store)
- `code .` opens VS Code with WSL remote extension
- WSL2 uses up to 50% system RAM. Limit in `%UserProfile%\.wslconfig`:
  ```ini
  [wsl2]
  memory=4GB
  ```
