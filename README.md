<div align="center">

<img width="361" height="341" alt="image" src="https://github.com/user-attachments/assets/15356424-a33a-4cee-95c4-4973b7e9620a" />


<h3>Let me Doey for you</h3>

<p><em>Run parallel Claude Code agents in one terminal</em></p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-CLI-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![tmux](https://img.shields.io/badge/tmux-powered-green)](https://github.com/tmux/tmux)

</div>

```
┌──────────────┬──────────────┬──────────────┐
│ SUBTASKMASTER│  Worker 1    │  Worker 3    │
│  plans &     │  ┌─agent─┐   │  ┌─agent─┐   │  scales →
│  delegates   │  │ ↓ ↓ ↓ │   │  │ ↓ ↓ ↓ │   │
├──────────────┼──────────────┼──────────────┤
│              │  Worker 2    │  Worker 4    │  workers spawn
│              │  ┌─agent─┐   │  ┌─agent─┐   │  their own agents
│              │  │ ↓ ↓ ↓ │   │  │ ↓ ↓ ↓ │   │
└──────────────┴──────────────┴──────────────┘
 Boss relays user intent from Dashboard (window 0)
```

Subtaskmaster plans, workers execute in parallel. Dynamic grid — scale with `doey add`.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

# Launch (first time: project picker → "init"; after that: auto-launches)
cd ~/your-project && doey
```

Or: `git clone https://github.com/FRIKKern/doey.git && cd doey && ./install.sh`

> [Linux server](docs/linux-server.md) · [Windows WSL2](docs/windows-wsl2.md) · [Linode VPS](docs/linode-setup.md)

Tell the Boss your task — teams plan and execute in parallel, results are consolidated.

## CLI Commands

| Command | Description |
|---------|-------------|
| `doey` | Smart launch — attach, launch, or project picker |
| `doey init` | Register current directory as a project |
| `doey add` / `remove` | Add/remove worker columns |
| `doey stop` | Stop the team |
| `doey reload` | Hot-reload (Subtaskmaster; `--workers` for all) |
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

Window 0 is the dashboard; window 1 is the Core Team; team windows (2+) each have a Subtaskmaster + Workers.

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard (shell script). User lands here on attach |
| Boss | `0.1` | User-facing Project Manager. Receives user intent, manages tasks, reports results |
| Taskmaster | `C.0` | Sole executor/coordinator. Routes tasks, spawns teams, manages git, dispatches work |
| Task Reviewer | `C.1` | Reviews completed work for quality and correctness |
| Deployment | `C.2` | Handles deployment, CI/CD, and release operations |
| Doey Expert | `C.3` | Doey codebase specialist for self-improvement tasks |
| Subtaskmaster | `W.0` | Plans, delegates, validates all context. Never writes code |
| Workers | `W.1+` | Execute tasks. Skipped if reserved |
| Freelancers | `F.0+` | Independent workers, no Subtaskmaster |
| Test Driver | external | E2E test runner via `doey test` |

### Default Setup

Out of the box, `doey` launches:

```
Window 0 — Dashboard
  ├── Info Panel (live stats, tasks)
  └── Boss (user-facing Project Manager)

Window 1 — Core Team
  ├── Taskmaster (internal coordinator)
  ├── Task Reviewer
  ├── Deployment
  └── Doey Expert

Window 2 — Worker Team (local)
  ├── Subtaskmaster
  └── 6 Workers (3x2 dynamic grid)
```

Scale with `doey add` (columns) or `doey add-team` (teams). See [Context Reference](docs/context-reference.md).

## Configuration

All optional. Hierarchy (last wins): hardcoded defaults → `~/.config/doey/config.sh` → `<project>/.doey/config.sh`.

Per-project example:

```bash
mkdir -p .doey
cat > .doey/config.sh << 'EOF'
# Smaller team for a simple project
DOEY_INITIAL_WORKER_COLS=1
DOEY_INITIAL_TEAMS=0
DOEY_WORKER_MODEL=sonnet
EOF
```

<details>
<summary><strong>All config options</strong></summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `DOEY_INITIAL_WORKER_COLS` | `3` | Worker columns per team (workers = cols x 2) |
| `DOEY_INITIAL_TEAMS` | `0` | Extra team windows at startup |
| `DOEY_INITIAL_FREELANCER_TEAMS` | `0` | Freelancer pools (no Subtaskmaster) |
| `DOEY_INITIAL_WORKTREE_TEAMS` | `0` | Teams on isolated git branches |
| `DOEY_MAX_WORKERS` | `20` | Max worker panes across all teams |
| `DOEY_MANAGER_MODEL` | `opus` | Model for Subtaskmasters |
| `DOEY_WORKER_MODEL` | `opus` | Model for Workers |
| `DOEY_WORKER_LAUNCH_DELAY` | `1` | Seconds between worker launches (auth stagger) |
| `DOEY_TEAM_LAUNCH_DELAY` | `2` | Seconds between team launches |

**Advanced: named teams** — define teams with specific roles, models, and types:

```bash
DOEY_TEAM_COUNT=2
DOEY_TEAM_1_TYPE=local
DOEY_TEAM_1_WORKERS=6
DOEY_TEAM_1_NAME="Backend"
DOEY_TEAM_1_ROLE=backend

DOEY_TEAM_2_TYPE=worktree
DOEY_TEAM_2_WORKERS=4
DOEY_TEAM_2_NAME="Frontend"
DOEY_TEAM_2_WORKER_MODEL=sonnet
```

</details>

### Interactive Settings

`/doey-settings` or the **Settings** button opens a split-screen editor with live config values.

## Task Tracking

Built-in task system — tasks show on the dashboard.

```
/doey-task add Implement the auth system    # create a task
/doey-task list                              # see all tasks
/doey-task done 1                            # mark complete (user confirms)
```

| Status | Meaning |
|--------|---------|
| `active` | In progress |
| `pending` | Work done — awaiting your sign-off |
| `done` | You confirmed it's complete |
| `cancelled` | Dropped |

Workers can mark tasks `pending` but only **you** mark them `done`.

## Debug Mode

```
/doey-debug on       # start flight recorder
/doey-debug status   # see captured events
/doey-debug off      # stop (logs preserved for post-mortem)
```

Structured JSONL: hooks, state, lifecycle, IPC. Zero overhead when off.

```bash
cat /tmp/doey/*/debug/*/hooks.jsonl | sort -t'"' -k4   # view chronologically
```

<details>
<summary><strong>Slash Commands</strong></summary>

**Planning:** `/doey-masterplan`, `/doey-create-task`, `/doey-instant-task`, `/doey-planned-task`
**Tasks:** `/doey-task`, `/doey-dispatch`, `/doey-delegate`, `/doey-research`, `/doey-broadcast`
**Monitor:** `/doey-monitor`, `/doey-status`, `/doey-taskmaster-compact`, `/doey-nudge`, `/doey-debug`
**Infra:** `/doey-add-window`, `/doey-add-team`, `/doey-kill-window`, `/doey-list-windows`, `/doey-worktree`
**Lifecycle:** `/doey-stop`, `/doey-clear`, `/doey-reload`, `/doey-reinstall`, `/doey-reserve`, `/doey-repair`, `/doey-purge`, `/doey-login`, `/doey-reset`, `/doey-simplify-everything`
**Config:** `/doey-settings`
**Session:** `/doey-kill-session`, `/doey-kill-all-sessions`
**R&D:** `/doey-rd-team`

</details>

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Workers "Not logged in" | Run `claude` first to authenticate |
| Terminal too small | `doey 3x2` or maximize |
| `doey` not found | Add `~/.local/bin` to PATH |
| Workers stuck | `/doey-clear workers` |
| `doey update` fails | `git clone ... && ./install.sh` |
| Other | `doey doctor` |

## Requirements

[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (authenticated) · [Node.js](https://nodejs.org/) v18+ · [tmux](https://github.com/tmux/tmux) · macOS or Linux

> Missing tmux or Claude Code? `doey` / `./install.sh` will detect and offer to install.

---

Contributions welcome — [open an issue](https://github.com/FRIKKern/doey/issues) or PR. Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
