<div align="center">

<img width="361" height="341" alt="image" src="https://github.com/user-attachments/assets/15356424-a33a-4cee-95c4-4973b7e9620a" />


<h3>Let me Doey for you</h3>

<p><em>Your loyal AI team doggo assistant — run 10 Claude Code agents in parallel, one terminal</em></p>

<p>Orchestrate a fleet of AI coding agents with a Manager that plans, Workers that execute,<br>and a Watchdog that keeps everything running — all inside tmux.</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-CLI-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![tmux](https://img.shields.io/badge/tmux-powered-green)](https://github.com/tmux/tmux)
[![Shell](https://img.shields.io/badge/Shell-Bash%20%2F%20Zsh-orange)](#requirements)

</div>

---

```
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ 0.0      │ 0.1      │ 0.2      │ 0.3      │ 0.4      │ 0.5      │
│ MANAGER  │ Worker 1 │ Worker 2 │ Worker 3 │ Worker 4 │ Worker 5 │
├──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤
│ 0.6      │ 0.7      │ 0.8      │ 0.9      │ 0.10     │ 0.11     │
│ WATCHDOG │ Worker 6 │ Worker 7 │ Worker 8 │ Worker 9 │ Worker10 │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
          Default 6x2 grid — 10 workers, 1 manager, 1 watchdog
```

---

## The Problem

You have 30 files to refactor. One Claude Code instance. You wait for each file, one by one. It takes forever.

## The Solution

Doey launches **10 Claude Code instances in parallel**, coordinated by a Manager agent that breaks your task into subtasks, dispatches them to idle workers, and monitors progress — all in a single tmux session.

You talk to the Manager. The Manager runs the team. You ship 10x faster.

---

## Quick Start

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/frikk-gyldendal/doey/main/web-install.sh | bash
```

Or clone and install locally:

```bash
git clone https://github.com/frikk-gyldendal/doey.git
cd doey && ./install.sh
```

The installer validates prerequisites automatically (Claude Code CLI, tmux, shell config) and provides clear feedback with colored output.

> **Other platforms:** For Linux server deployment, see [docs/linux-server.md](docs/linux-server.md). For Windows (WSL2), see [docs/windows-wsl2.md](docs/windows-wsl2.md).

**Launch:**

```bash
cd ~/your-project
doey                   # first time: shows project picker, choose "init"
doey                   # next time: auto-launches your team
```

That's it. No config files. No shell reload. Just `doey`.

---

## What You'll See

When you run `doey`, the startup sequence gives you full visibility into what's happening:

1. **ASCII art banner** with your session configuration (grid size, worker count, working directory)
2. **Step-by-step progress** — each phase (grid creation, pane setup, agent launches) shows a checkmark as it completes
3. **Workers boot in ~15 seconds** — Claude Code instances launch in parallel across the grid
4. **Summary dashboard** — a formatted box confirms the session is ready, showing the grid layout and pane assignments

Once the summary appears, switch to the Manager pane (`0.0`) and start giving it tasks.

> Run `doey` to see the premium startup experience.

---

## Commands

| Command | Description |
|---------|-------------|
| `doey` | Smart launch — auto-attach, launch, or show project picker |
| `doey init` | Register current directory as a project |
| `doey list` | Show all projects with running/stopped status |
| `doey stop` | Stop the team for the current project |
| `doey update` | Pull latest changes and reinstall |
| `doey doctor` | Check installation health and prerequisites |
| `doey remove` | Unregister a project by name or current directory |
| `doey version` | Show version and installation info |
| `doey 4x3` | Launch with a custom grid layout |
| `doey --help` | Show all options |

---

## How It Works

<table>
<tr>
<td width="40" align="center"><strong>0</strong></td>
<td>You register your project: <code>doey init</code> (one time per project)</td>
</tr>
<tr>
<td align="center"><strong>1</strong></td>
<td>You run <code>doey</code> — it auto-launches or reattaches to an existing session</td>
</tr>
<tr>
<td align="center"><strong>2</strong></td>
<td>You tell the Manager what to do — <em>"Refactor all components to use the new design tokens"</em></td>
</tr>
<tr>
<td align="center"><strong>3</strong></td>
<td>The Manager analyzes the task and breaks it into independent, parallelizable subtasks</td>
</tr>
<tr>
<td align="center"><strong>4</strong></td>
<td>Each subtask is dispatched to an idle worker with a self-contained prompt</td>
</tr>
<tr>
<td align="center"><strong>5</strong></td>
<td>The Watchdog monitors workers and delivers inbox messages</td>
</tr>
<tr>
<td align="center"><strong>6</strong></td>
<td>The Manager tracks progress and reports back when everything is done</td>
</tr>
</table>

---

## Features

- **Parallel execution** — 10 workers running simultaneously, not sequentially
- **Smart orchestration** — Manager plans, delegates, and monitors without writing code itself
- **Always-on monitoring** — Watchdog tracks worker state and delivers inbox messages
- **Premium startup experience** — ASCII banner, step-by-step progress indicators, and a summary dashboard
- **Session manifest** — Project context written to `/tmp/doey/<project>/session.env` so all tools and agents share config
- **Project-aware** — Register projects, auto-attach to running sessions, interactive picker
- **Flexible grid** — Configure `COLSxROWS` to match your screen and workload
- **Message bus** — Workers, Manager, and Watchdog communicate through a lightweight file-based system
- **Slash commands** — Built-in `/doey-dispatch`, `/doey-monitor`, `/doey-team` and more
- **Zero config** — Install, init, launch. Works with any project.
- **Restartable** — Restart workers without killing the Manager with `/doey-restart-workers`
- **Human reservation** — Use `/doey-reserve` to permanently reserve a pane for human use

---

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| **Manager** | `0.0` | Plans tasks, delegates to workers, monitors progress. Never writes code. |
| **Watchdog** | `0.{cols}` | Monitors all worker panes. Delivers inbox messages. |
| **Workers** | All others | Standard Claude Code instances that do the actual implementation work. Status: READY, BUSY, FINISHED, or RESERVED. |

### Communication

| Channel | Mechanism |
|---------|-----------|
| Task dispatch | `tmux send-keys` / `tmux paste-buffer` |
| Progress monitoring | `tmux capture-pane` |
| Session manifest | `/tmp/doey/<project>/session.env` — shared config for all agents |
| Inter-pane messages | `/tmp/doey/<project>/messages/` |
| Broadcasts | `/tmp/doey/<project>/broadcasts/` |
| Status tracking | `/tmp/doey/<project>/status/` — READY, BUSY, FINISHED, RESERVED |

### Context Layer Model

Each agent's behavior is shaped by multiple context layers that merge at startup and runtime:

| # | Layer | Source | Affects |
|---|-------|--------|---------|
| 1 | Agent Definitions | `agents/*.md` | Manager, Watchdog |
| 2 | Settings | `~/.claude/settings*.json`, `.claude/settings*.json` | All |
| 3 | Hooks | `.claude/hooks/` (6 event hooks + utilities) | All |
| 4 | Skills/Commands | `commands/doey-*.md` | Manager primarily |
| 5 | Persistent Memory | `~/.claude/agent-memory/` | Manager |
| 6 | Environment Variables | `session.env`, tmux env | All |
| 7 | CLI Flags | `--agent`, `--model`, etc. | All |
| 8 | tmux Integration | Session config, pane detection | All |
| 9 | Runtime State | `status/`, `research/`, `reports/` | All |
| 10 | CLAUDE.md | Project root | All |

For complete documentation of each layer, see [Context Reference](docs/context-reference.md).

---

## Deep Dive

For comprehensive documentation of the system internals:

- **[Context Reference](docs/context-reference.md)** — Complete documentation of every context layer that influences Manager and Watchdog behavior: agent definitions, settings, hooks, skills, memory, environment variables, CLI flags, tmux integration, runtime state, and CLAUDE.md.
- **[Linux Server Guide](docs/linux-server.md)** — Deploying on headless Linux servers.
- **[Windows WSL2 Guide](docs/windows-wsl2.md)** — Running on Windows via WSL2.

---

## Configuration

The session manifest (`session.env`) and runtime directory are created automatically by `doey init`. For detailed documentation of the manifest variables, runtime directory structure, status hooks, and all system internals, see the [Context Reference](docs/context-reference.md).

---

## Grid Configurations

The grid argument to `doey` is a `COLSxROWS` specification. Two panes are always reserved (Manager + Watchdog):

| Grid | Panes | Workers | Best for |
|------|-------|---------|----------|
| `6x2` | 12 | 10 | **Default** — large refactors, codebase sweeps |
| `4x3` | 12 | 10 | Taller panes — better for reading output |
| `4x2` | 8 | 6 | Medium tasks, smaller screens |
| `3x2` | 6 | 4 | Quick parallel tasks |
| `8x1` | 8 | 6 | Single row — maximizes pane height |

---

<details>
<summary><strong>Slash Commands Reference</strong></summary>

Once installed, these commands are available in any Claude Code instance:

| Command | Description |
|---------|-------------|
| `/doey-dispatch` | Dispatch tasks to workers (primary send mechanism) |
| `/doey-delegate` | Delegate a task to a specific pane |
| `/doey-monitor` | Check status of all workers |
| `/doey-team` | View full team overview with statuses |
| `/doey-send` | Send a message to another pane |
| `/doey-broadcast` | Broadcast a message to all panes |
| `/doey-inbox` | Check incoming messages |
| `/doey-status` | Set or view pane statuses |
| `/doey-research` | Dispatch research task with guaranteed report-back |
| `/doey-stop` | Stop a specific worker |
| `/doey-stop-all` | Stop all workers gracefully |
| `/doey-restart-workers` | Restart all workers (keeps Manager alive) |
| `/doey-reinstall` | Reinstall from the repo without leaving Claude Code |
| `/doey-reserve` | Reserve a worker pane for human use |
| `/doey-watchdog-compact` | Load the compact Watchdog prompt |

</details>

<details>
<summary><strong>File Structure</strong></summary>

```
doey/
├── CLAUDE.md                    # Project-level context for Claude Code instances
├── install.sh                   # Installer
├── web-install.sh               # Web installer (curl | bash)
├── agents/
│   ├── doey-manager.md          # Manager agent → ~/.claude/agents/
│   ├── doey-watchdog.md         # Watchdog agent → ~/.claude/agents/
│   └── test-driver.md           # E2E test driver agent → ~/.claude/agents/
├── docs/
│   ├── context-reference.md     # Deep reference for agent context layers
│   ├── linux-server.md          # Linux server deployment guide
│   └── windows-wsl2.md          # Windows WSL2 installation guide
├── commands/                    # Slash commands → ~/.claude/commands/
│   ├── doey-broadcast.md
│   ├── doey-delegate.md
│   ├── doey-dispatch.md
│   ├── doey-inbox.md
│   ├── doey-monitor.md
│   ├── doey-reinstall.md
│   ├── doey-research.md
│   ├── doey-reserve.md
│   ├── doey-restart-workers.md
│   ├── doey-send.md
│   ├── doey-status.md
│   ├── doey-stop.md
│   ├── doey-stop-all.md
│   ├── doey-team.md
│   └── doey-watchdog-compact.md
└── shell/
    └── doey.sh                  # CLI launcher → ~/.local/bin/doey
```

</details>

<details>
<summary><strong>Environment Variables</strong></summary>

| Variable | Description |
|----------|-------------|
| `DOEY_RUNTIME` | Path to the session runtime directory (set as tmux environment variable). Contains `session.env` manifest, messages, broadcasts, and status files. |

</details>

---

## Tips

**Shortcuts** — You can add shortcuts if you like:

```bash
alias doey4="doey 4x2"
alias doeys="doey 3x2"            # small team
```

**Project commands** — Copy the commands into your project for project-scoped access:

```bash
cp -r /path/to/doey/commands/ .claude/commands/
```

---

## Platform Guides

| Platform | Guide |
|----------|-------|
| **Windows** | [Windows Installation (WSL2)](docs/windows-wsl2.md) — full setup via WSL2 in 4 steps |
| **Linux Server** | [Linux Server Deployment](docs/linux-server.md) — headless SSH, cloud providers, systemd |

> Doey works on macOS out of the box. Windows and Linux require a few extra setup steps — see the guides above.

---

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [Node.js](https://nodejs.org/) v18+ (required by Claude Code)
- [tmux](https://github.com/tmux/tmux) (any recent version)
- macOS or Linux
- A terminal with a large window (the grid needs room)

---

## Contributing

Contributions are welcome! Open an issue or submit a PR.

This project is in active development — if you find bugs, have ideas for new slash commands, or want to improve the orchestration logic, jump in.

---

## Troubleshooting

<details>
<summary><strong>Workers show "Not logged in"</strong></summary>

Run `claude` manually in a regular terminal to authenticate first. The Watchdog will attempt auto-login but it's not always reliable.

</details>

<details>
<summary><strong>Terminal too small for grid</strong></summary>

Use a smaller grid like `doey 3x2` or maximize your terminal window. The default `6x2` grid needs approximately 200 columns to render properly.

</details>

<details>
<summary><strong><code>doey update</code> fails after web install</strong></summary>

The web installer's temporary directory was deleted after install. Fix: clone the repo manually, then run `./install.sh` to update the stored repo path:

```bash
git clone https://github.com/frikk-gyldendal/doey.git
cd doey && ./install.sh
```

</details>

<details>
<summary><strong>Workers get stuck</strong></summary>

The Manager can use `/doey-restart-workers` to kill and restart all workers without restarting itself. This is useful when workers become unresponsive or are in a bad state.

</details>

<details>
<summary><strong>macOS notifications not working</strong></summary>

Check System Preferences > Notifications and ensure your terminal app is allowed to send notifications. On Linux, notifications are not supported (the notification system uses macOS-only `osascript`).

</details>

<details>
<summary><strong><code>doey</code> command not found</strong></summary>

Add `~/.local/bin` to your PATH by adding this line to your shell config (`~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then restart your shell or run `source ~/.zshrc`.

</details>

<details>
<summary><strong><code>doey doctor</code> reports issues</strong></summary>

Run `doey doctor` and follow the suggestions it provides. It checks tmux, Claude CLI, PATH configuration, agents, commands, and repo path. Most issues can be fixed by re-running `./install.sh`.

</details>

---

## License

[MIT](LICENSE)

---

<div align="center">

**Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code)**

If you find this useful, [give it a star](https://github.com/frikk-gyldendal/doey) — it helps others find it.

</div>
