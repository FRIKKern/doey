# CLAUDE.md

## Overview

Doey: CLI tool creating tmux-based multi-agent Claude Code teams. Dynamic grid (default 3 cols = 6 workers, auto-expands). CLI entry: `doey`. Human reservation via `/doey-reserve`.

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard (shell script). User lands here on attach. |
| Session Manager | `0.1` | Routes tasks between team windows. Present when multiple teams exist. |
| Watchdog | `0.2-0.7` | One per team. Monitors workers, catches crashes. |
| Window Manager | `W.0` | Per-window orchestrator. Plans/delegates, never writes code. |
| Workers | `W.1+` | Execute tasks. Skipped if reserved. |
| Test Driver | external | E2E test runner via `doey test`. |

Runtime: `/tmp/doey/<project>/`. Context layers: `docs/context-reference.md`.

### Tool Restrictions (via `on-pre-tool-use.sh`)

| Role | Blocked |
|------|---------|
| Window Manager | None (full access) |
| Watchdog | Edit, Write, Agent, NotebookEdit; send-keys limited; no git push/commit, gh pr create/merge, destructive rm, shutdown, tmux kill |
| Workers | git push/commit, gh pr create/merge, ALL send-keys, tmux kill, rm -rf ~/$HOME, shutdown |

## Key Directories

| Dir | Purpose | Installs to |
|-----|---------|-------------|
| `agents/` | Agent definitions | `~/.claude/agents/` |
| `commands/` | Slash commands | `~/.claude/commands/` |
| `.claude/hooks/` | Event hooks | (in-repo) |
| `shell/` | Launcher & utils | `~/.local/bin/` |
| `docs/` | Guides & context ref | — |

Grid management: `doey add`/`doey remove` scale columns at runtime.

## Conventions

- Agents: YAML frontmatter (name, model, color, memory, description)
- Commands: `# Skill: name` + `## Usage` + `## Prompt`
- Hook exits: 0=allow, 1=block+error, 2=block+feedback
- Shell: `set -euo pipefail`, bash 3.2 compatible. Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `[[ =~` capture groups.
- Naming: sessions `doey-<project>`, runtime `/tmp/doey/<project>/`

## Testing Changes

| Changed | Action |
|---------|--------|
| Agents | Restart Manager or Watchdog |
| Hooks | Restart ALL workers (loaded at startup) |
| Commands | No restart (on-demand) |
| Launcher/shell | `doey reload` or `doey stop && doey` |
| Shell scripts | Run `tests/test-bash-compat.sh` |

Live reload: `doey reload` (Manager+Watchdog), `doey reload --workers` (all).

## Important Files

| File | Purpose |
|------|---------|
| `shell/doey.sh` | Main CLI launcher |
| `shell/info-panel.sh` | Window 0 dashboard |
| `shell/context-audit.sh` | Context pattern auditor |
| `.claude/hooks/common.sh` | Shared utils: `init_hook()`, `parse_field()`, `load_team_env()`, role checks, `send_notification()` |
| `.claude/hooks/on-session-start.sh` | Sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX |
| `.claude/hooks/on-prompt-submit.sh` | BUSY status, READY on /compact, column expansion |
| `.claude/hooks/on-pre-tool-use.sh` | Tool usage safety guards |
| `.claude/hooks/on-pre-compact.sh` | Context preservation before compaction |
| `.claude/hooks/post-tool-lint.sh` | Bash 3.2 compatibility lint |
| `.claude/hooks/stop-status.sh` | FINISHED/RESERVED status, research enforcement |
| `.claude/hooks/stop-results.sh` | Result JSON and completion events |
| `.claude/hooks/stop-notify.sh` | Session Manager notifications |
| `.claude/hooks/watchdog-scan.sh` | Pane state detection, heartbeat |
