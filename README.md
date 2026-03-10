<div align="center">

# Claude Code TMUX Team

**Run 10 Claude Code agents in parallel. One terminal.**

Orchestrate a fleet of AI coding agents with a Manager that plans, Workers that execute,<br>and a Watchdog that keeps everything running — all inside tmux.

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

TMUX Claude Team launches **10 Claude Code instances in parallel**, coordinated by a Manager agent that breaks your task into subtasks, dispatches them to idle workers, and monitors progress — all in a single tmux session.

You talk to the Manager. The Manager runs the team. You ship 10x faster.

---

## Quick Start

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/frikk-gyldendal/claude-code-tmux-team/main/web-install.sh | bash
```

Or clone and install locally:

```bash
git clone https://github.com/frikk-gyldendal/claude-code-tmux-team.git
cd claude-code-tmux-team && ./install.sh
```

The installer validates prerequisites automatically (Claude Code CLI, tmux, shell config) and provides clear feedback with colored output.

> **Other platforms:** For Linux server deployment, see [docs/linux-server.md](docs/linux-server.md). For Windows (WSL2), see [docs/windows-wsl2.md](docs/windows-wsl2.md).

**Launch:**

```bash
cd ~/your-project
ct                     # first time: shows project picker, choose "init"
ct                     # next time: auto-launches your team
```

That's it. No config files. No shell reload. Just `ct` (or `claude-team` — both work).

> `ct` is installed automatically as a symlink to `claude-team`. No alias setup needed.

---

## What You'll See

When you run `ct` (or `claude-team`), the startup sequence gives you full visibility into what's happening:

1. **ASCII art banner** with your session configuration (grid size, worker count, working directory)
2. **Step-by-step progress** — each phase (grid creation, pane setup, agent launches) shows a checkmark as it completes
3. **Workers boot in ~15 seconds** — Claude Code instances launch in parallel across the grid
4. **Summary dashboard** — a formatted box confirms the session is ready, showing the grid layout and pane assignments

Once the summary appears, switch to the Manager pane (`0.0`) and start giving it tasks.

> Run `ct` to see the premium startup experience.

---

## Commands

> `ct` is a built-in shorthand for `claude-team` — installed automatically as a symlink.

| Command | Description |
|---------|-------------|
| `ct` | Smart launch — auto-attach, launch, or show project picker |
| `ct init` | Register current directory as a project |
| `ct list` | Show all projects with running/stopped status |
| `ct stop` | Stop the team for the current project |
| `ct update` | Pull latest changes and reinstall |
| `ct doctor` | Check installation health and prerequisites |
| `ct remove` | Unregister a project by name or current directory |
| `ct version` | Show version and installation info |
| `ct 4x3` | Launch with a custom grid layout |
| `ct --help` | Show all options |

---

## How It Works

<table>
<tr>
<td width="40" align="center"><strong>0</strong></td>
<td>You register your project: <code>ct init</code> (one time per project)</td>
</tr>
<tr>
<td align="center"><strong>1</strong></td>
<td>You run <code>ct</code> — it auto-launches or reattaches to an existing session</td>
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
<td>The Watchdog monitors workers and auto-accepts permission prompts to keep them unblocked</td>
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
- **Auto-unblocking** — Watchdog handles `y/n` prompts, permission dialogs, and confirmations
- **Premium startup experience** — ASCII banner, step-by-step progress indicators, and a summary dashboard
- **Session manifest** — Project context written to `/tmp/claude-team/<project>/session.env` so all tools and agents share config
- **Project-aware** — Register projects, auto-attach to running sessions, interactive picker
- **Flexible grid** — Configure `COLSxROWS` to match your screen and workload
- **Message bus** — Workers, Manager, and Watchdog communicate through a lightweight file-based system
- **Slash commands** — Built-in `/tmux-dispatch`, `/tmux-monitor`, `/tmux-team` and more
- **Zero config** — Install, init, launch. Works with any project.
- **Restartable** — Restart workers without killing the Manager with `/tmux-restart-workers`

---

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| **Manager** | `0.0` | Plans tasks, delegates to workers, monitors progress. Never writes code. |
| **Watchdog** | `0.{cols}` | Monitors all worker panes. Auto-accepts prompts and confirmations. |
| **Workers** | All others | Standard Claude Code instances that do the actual implementation work. |

### Communication

| Channel | Mechanism |
|---------|-----------|
| Task dispatch | `tmux send-keys` / `tmux paste-buffer` |
| Progress monitoring | `tmux capture-pane` |
| Session manifest | `/tmp/claude-team/<project>/session.env` — shared config for all agents |
| Inter-pane messages | `/tmp/claude-team/<project>/messages/` |
| Broadcasts | `/tmp/claude-team/<project>/broadcasts/` |
| Status tracking | `/tmp/claude-team/<project>/status/` |

---

## Configuration

### Session Manifest

Each session creates a manifest at `/tmp/claude-team/<project>/session.env` with session metadata. All agents and slash commands read from this file to stay in sync.

| Variable | Description |
|----------|-------------|
| `PROJECT_DIR` | Absolute path to the project directory |
| `SESSION_NAME` | tmux session name |
| `WORKER_PANES` | Space-separated list of worker pane indices |
| `WATCHDOG_PANE` | Pane index of the Watchdog |
| `GRID` | Grid specification (e.g. `6x2`) |
| `WORKER_COUNT` | Number of worker panes |

### Runtime Directory Structure

All runtime data lives under `/tmp/claude-team/<project>/`:

```
/tmp/claude-team/<project>/
├── session.env        # Session manifest
├── messages/          # Inter-pane messages
├── broadcasts/        # Broadcast messages
├── status/            # Per-pane status files (WORKING/IDLE)
├── research/          # Research task markers
└── reports/           # Research reports
```

### Project Registry

Registered projects are stored in `~/.claude/claude-team/projects` as `name:path` entries (one per line). This file is managed by `ct init` and `ct remove`.

### Status Hooks

The repo includes `.claude/hooks/status-hook.sh` and `.claude/settings.local.json` which enable automatic WORKING/IDLE status tracking. The hook fires on `UserPromptSubmit` (marks the pane as WORKING) and `Stop` (marks it as IDLE), writing status files to the runtime directory. This powers `/tmux-monitor` and `/tmux-team` real-time worker state display.

To use status hooks in your own project, copy the hook files from the repo:

```bash
cp -r /path/to/claude-code-tmux-team/.claude/hooks/ your-project/.claude/hooks/
cp /path/to/claude-code-tmux-team/.claude/settings.local.json your-project/.claude/settings.local.json
```

---

## Grid Configurations

The grid argument to `ct` (or `claude-team`) is a `COLSxROWS` specification. Two panes are always reserved (Manager + Watchdog):

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
| `/tmux-dispatch` | Dispatch tasks to workers (primary send mechanism) |
| `/tmux-delegate` | Delegate a task to a specific pane |
| `/tmux-monitor` | Check status of all workers |
| `/tmux-team` | View full team overview with statuses |
| `/tmux-send` | Send a message to another pane |
| `/tmux-broadcast` | Broadcast a message to all panes |
| `/tmux-inbox` | Check incoming messages |
| `/tmux-status` | Set or view pane statuses |
| `/tmux-stop-all` | Stop all workers gracefully |
| `/tmux-restart-workers` | Restart all workers (keeps Manager alive) |
| `/tmux-reinstall` | Reinstall from the repo without leaving Claude Code |
| `/tmux-manager-prompt` | Load the Manager system prompt |
| `/tmux-runner-prompt` | Load the Runner/Worker system prompt |
| `/tmux-watchdog-compact` | Load the compact Watchdog prompt |

</details>

<details>
<summary><strong>File Structure</strong></summary>

```
claude-code-tmux-team/
├── install.sh                   # Installer
├── web-install.sh               # Web installer (curl | bash)
├── agents/
│   ├── tmux-manager.md          # Manager agent → ~/.claude/agents/
│   └── tmux-watchdog.md         # Watchdog agent → ~/.claude/agents/
├── commands/                    # Slash commands → ~/.claude/commands/
│   ├── tmux-broadcast.md
│   ├── tmux-delegate.md
│   ├── tmux-dispatch.md
│   ├── tmux-inbox.md
│   ├── tmux-manager-prompt.md
│   ├── tmux-monitor.md
│   ├── tmux-reinstall.md
│   ├── tmux-restart-workers.md
│   ├── tmux-runner-prompt.md
│   ├── tmux-send.md
│   ├── tmux-status.md
│   ├── tmux-stop-all.md
│   ├── tmux-team.md
│   └── tmux-watchdog-compact.md
└── shell/
    └── claude-team.sh           # CLI launcher → ~/.local/bin/claude-team (+ ct symlink)
