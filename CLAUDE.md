# CLAUDE.md

## Overview

Doey: CLI tool creating tmux-based multi-agent Claude Code teams. Dynamic grid (default) starts 1 col, auto-expands. Static grid default: 3x2 (5 workers + manager). CLI entry: `doey`. Human reservation via `/doey-reserve`.

## Philosophy

Doey optimizes for **strategic utilization of Claude**, not brute-force parallelism. Smaller teams used well outperform larger teams used carelessly.

**The Manager is the bastion between agents and bad context.** Workers produce raw output — the Manager validates, distills, and decides what becomes knowledge. Nothing enters the golden context log unchallenged. If a finding doesn't smell right, another worker verifies it.

**Workers feed managers.** Workers are the most shapeable, most disposable-context role. They are never dispatched without intent — every worker task is crafted to produce HIGH QUALITY content that flows back to the Manager. The manager-worker hierarchy exists so managers can orchestrate deep, focused work.

**Force multipliers over headcount:**
- **ultrathink** — Deep reasoning for complex problems
- **`/batch`** — Efficient bulk operations across files
- **`/doey-simplify-everything`** — Quality sweeps after multi-team edits
- **`/doey-research`** — Investigation before implementation
- **Agent swarm** — Workers spawning their own agents for complex exploration

Default to fewer, well-utilized workers. Scale up only when parallelism genuinely helps.

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard (shell script). User lands here on attach. |
| Session Manager | `0.1` | Routes tasks between team windows. Present when multiple teams exist. |
| Watchdog | `0.2+` | Manager's best friend. Obsessively monitors every hook event, filters noise, escalates signal. |
| Window Manager | `W.0` | The bastion. Plans/delegates, validates all context, never writes code. |
| Workers | `W.1+` | Execute tasks. Skipped if reserved. |
| Test Driver | external | E2E test runner via `doey test`. |

Runtime: `/tmp/doey/<project>/`. Context layers: `docs/context-reference.md`.

### Tool Restrictions (via `on-pre-tool-use.sh`)

| Role | Blocked |
|------|---------|
| Window Manager | None (full access) |
| Watchdog | Edit, Write, Agent, NotebookEdit; send-keys limited; no git push/commit, gh pr create/merge, destructive rm, shutdown, tmux kill |
| Workers | git push/commit, gh pr create/merge, ALL send-keys, tmux kill, rm -rf /, ~, $HOME, shutdown |

## Key Directories

| Dir | Purpose | Installs to |
|-----|---------|-------------|
| `agents/` | Agent definitions | `~/.claude/agents/` |
| `.claude/skills/` | Slash commands (skills) | (in-repo) |
| `.claude/hooks/` | Event hooks | (in-repo) |
| `shell/` | Launcher & utils | `~/.local/bin/` |
| `docs/` | Guides & context ref | — |

## Conventions

- Agents: YAML frontmatter (name, model, color, memory, description)
- Skills: YAML frontmatter (name, description) in `.claude/skills/<name>/SKILL.md`
- Hook exits: 0=allow, 1=block+error, 2=block+feedback
- Shell: `set -euo pipefail`, bash 3.2 compatible. Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `BASH_REMATCH` capture groups (`[[ =~` itself is allowed).
- Naming: sessions `doey-<project>`, runtime `/tmp/doey/<project>/`

## Testing Changes

| Changed | Action |
|---------|--------|
| Agents | Restart Manager or Watchdog |
| Hooks | Restart ALL workers (loaded at startup) |
| Skills | No restart (on-demand) |
| Launcher/shell | `doey reload` or `doey stop && doey` |
| Shell scripts | Run `tests/test-bash-compat.sh` |

Live reload: `doey reload` (Manager+Watchdog), `doey reload --workers` (all).

## Important Files

**Shell:** `shell/doey.sh` (CLI launcher), `shell/info-panel.sh` (dashboard), `shell/context-audit.sh` (context auditor), `shell/pane-border-status.sh` (pane borders), `shell/tmux-statusbar.sh` (status bar)

**Hooks** (`.claude/hooks/`):

| File | Purpose |
|------|---------|
| `common.sh` | Shared utils: `init_hook()`, `parse_field()`, `_read_team_key()`, role checks, `send_notification()` |
| `on-session-start.sh` | Sets DOEY_* env vars (ROLE, PANE_INDEX, WINDOW_INDEX, TEAM_WINDOW, TEAM_DIR, RUNTIME) plus SESSION_NAME, PROJECT_DIR, PROJECT_NAME |
| `on-prompt-submit.sh` | BUSY status, READY on /compact, collapsed column restore |
| `on-pre-tool-use.sh` | Tool usage safety guards |
| `on-pre-compact.sh` | Context preservation before compaction |
| `post-tool-lint.sh` | Bash 3.2 compatibility lint |
| `stop-status.sh` | FINISHED/RESERVED status, research enforcement |
| `stop-results.sh` | Result JSON and completion events |
| `stop-notify.sh` | Unified stop notifications: Worker→Manager, Manager→Session Manager, Session Manager→desktop |
| `watchdog-scan.sh` | Pane state detection, heartbeat |
| `watchdog-wait.sh` | Watchdog sleep/wake between scan cycles |
| `session-manager-wait.sh` | Session Manager sleep/wake between cycles |
