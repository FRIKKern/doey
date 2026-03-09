# 🧠 TMUX Claude Team

**Multi-agent orchestration for Claude Code using tmux**

Run a team of parallel Claude Code instances with a Manager, Watchdog, and Workers — all coordinated through tmux.

```
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ 0.0      │ 0.1      │ 0.2      │ 0.3      │ 0.4      │ 0.5      │
│ MANAGER  │ Worker 1 │ Worker 2 │ Worker 3 │ Worker 4 │ Worker 5 │
├──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤
│ 0.6      │ 0.7      │ 0.8      │ 0.9      │ 0.10     │ 0.11     │
│ WATCHDOG │ Worker 6 │ Worker 7 │ Worker 8 │ Worker 9 │ Worker10 │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
```

## Highlights

- **Multi-agent coordination** — Manager plans, Workers execute, Watchdog keeps things moving
- **Flexible grid layouts** — from `3x2` to `8x1`, scale to match the task
- **Premium startup experience** with ASCII banner, progress indicators, and a summary dashboard
- **Prerequisite validation** during install — catches missing dependencies early
- **Slash command toolkit** — dispatch, monitor, broadcast, and more from any Claude Code instance

## ⚡ Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/claude-code-tmux-team.git
cd claude-code-tmux-team
./install.sh
```

The installer validates prerequisites automatically (Claude Code CLI, tmux, shell config) and provides clear feedback with colored output.

After installation, source your shell or restart your terminal:

```bash
source ~/.zshrc   # or ~/.bashrc
```

Then launch a team in any project:

```bash
cd /path/to/your/project
claude-team        # default 6x2 grid (10 workers)
claude-team 4x3    # custom grid (10 workers)
claude-team 8x1    # single row (6 workers)
```

## 🚀 What You'll See

When you run `claude-team`, the startup sequence gives you full visibility into what's happening:

1. **ASCII art banner** with your session configuration (grid size, worker count, working directory)
2. **Step-by-step progress** — each phase (grid creation, pane setup, agent launches) shows a checkmark as it completes
3. **Workers boot in ~15 seconds** — Claude Code instances launch in parallel across the grid
4. **Summary box** — a formatted dashboard confirms the session is ready, showing the grid layout and pane assignments

Once the summary appears, switch to the Manager pane (`0.0`) and start giving it tasks.

## 🏗️ How It Works

The system has three roles:

| Role | Pane | What it does |
|------|------|-------------|
| **🧠 Manager** | `0.0` | Plans tasks, delegates to workers, monitors progress, reports results. **Never writes code.** |
| **🐕 Watchdog** | `0.{cols}` | Continuously monitors all worker panes and auto-accepts y/n prompts, confirmations, and permission requests. |
| **👷 Workers** | All others | Standard Claude Code instances that do the actual implementation work. |

### The Flow

1. You tell the Manager what to do (e.g., "Refactor all components to use the new design system")
2. The Manager analyzes the task and breaks it into independent subtasks
3. Each subtask is dispatched to an idle worker with a self-contained prompt
4. The Watchdog keeps workers unblocked by auto-accepting prompts
5. The Manager monitors progress and reports back when everything is done

### Communication

- **Task dispatch**: Manager sends prompts to workers via `tmux send-keys` / `tmux paste-buffer`
- **Progress monitoring**: Manager captures worker output via `tmux capture-pane`
- **Message bus**: `/tmp/claude-team/` holds inter-pane messages, broadcasts, and status files
- **Slash commands**: Skills like `/tmux-dispatch`, `/tmux-monitor`, `/tmux-team` provide structured operations

## 📁 File Structure

```
claude-code-tmux-team/
├── README.md                    # This file
├── install.sh                   # One-command installer
├── agents/
│   ├── tmux-manager.md          # Manager agent definition (~/.claude/agents/)
│   └── tmux-watchdog.md         # Watchdog agent definition (~/.claude/agents/)
├── skills/                      # User-level slash commands (~/.claude/skills/)
│   ├── tmux-dispatch.md         # Send tasks to workers reliably
│   ├── tmux-delegate.md         # Delegate a task to a specific pane
│   ├── tmux-monitor.md          # Smart worker status monitoring
│   ├── tmux-restart-workers.md  # Restart all workers without restarting Manager
│   ├── tmux-manager-prompt.md   # Manager system prompt reference
│   ├── tmux-runner-prompt.md    # Watchdog/Runner system prompt reference
│   ├── tmux-team.md             # View full team overview
│   ├── tmux-send.md             # Send a message to another pane
│   ├── tmux-broadcast.md        # Broadcast to all panes
│   ├── tmux-inbox.md            # Check incoming messages
│   └── tmux-status.md           # Set/view pane statuses
├── commands/                    # Project-level commands (.claude/commands/)
│   └── (same tmux-*.md files)   # Copy these into your project if desired
└── shell/
    └── claude-team.sh           # Shell function that launches the tmux session
```

## ⚙️ Configuration

### Grid Sizes

The argument to `claude-team` is a `COLSxROWS` grid specification:

| Grid | Total Panes | Workers | Good for |
|------|------------|---------|----------|
| `6x2` | 12 | 10 | Default — large refactors, full codebase sweeps |
| `4x3` | 12 | 10 | Taller panes — better for reading output |
| `4x2` | 8 | 6 | Medium tasks, smaller screens |
| `3x2` | 6 | 4 | Quick parallel tasks |
| `8x1` | 8 | 6 | Single row — maximizes pane height |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_TEAM_DIR` | `$PWD` | Working directory for the session |
| `CLAUDE_TEAM_NAME` | `claude-team` | tmux session name |

### Aliases

Add to your shell config:
```bash
alias ct="claude-team"
alias ct4="claude-team 4x2"
```

## 🎯 Available Slash Commands

Once installed, these commands are available in any Claude Code instance:

| Command | Description |
|---------|-------------|
| `/tmux-dispatch` | Dispatch tasks to workers (primary send primitive) |
| `/tmux-delegate` | Delegate a task to a specific pane |
| `/tmux-monitor` | Check status of all workers |
| `/tmux-team` | View full team overview with statuses |
| `/tmux-send` | Send a message to another pane |
| `/tmux-broadcast` | Broadcast a message to all panes |
| `/tmux-inbox` | Check incoming messages |
| `/tmux-status` | Set or view pane statuses |
| `/tmux-restart-workers` | Restart all workers (keeps Manager alive) |

## 🔧 Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [tmux](https://github.com/tmux/tmux) (any recent version)
- macOS or Linux
- A terminal emulator with a large window (the grid needs space!)

## 📸 Screenshots

> Run `claude-team` to see the premium startup experience in action. Screenshots coming soon.

## 📄 License

MIT
