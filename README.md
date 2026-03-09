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

**One command — no clone needed:**

```bash
curl -fsSL https://raw.githubusercontent.com/frikk-gyldendal/claude-code-tmux-team/main/web-install.sh | bash
```

**Or clone and install locally:**

```bash
git clone https://github.com/frikk-gyldendal/claude-code-tmux-team.git
cd claude-code-tmux-team && ./install.sh
```

**Then launch from any project directory:**

```bash
claude-team       # default 6x2 grid (10 workers)
```

That's it. The Manager boots up, workers come online, and you're asked what to work on.

```bash
claude-team 4x3      # custom grid layout
claude-team 3x2      # smaller team (4 workers)
claude-team --help   # all options
```

---

<!-- TODO: Add a GIF/video demo here -->
<!-- ## Demo -->
<!-- ![Claude Team in action](demo.gif) -->

---

## How It Works

<table>
<tr>
<td width="40" align="center"><strong>1</strong></td>
<td>You tell the Manager what to do — <em>"Refactor all components to use the new design tokens"</em></td>
</tr>
<tr>
<td align="center"><strong>2</strong></td>
<td>The Manager analyzes the task and breaks it into independent, parallelizable subtasks</td>
</tr>
<tr>
<td align="center"><strong>3</strong></td>
<td>Each subtask is dispatched to an idle worker with a self-contained prompt</td>
</tr>
<tr>
<td align="center"><strong>4</strong></td>
<td>The Watchdog monitors workers and auto-accepts permission prompts to keep them unblocked</td>
</tr>
<tr>
<td align="center"><strong>5</strong></td>
<td>The Manager tracks progress and reports back when everything is done</td>
</tr>
</table>

---

## Features

- **Parallel execution** — 10 workers running simultaneously, not sequentially
- **Smart orchestration** — Manager plans, delegates, and monitors without writing code itself
- **Auto-unblocking** — Watchdog handles `y/n` prompts, permission dialogs, and confirmations
- **Flexible grid** — Configure `COLSxROWS` to match your screen and workload
- **Message bus** — Workers, Manager, and Watchdog communicate through a lightweight file-based system
- **Slash commands** — Built-in `/tmux-dispatch`, `/tmux-monitor`, `/tmux-team` and more
- **Zero config** — Clone, install, launch. Works with any project.
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
| Inter-pane messages | `/tmp/claude-team/messages/` |
| Broadcasts | `/tmp/claude-team/broadcasts/` |
| Status tracking | `/tmp/claude-team/status/` |

---

## Grid Configurations

The argument to `claude-team` is a `COLSxROWS` specification. Two panes are always reserved (Manager + Watchdog):

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
| `/tmux-restart-workers` | Restart all workers (keeps Manager alive) |

</details>

<details>
<summary><strong>File Structure</strong></summary>

```
claude-code-tmux-team/
├── install.sh                   # Installer
├── agents/
│   ├── tmux-manager.md          # Manager agent definition → ~/.claude/agents/
│   └── tmux-watchdog.md         # Watchdog agent definition → ~/.claude/agents/
├── skills/                      # User-level slash commands → ~/.claude/skills/
│   ├── tmux-dispatch.md
│   ├── tmux-delegate.md
│   ├── tmux-monitor.md
│   ├── tmux-restart-workers.md
│   ├── tmux-manager-prompt.md
│   ├── tmux-runner-prompt.md
│   ├── tmux-team.md
│   ├── tmux-send.md
│   ├── tmux-broadcast.md
│   ├── tmux-inbox.md
│   └── tmux-status.md
├── commands/                    # Project-level commands → .claude/commands/
│   └── (same tmux-*.md files)
└── shell/
    └── claude-team.sh           # Shell function that launches the session
```

</details>

<details>
<summary><strong>Environment Variables</strong></summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_TEAM_DIR` | `$PWD` | Working directory for the session |
| `CLAUDE_TEAM_NAME` | `claude-team` | tmux session name |

</details>

---

## Tips

**Aliases** — Add these to your shell config for quick access:

```bash
alias ct="claude-team"
alias ct4="claude-team 4x2"
alias cts="claude-team 3x2"   # small team
```

**Project commands** — Copy the commands into your project for project-scoped access:

```bash
cp -r /path/to/claude-code-tmux-team/commands/ .claude/commands/
```

---

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [tmux](https://github.com/tmux/tmux) (any recent version)
- macOS or Linux
- A terminal with a large window (the grid needs room)

---

## Contributing

Contributions are welcome! Open an issue or submit a PR.

This project is in active development — if you find bugs, have ideas for new slash commands, or want to improve the orchestration logic, jump in.

---

## License

[MIT](LICENSE)

---

<div align="center">

**Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code)**

If you find this useful, [give it a star](https://github.com/frikk-gyldendal/claude-code-tmux-team) — it helps others find it.

</div>