```

</details>

<details>
<summary><strong>Environment Variables</strong></summary>

| Variable | Description |
|----------|-------------|
| `CLAUDE_TEAM_RUNTIME` | Path to the session runtime directory (set as tmux environment variable). Contains `session.env` manifest, messages, broadcasts, and status files. |

</details>

---

## Tips

**Shortcuts** — `ct` is installed automatically as a symlink — no alias needed. You can add more shortcuts if you like:

```bash
alias ct4="ct 4x2"
alias cts="ct 3x2"            # small team
```

**Project commands** — Copy the commands into your project for project-scoped access:

```bash
cp -r /path/to/claude-code-tmux-team/commands/ .claude/commands/
```

---

## Platform Guides

| Platform | Guide |
|----------|-------|
| **Windows** | [Windows Installation (WSL2)](docs/windows-wsl2.md) — full setup via WSL2 in 4 steps |
| **Linux Server** | [Linux Server Deployment](docs/linux-server.md) — headless SSH, cloud providers, systemd |

> Claude Team works on macOS out of the box. Windows and Linux require a few extra setup steps — see the guides above.

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

Use a smaller grid like `ct 3x2` or maximize your terminal window. The default `6x2` grid needs approximately 200 columns to render properly.

</details>

<details>
<summary><strong><code>ct update</code> fails after web install</strong></summary>

The web installer's temporary directory was deleted after install. Fix: clone the repo manually, then run `./install.sh` to update the stored repo path:

```bash
git clone https://github.com/frikk-gyldendal/claude-code-tmux-team.git
cd claude-code-tmux-team && ./install.sh
```

</details>

<details>
<summary><strong>Workers get stuck</strong></summary>

The Manager can use `/tmux-restart-workers` to kill and restart all workers without restarting itself. This is useful when workers become unresponsive or are in a bad state.

</details>

<details>
<summary><strong>macOS notifications not working</strong></summary>

Check System Preferences > Notifications and ensure your terminal app is allowed to send notifications. On Linux, notifications are not supported (the notification system uses macOS-only `osascript`).

</details>

<details>
<summary><strong><code>ct</code> / <code>claude-team</code> command not found</strong></summary>

Add `~/.local/bin` to your PATH by adding this line to your shell config (`~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then restart your shell or run `source ~/.zshrc`.

</details>

<details>
<summary><strong><code>ct doctor</code> reports issues</strong></summary>

Run `ct doctor` and follow the suggestions it provides. It checks tmux, Claude CLI, PATH configuration, agents, commands, and repo path. Most issues can be fixed by re-running `./install.sh`.

</details>

---

## License

[MIT](LICENSE)

---

<div align="center">

**Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code)**

If you find this useful, [give it a star](https://github.com/frikk-gyldendal/claude-code-tmux-team) — it helps others find it.

</div>
