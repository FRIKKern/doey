# CLAUDE.md

## What This Is

Doey is a CLI tool that creates tmux-based multi-agent Claude Code teams. A user runs `doey` in any project directory and gets a coordinated grid of Claude instances — a Manager that plans, Workers that execute, and a Watchdog that monitors. Dynamic grid by default: starts small, grows on demand. Entry point: `shell/doey.sh`, installed to `~/.local/bin/doey`.

## ALWAYS DO THESE THINGS

- **Think "fresh install"** — Every change must work for someone who just ran `curl | bash` to install Doey for the first time. If a feature depends on local state, config, or manual setup that isn't in the install path — it's broken
- **Ship in the repo, not in local files** — Changes to `~/.claude/settings.json`, `~/.claude/statusline-command.sh`, or other user-level files are LOCAL ONLY. They don't ship with Doey. If a feature needs those files, it must be set up by the install script or on-session-start hook
- **Test the install path** — After changing install.sh, doey.sh, or any `shell/` script: does `./install.sh` still produce a working install? Does `doey doctor` pass?
- **Don't assume your environment** — Our dev session has DOEY_* env vars, tmux, multiple teams. A user's first launch has none of that. Guard every assumption
- **Bash 3.2 compatible** — macOS ships `/bin/bash` 3.2. Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `BASH_REMATCH` capture groups. Run `tests/test-bash-compat.sh` after any `.sh` change
- **Bash tool commands must be zsh-safe** — The Bash tool runs in the user's login shell, which is zsh on macOS. Patterns that break: `for f in *.ext 2>/dev/null` (zsh parse error on glob redirect), unquoted globs that fail with `nomatch`. Fix: wrap bash-specific logic in `bash -c '...'`, or use `ls dir/ 2>/dev/null` instead of glob loops. Parallel Bash tool calls must not depend on glob success — one failure cancels siblings
- **One worker per file** — Never split a file across workers. Concurrent edits to the same file cause conflicts
- **Validate before writing** — Read state before mutating it. GET calls are cheap, broken writes cause cascading failures
- **Use `set -euo pipefail`** — Every shell script. No exceptions
- **Use `trash` not `rm`** — For file deletion (recoverable)

## The End-User Test

Before any change, ask: **"Would this work if I deleted `~/.config/doey/`, `~/.local/bin/doey`, and `~/.claude/agents/doey-*`, then ran `./install.sh` fresh?"**

