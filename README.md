<div align="center">

<img width="361" height="341" alt="image" src="https://github.com/user-attachments/assets/15356424-a33a-4cee-95c4-4973b7e9620a" />


<h3>Let me Doey for you</h3>

<p><em>Run parallel Claude Code agents in one terminal</em></p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-CLI-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![tmux](https://img.shields.io/badge/tmux-powered-green)](https://github.com/tmux/tmux)

</div>

```
┌──────────┬──────────────┬──────────────┐
│ MANAGER  │ Worker 1     │ Worker 3     │
│ plans &  │  ┌─agent─┐   │  ┌─agent─┐   │  scales →
│ delegates│  │ ↓ ↓ ↓ │   │  │ ↓ ↓ ↓ │   │
├──────────┼──────────────┼──────────────┤
│          │ Worker 2     │ Worker 4     │  workers spawn
│          │  ┌─agent─┐   │  ┌─agent─┐   │  their own agents
│          │  │ ↓ ↓ ↓ │   │  │ ↓ ↓ ↓ │   │
└──────────┴──────────────┴──────────────┘
 WATCHDOG monitors from Dashboard (window 0)
```

Manager plans and delegates. Workers execute in parallel. Dynamic grid — scale with `doey add`.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

# Launch (first time: project picker → "init"; after that: auto-launches)
cd ~/your-project && doey
```

Or: `git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh`

> **Other platforms:** [Linux server](docs/linux-server.md) · [Windows WSL2](docs/windows-wsl2.md) · [Linode VPS](docs/linode-setup.md)

Tell the Window Manager your task — it plans, Workers execute in parallel, Watchdog monitors, results are consolidated.

## CLI Commands

| Command | Description |
|---------|-------------|
| `doey` | Smart launch — attach, launch, or project picker |
| `doey init` | Register current directory as a project |
| `doey add` / `remove` | Add/remove worker columns |
| `doey stop` | Stop the team |
| `doey reload` | Hot-reload (Manager+Watchdog; `--workers` for all) |
| `doey add-team [--worktree]` / `kill-team <N>` | Add/kill team windows (worktree = isolated branch) |
| `doey list` / `list-teams` | List projects / team windows |
| `doey purge` | Clean runtime files, audit context |
| `doey doctor` | Check installation health |
| `doey update` | Pull latest and reinstall |
| `doey test` | Run test suite |
| `doey 4x3` | Static grid layout |
| `doey dynamic` | Dynamic grid (add workers on demand) (default) |
| `doey uninstall` | Remove doey completely |

## Architecture

Window 0 is the dashboard; team windows (1+) each have a Manager + Workers.

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard |
| Session Manager | `0.1` | Cross-team coordination |
| Watchdog | `0.2+` | One per team — monitors workers |
| Window Manager | `W.0` | Plans and delegates |
| Workers | `W.1+` | Execute tasks in parallel |

See [Context Reference](docs/context-reference.md) for details.

<details>
<summary><strong>Slash Commands</strong></summary>

**Tasks:** `/doey-dispatch`, `/doey-delegate`, `/doey-research`, `/doey-broadcast`
**Monitor:** `/doey-monitor`, `/doey-status`, `/doey-watchdog-compact`
**Infra:** `/doey-add-window`, `/doey-kill-window`, `/doey-list-windows`, `/doey-worktree`
**Lifecycle:** `/doey-stop`, `/doey-clear`, `/doey-reload`, `/doey-reinstall`, `/doey-reserve`, `/doey-repair`, `/doey-purge`, `/doey-simplify-everything`
**Session:** `/doey-kill-session`, `/doey-kill-all-sessions`
**R&D:** `/doey-rd-team`

</details>

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Workers "Not logged in" | Run `claude` in a terminal first to authenticate |
| Terminal too small | Use `doey 3x2` or maximize terminal |
| `doey` not found | Add `~/.local/bin` to PATH |
| Workers stuck | `/doey-clear workers` restarts them |
| `doey update` fails | Clone manually: `git clone ... && ./install.sh` |
| Other | Run `doey doctor` |

## Requirements

[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (authenticated) · [Node.js](https://nodejs.org/) v18+ · [tmux](https://github.com/tmux/tmux) · macOS or Linux

---

Contributions welcome — [open an issue](https://github.com/FRIKKern/doey/issues) or submit a PR. Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
