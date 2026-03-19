<div align="center">

<img width="361" height="341" alt="image" src="https://github.com/user-attachments/assets/15356424-a33a-4cee-95c4-4973b7e9620a" />


<h3>Let me Doey for you</h3>

<p><em>Run parallel Claude Code agents in one terminal</em></p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-CLI-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![tmux](https://img.shields.io/badge/tmux-powered-green)](https://github.com/tmux/tmux)

</div>

---

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

Manager breaks tasks into subtasks, dispatches to workers, monitors progress. Dynamic grid (4 teams, 24 workers default). Scale with `doey add`.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

# Launch
cd ~/your-project
doey              # first time: project picker → choose "init"
doey              # after that: auto-launches your team
```

Or: `git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh`

> **Other platforms:** [Linux server](docs/linux-server.md) · [Windows WSL2](docs/windows-wsl2.md) · [Linode VPS](docs/linode-setup.md)

---

## How It Works

1. `doey init` — register your project (once)
2. `doey` — launch or reattach
3. Tell the Window Manager your task
4. Manager plans, Workers execute in parallel, Watchdog monitors
5. Consolidated results when done

---

## Worktree Isolation

Teams can run in isolated git worktrees — each gets its own branch at `<project>/.doey-worktrees/team-N/`. No merge conflicts between teams.

```bash
doey add-team --worktree     # add isolated team
doey kill-team N             # auto-saves, removes worktree, preserves branch
```

---

## CLI Commands

| Command | Description |
|---------|-------------|
| `doey` | Smart launch — attach, launch, or project picker |
| `doey init` | Register current directory as a project |
| `doey add` / `remove` | Add/remove worker columns |
| `doey stop` | Stop the team |
| `doey reload` | Hot-reload (Manager+Watchdog; `--workers` for all) |
| `doey add-team` / `kill-team <N>` | Add/kill team windows |
| `doey list` / `list-teams` | List projects / team windows |
| `doey purge` | Clean runtime files, audit context |
| `doey doctor` | Check installation health |
| `doey update` | Pull latest and reinstall |
| `doey test` | Run test suite |
| `doey 4x3` | Static grid layout |
| `doey uninstall` | Remove doey completely |

---

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard with team status and events |
| Session Manager | `0.1` | Coordinates across team windows |
| Watchdog | `0.2-0.7` | One per team — monitors workers, catches crashes |
| Window Manager | `W.0` | Per-window orchestrator. Plans and delegates. |
| Workers | `W.1+` | Execute tasks autonomously |

Dashboard (window 0) + team windows (1+). See [Context Reference](docs/context-reference.md).

---

<details>
<summary><strong>Slash Commands (21)</strong></summary>

| Command | Description |
|---------|-------------|
| `/doey-dispatch` | Dispatch tasks to workers |
| `/doey-delegate` | Send task to specific pane |
| `/doey-monitor` | Check worker statuses |
| `/doey-team` | Full team overview |
| `/doey-research` | Research with guaranteed report |
| `/doey-broadcast` | Message all panes |
| `/doey-status` | View/set pane status |
| `/doey-purge` | Audit & fix context rot |
| `/doey-reserve` | Reserve pane for human use |
| `/doey-add-window` / `-kill-window` | Add/kill team windows |
| `/doey-kill-session` / `-kill-all-sessions` | Kill session(s) |
| `/doey-list-windows` | List team windows |
| `/doey-reload` / `-reinstall` | Reload/reinstall |
| `/doey-stop` | Stop a worker |
| `/doey-repair` | Dashboard diagnostic |
| `/doey-clear` | Clear and restart panes |
| `/doey-worktree` | Toggle worktree isolation |
| `/doey-watchdog-compact` | Compact Watchdog context |

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

---

## Requirements

[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (authenticated) · [Node.js](https://nodejs.org/) v18+ · [tmux](https://github.com/tmux/tmux) · macOS or Linux

---

Contributions welcome — open an issue or submit a PR.

<div align="center">

**Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code)** · [Star it](https://github.com/FRIKKern/doey) if useful

</div>
