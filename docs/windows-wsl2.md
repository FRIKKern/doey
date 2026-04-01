# Windows (WSL2)

> Windows 10 (2004+) or Windows 11, admin access required.

### Setup

```bash
# 1. Install WSL2 (restart when prompted)
wsl --install

# 2. Inside WSL2 Ubuntu
sudo apt update && sudo apt install -y tmux git curl
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc && fnm install --lts

# 3. Install Claude Code & Doey
npm install -g @anthropic-ai/claude-code && claude auth
curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

# 4. Launch
cd /path/to/your/project && doey init && doey
```

From here, usage is identical to macOS/Linux. See [Quick Start](../README.md#quick-start).

### Tips

- Work inside `~/` — `/mnt/c/` is much slower
- **Windows Terminal** renders tmux best
- `code .` opens VS Code with WSL remote extension
- Limit WSL2 RAM in `%UserProfile%\.wslconfig`:
  ```ini
  [wsl2]
  memory=4GB
  ```