Things that have tricked us before:
- Editing `~/.claude/statusline-command.sh` (user file, not shipped — fixed: now ships as `shell/doey-statusline.sh`, injected via `--settings` at launch)
- Relying on env vars set only inside a running Doey session (statusline subprocess doesn't inherit Claude's hook exports)
- Adding agent features that need settings.json entries the install doesn't create
- Assuming tmux pane titles exist before `on-session-start.sh` runs
- Testing in our session and assuming the user's first session behaves the same
- Using bash-only glob patterns in Bash tool commands (user's shell is zsh — `for f in *.task 2>/dev/null` is a parse error)

**The shippable pattern:** Need a Claude Code setting? Don't edit `~/.claude/settings.json`. Instead: ship the script in `shell/`, install it via `install.sh`, generate a settings overlay in `_init_doey_session()` → `${runtime_dir}/doey-settings.json`, and pass `--settings` on every `claude` launch command. See `doey-statusline.sh` as the reference implementation.

**What ships with Doey (safe to change):** `shell/`, `agents/`, `.claude/hooks/`, `.claude/skills/`, `docs/`, `install.sh`, `web-install.sh`

**What does NOT ship (local only):** `~/.claude/settings.json`, `~/.config/doey/config.sh` (only default created by install), anything in `/tmp/doey/` (generated at runtime)

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard (shell script). User lands here on attach |
| Session Manager | `0.1` | Routes tasks between team windows. Present when >1 team |
| Watchdog | `0.2+` | Monitors hook events, filters noise, escalates signal |
| Window Manager | `W.0` | Plans, delegates, validates all context. Never writes code |
| Workers | `W.1+` | Execute tasks. Skipped if reserved |
| Freelancers | `F.0+` | Independent workers in managerless teams |
| Git Agent | `F.x` | Dedicated git specialist. Has commit/push permissions |
| Test Driver | external | E2E test runner via `doey test` |

**Communication:** User → Manager → Workers (dispatch) | Workers → Manager (stop hooks) | Watchdog → Manager (alerts) | Manager → Session Manager (cross-team)

**Runtime:** `/tmp/doey/<project>/` — ephemeral, clears on reboot

### Tool Restrictions (via `on-pre-tool-use.sh`)

| Role | Blocked |
|------|---------|
| Window Manager | None (full access) |
| Git Agent | destructive rm, shutdown, tmux commands. **Allowed:** git commit/push |
| Watchdog | Edit, Write, Agent, NotebookEdit; send-keys limited; no git push/commit, destructive rm, shutdown, tmux kill |
| Workers | git push/commit, gh pr create/merge, ALL send-keys, tmux kill, rm -rf /, ~, $HOME, shutdown |

## Philosophy

**Strategic utilization over brute-force parallelism.** Fewer workers used well beat many workers used carelessly.

**The Manager is the bastion.** Nothing enters the golden context log unchallenged. Workers produce raw output — the Manager validates, distills, and decides what becomes knowledge.

**Force multipliers over headcount:** ultrathink, `/batch`, `/doey-research`, `/doey-simplify-everything`, agent swarms. Scale up only when parallelism genuinely helps.

## Project Layout

| Dir | Purpose | Installs to |
|-----|---------|-------------|
| `shell/` | CLI launcher & utilities | `~/.local/bin/` |
| `agents/` | Agent definitions (YAML frontmatter) | `~/.claude/agents/` |
| `.claude/hooks/` | Event hooks (loaded at Claude startup) | (in-repo) |
| `.claude/skills/` | Slash commands (loaded on-demand) | (in-repo) |
| `docs/` | Guides & context reference | — |
| `tests/` | Bash compat & E2E tests | — |

**Config hierarchy (last wins):** Hardcoded defaults → `~/.config/doey/config.sh` (global) → `.doey/config.sh` (project). Only the default config is created by install — user config is optional.

## Hooks

| Hook | Event | Purpose |
|------|-------|---------|
| `common.sh` | — | Shared library: `init_hook()`, `parse_field()`, role checks, `send_notification()` |
| `on-session-start.sh` | Session start | Injects DOEY_* env vars (ROLE, PANE_INDEX, WINDOW_INDEX, RUNTIME, etc.) |
| `on-prompt-submit.sh` | Before prompt | Sets BUSY status, READY on /compact, restores collapsed columns |
| `on-pre-tool-use.sh` | Before each tool | Role-based safety guards |
| `on-pre-compact.sh` | Before compaction | Preserves task context, role identity, recent file list |
| `post-tool-lint.sh` | After Write/Edit on .sh | Bash 3.2 compatibility lint (catches violations automatically) |
| `stop-status.sh` | On stop (sync) | Sets FINISHED/RESERVED status, blocks incomplete research |
| `stop-results.sh` | On stop (async) | Captures output, files changed, tool counts → JSON result |
| `stop-notify.sh` | On stop (async) | Notification chain: Worker → Manager → Session Manager → desktop |
| `watchdog-scan.sh` | Watchdog cycle | Pane state detection, anomaly reporting, heartbeat |
| `watchdog-wait.sh` | Watchdog idle | Sleep/wake (30s default, wakes on trigger) |
| `session-manager-wait.sh` | SM idle | Multi-trigger sleep: messages, results, crash alerts |

Hook exit codes: `0` = allow, `1` = block + error, `2` = block + feedback

## Conventions

- **Shell:** `set -euo pipefail`, bash 3.2 compatible
- **Agents:** YAML frontmatter (name, model, color, memory, description)
- **Skills:** YAML frontmatter (name, description) in `.claude/skills/<name>/SKILL.md`
- **Naming:** sessions `doey-<project>`, runtime `/tmp/doey/<project>/`

## Testing Changes

| Changed | Action |
|---------|--------|
| Agents | Restart Manager or Watchdog |
| Hooks | Restart ALL workers (`doey reload --workers`) — hooks load at startup |
| Skills | No restart needed (loaded on-demand) |
| Shell scripts | Run `tests/test-bash-compat.sh` |
| Launcher | `doey reload` or `doey stop && doey` |
| Install script | Test with fresh install: `doey uninstall && ./install.sh && doey doctor` |

## Important Files

**Shell:** `shell/doey.sh` (CLI entry ~3000 lines), `shell/info-panel.sh` (dashboard), `shell/context-audit.sh` (context auditor), `shell/pane-border-status.sh` (pane borders), `shell/tmux-statusbar.sh` (status bar)

**Docs:** `docs/context-reference.md` (authoritative architecture reference)
