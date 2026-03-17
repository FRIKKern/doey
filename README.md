<div align="center">

<img width="361" height="341" alt="image" src="https://github.com/user-attachments/assets/15356424-a33a-4cee-95c4-4973b7e9620a" />


<h3>Let me Doey for you</h3>

<p><em>Your loyal AI team doggo — run parallel Claude Code agents in one terminal</em></p>

<p>A Window Manager that plans, Workers that build, and a Watchdog that keeps it all running — inside tmux.</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-CLI-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![tmux](https://img.shields.io/badge/tmux-powered-green)](https://github.com/tmux/tmux)

</div>

---

```
┌──────────┬──────────────────┬──────────────────┐
│ MANAGER  │ Worker 1         │ Worker 3         │
│          │  ┌─agent─┐       │  ┌─agent─┐       │
│ plans &  │  │ ↓ ↓ ↓ │ ...   │  │ ↓ ↓ ↓ │ ...   │
│ delegates│  └───────┘       │  └───────┘       │    scales as needed →
├──────────┼──────────────────┼──────────────────┤
│          │ Worker 2         │ Worker 4         │    each worker spawns its
│          │  ┌─agent─┐       │  ┌─agent─┐       │    own agent swarms
│          │  │ ↓ ↓ ↓ │ ...   │  │ ↓ ↓ ↓ │ ...   │
│          │  └───────┘       │  └───────┘       │
└──────────┴──────────────────┴──────────────────┘
 WATCHDOG monitors from Dashboard (window 0)
```

---

## The Problem

You have 30 files to refactor. One Claude Code instance. You wait for each file, one by one.

## The Solution

Doey launches **parallel Claude Code instances** coordinated by a Window Manager that breaks your task into subtasks, dispatches them to workers, and monitors progress — all in one tmux session.

You talk to the Window Manager. The Window Manager runs the team. You ship faster.

The grid is **dynamic by default** — starts lean with 6 workers, then use `doey add` to scale up when you need more horsepower. No restarts needed.

---

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

# Launch
cd ~/your-project
doey              # first time: project picker → choose "init"
doey              # after that: auto-launches your team
```

Or clone locally: `git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh`

No config files. No shell reload. Just `doey`.

> **Other platforms:** [Linux server](docs/linux-server.md) · [Windows WSL2](docs/windows-wsl2.md) · [Linode VPS](docs/linode-setup.md)

---

## How It Works

1. **Init** — `doey init` registers your project (once)
2. **Launch** — `doey` starts the team or reattaches to a running session
3. **Tell the Window Manager** — *"Refactor all components to use the new design tokens"*
4. **Window Manager plans** — breaks the task into independent, parallelizable subtasks
5. **Workers execute** — each gets a self-contained prompt and works autonomously
6. **Watchdog monitors** — tracks state, delivers messages, catches crashes
7. **Window Manager reports** — consolidated summary when everything's done

---

## Features

- **Dynamic grid** — starts with 6 workers, scale up with `doey add`, scale down with `doey remove`
- **Parallel execution** — workers run simultaneously, not sequentially
- **Smart orchestration** — Window Manager plans and delegates, never writes code itself
- **Always-on monitoring** — Watchdog tracks worker state and catches crashes
- **Context management** — `doey purge` scans for stale runtime files and audits context bloat
- **22 slash commands** — `/doey-dispatch`, `/doey-monitor`, `/doey-analyze`, and more
- **Human reservation** — `/doey-reserve` locks a pane for your own use
- **Zero config** — install, init, launch. Works with any project.

---

## Commands

| Command | Description |
|---------|-------------|
| `doey` | Smart launch — attach, launch, or show project picker |
| `doey init` | Register current directory as a project |
| `doey add` | Add workers to a running session |
| `doey remove` | Remove a worker column (by number) or unregister a project (by name) |
| `doey stop` | Stop the team |
| `doey purge` | Clean stale runtime files, audit context bloat |
| `doey list` | Show all projects with status |
| `doey doctor` | Check installation health |
| `doey update` | Pull latest and reinstall (alias: `reinstall`) |
| `doey reload` | Hot-reload running session (Manager + Watchdog; `--workers` for all) |
| `doey version` | Show version info |
| `doey dynamic` | Launch in dynamic grid mode (alias: `d`) |
| `doey add-window` | Add a new team window with its own Window Manager and Workers (Watchdog in Dashboard) |
| `doey kill-window <N>` | Kill a team window and all its processes |
| `doey list-windows` | List all team windows with status |
| `doey test` | Run test suite |
| `doey uninstall` | Remove doey completely |
| `doey 4x3` | Launch with a static grid layout |

---

## Architecture

| Role | Pane | What it does |
|------|------|-------------|
| **Info Panel** | `0.0` (Dashboard) | Live dashboard showing team status, events, worker counts. |
| **Session Manager** | `0.1` (Dashboard) | Session-level orchestrator — coordinates across team windows. |
| **Watchdog** | `0.2-0.5` (Dashboard) | One per team. Monitors workers, delivers messages, catches crashes. |
| **Window Manager** | `W.0` | Per-window orchestrator. Plans, delegates, monitors. Never writes code. |
| **Workers** | `W.1+` | Claude Code instances that do the actual work. |

Window 0 (Dashboard) hosts the Info Panel, up to 4 Watchdog slots (one per team), and the Session Manager. Each team window (W≥1) has its own Window Manager and Workers.

Runtime data lives in `/tmp/doey/<project>/` — status files, messages, results, research reports. See [Context Reference](docs/context-reference.md) for the full picture.

---

<details>
<summary><strong>Slash Commands</strong></summary>

| Command | Description |
|---------|-------------|
| `/doey-dispatch` | Dispatch tasks to workers |
| `/doey-delegate` | Send a task to a specific pane |
| `/doey-monitor` | Check all worker statuses |
| `/doey-team` | Full team overview |
| `/doey-research` | Dispatch research with guaranteed report |
| `/doey-broadcast` | Message all panes |
| `/doey-status` | View or set pane status |
| `/doey-purge` | Run purge from inside a session |
| `/doey-reserve` | Reserve a pane for human use |
| `/doey-add-window` | Add a new team window |
| `/doey-kill-window` | Kill a team window and all its processes |
| `/doey-kill-session` | Kill entire Doey session |
| `/doey-kill-all-sessions` | Kill all running Doey sessions across all projects |
| `/doey-list-windows` | List all team windows with status |
| `/doey-reload` | Hot-reload session (install files, restart Manager + Watchdog) |
| `/doey-restart-window` | Restart workers and Watchdog in a window |
| `/doey-stop` | Stop a specific worker |
| `/doey-stop-all` | Stop all running Doey sessions *(deprecated, replaced by `/doey-kill-session`)* |
| `/doey-restart-workers` | Restart workers and Watchdog *(deprecated, replaced by `/doey-restart-window`)* |
| `/doey-reinstall` | Reinstall from repo |
| `/doey-watchdog-compact` | Compact Watchdog context |
| `/doey-analyze` | Full project analysis — find and fix doc obscurities |

</details>

<details>
<summary><strong>File Structure</strong></summary>

```
doey/
├── CLAUDE.md                    # Project context for Claude Code
├── install.sh                   # Installer
├── web-install.sh               # Web installer (curl | bash)
├── agents/
│   ├── doey-manager.md          # Window Manager agent definition
│   ├── doey-session-manager.md  # Session Manager (multi-window orchestrator)
│   ├── doey-watchdog.md         # Watchdog agent definition
│   └── test-driver.md           # E2E test driver
├── commands/                    # Slash commands → ~/.claude/commands/
│   ├── doey-dispatch.md
│   ├── doey-purge.md
│   ├── doey-research.md
│   └── ... (22 total)
├── docs/
│   ├── context-reference.md     # Full context layer reference
│   ├── linode-setup.md          # Linode VPS deployment guide
│   ├── linux-server.md
│   └── windows-wsl2.md
├── shell/
│   ├── doey.sh                  # CLI → ~/.local/bin/doey
│   ├── info-panel.sh            # Live info panel dashboard (window 0.0)
│   ├── context-audit.sh         # Context pattern auditor
│   ├── tmux-statusbar.sh        # Dynamic status-right renderer
│   └── pane-border-status.sh    # Pane border label renderer
└── .claude/hooks/               # Modular event hooks
    ├── common.sh
    ├── on-session-start.sh
    ├── on-prompt-submit.sh
    ├── on-pre-tool-use.sh
    ├── on-pre-compact.sh
    ├── post-tool-lint.sh
    ├── stop-status.sh
    ├── stop-results.sh
    ├── stop-notify.sh
    └── watchdog-scan.sh
```

</details>

---

## Tips

```bash
alias doeys="doey 3x2"   # small team (5 workers)
alias doey4="doey 4x2"   # medium team (7 workers)
```

Copy commands into your project for project-scoped access:
```bash
cp -r /path/to/doey/commands/ .claude/commands/
```

---

## Troubleshooting

<details>
<summary><strong>Workers show "Not logged in"</strong></summary>

Run `claude` in a regular terminal first to authenticate. Workers inherit your auth.

</details>

<details>
<summary><strong>Terminal too small</strong></summary>

Use `doey 3x2` or maximize your terminal. The dynamic grid needs ~50 columns per worker.

</details>

<details>
<summary><strong><code>doey</code> command not found</strong></summary>

Add `~/.local/bin` to your PATH:
```bash
export PATH="$HOME/.local/bin:$PATH"
```
Then restart your shell.

</details>

<details>
<summary><strong>Workers stuck</strong></summary>

The Window Manager can run `/doey-restart-window` to restart all workers without killing itself.

</details>

<details>
<summary><strong><code>doey update</code> fails</strong></summary>

The web installer's temp directory was deleted. Clone manually instead:
```bash
git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh
```

</details>

<details>
<summary><strong>Other issues</strong></summary>

Run `doey doctor` — it checks tmux, Claude CLI, PATH, agents, commands, and repo path. Most issues are fixed by re-running `./install.sh`.

</details>

---

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (authenticated)
- [Node.js](https://nodejs.org/) v18+
- [tmux](https://github.com/tmux/tmux)
- macOS or Linux

---

## Contributing

Contributions welcome — open an issue or submit a PR. This project is in active development.

---

<div align="center">

**Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code)**

[⭐ Star it](https://github.com/FRIKKern/doey) if you find it useful

</div>
