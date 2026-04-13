# CLAUDE.md

## What This Is

Doey is a CLI tool that creates tmux-based multi-agent Claude Code teams. Run `doey` in any project directory to get a coordinated grid — Boss (user intent), Taskmaster (coordination), Subtaskmasters (planning), Workers (execution). Starts small, grows on demand. Entry point: `shell/doey.sh` → `~/.local/bin/doey`.

## ALWAYS DO THESE THINGS

- **Think "fresh install"** — Every change must work after `curl | bash`. No local state, config, or manual setup outside the install path
- **Ship in the repo, not in local files** — `~/.claude/settings.json` and other user-level files are LOCAL ONLY. Features needing them must be set up by install.sh or on-session-start hook
- **Test the install path** — After changing install.sh, doey.sh, or `shell/` scripts: does `./install.sh` work? Does `doey doctor` pass?
- **Don't assume your environment** — A user's first launch has no DOEY_* env vars, tmux, or teams. Guard every assumption
- **Bash 3.2 compatible** — Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `BASH_REMATCH` capture groups. Run `tests/test-bash-compat.sh` after `.sh` changes
- **Bash tool commands must be zsh-safe** — zsh on macOS breaks: `for f in *.ext 2>/dev/null`, unquoted globs with `nomatch`. Fix: `bash -c '...'` or `ls dir/ 2>/dev/null`. Parallel Bash calls must not depend on glob success
- **One worker per file** — Concurrent edits cause conflicts
- **Validate before writing** — Read state before mutating. GET calls are cheap, broken writes cascade
- **Use `set -euo pipefail`** — Every shell script. No exceptions
- **Use `trash` not `rm`** — For file deletion (recoverable)
- **Use AskUserQuestion for questions** — When asking the user questions, always use the AskUserQuestion tool (native Claude Code question UI) — never put questions inline in text responses. This applies to all user-facing roles (especially Boss)
- **Never add Co-Authored-By lines** — Do not append "Co-Authored-By" trailers or any AI attribution to git commit messages. Commits should contain only the commit message itself

## The End-User Test

Before any change: **"Would this work after deleting `~/.config/doey/`, `~/.local/bin/doey`, `~/.claude/agents/doey-*` and running `./install.sh` fresh?"**

Past traps: editing user files that don't ship, session-only env vars, uninstalled settings.json entries, assuming pane titles before `on-session-start.sh`, bash-only globs in zsh.

**Shippable pattern:** `shell/` → `install.sh` → `_init_doey_session()` → `--settings` on launch. Never edit `~/.claude/settings.json`.

**Ships:** `shell/`, `agents/`, `.claude/hooks/`, `.claude/skills/`, `docs/`, `teams/`, `tui/`, `tests/`, `install.sh`, `web-install.sh`
**Local only:** `~/.claude/settings.json`, `~/.config/doey/config.sh`, `/tmp/doey/`

## Architecture

| Role | Pane | Description |
|------|------|-------------|
| Info Panel | `0.0` | Live dashboard (shell script). User lands here on attach |
| Boss | `0.1` | User-facing Project Manager. Receives user intent, manages tasks, reports results |
| Taskmaster | `C.0` | Sole executor/coordinator. Routes tasks, spawns teams, manages git, dispatches work. Not user-facing — users interact via Boss |
| Task Reviewer | `C.1` | Reviews completed work for quality and correctness |
| Deployment | `C.2` | Handles deployment, CI/CD, and release operations |
| Doey Expert | `C.3` | Doey codebase specialist for self-improvement tasks |
| Subtaskmaster | `W.0` | Plans, delegates, validates all context. Never writes code |
| Workers | `W.1+` | Execute tasks. Skipped if reserved |
| Freelancers | `F.0+` | Independent workers in managerless teams |
| Test Driver | external | E2E test runner via `doey test` |

**Window layout:** `0` = Dashboard (Info Panel + Boss), `1` = Core Team (Taskmaster + specialists), `2+` = Worker teams (Subtaskmaster + Workers)

**Communication:** User → Boss → Taskmaster (relay) | Taskmaster → Subtaskmaster → Workers (dispatch) | Workers → Subtaskmaster (stop hooks) | Subtaskmaster → Taskmaster (cross-team)

**Runtime:** `/tmp/doey/<project>/` — ephemeral, clears on reboot

### Tool Restrictions (`on-pre-tool-use.sh`)

| Role | Blocked |
|------|---------|
| Subtaskmaster | Read/Edit/Write/Glob/Grep on project source; Agent; implementation work (send-keys allowed) |
| Taskmaster | Read/Edit/Write/Glob/Grep on project source; Agent |
| Boss | Read/Edit/Write/Glob/Grep on project source; send-keys; Agent; implementation work |
| Workers | git push, gh pr create/merge, ALL send-keys¹, tmux kill, rm -rf /, ~, $HOME, shutdown |

¹ Workers may send-keys to their coordinator (Subtaskmaster) pane — this is the one allowed exception, enforced in `.claude/hooks/on-pre-tool-use.sh`.

## Philosophy

- **Strategic utilization over brute-force parallelism.** Fewer workers used well beat many used carelessly
- **The Subtaskmaster is the bastion.** Workers produce raw output — Subtaskmaster validates, distills, and decides what becomes knowledge
- **Force multipliers over headcount:** ultrathink, `/batch`, `/doey-research`, agent swarms. Scale only when parallelism genuinely helps
- **Task-obsessed naming.** Our coordinator is the Taskmaster, not a manager. Teams are led by Subtaskmasters. Never abbreviate — always use the full name

## Project Layout

| Dir | Purpose | Installs to |
|-----|---------|-------------|
| `shell/` | CLI launcher & utilities | `~/.local/bin/` |
| `agents/` | Agent definitions (YAML frontmatter) | `~/.claude/agents/` |
| `.claude/hooks/` | Event hooks (loaded at Claude startup) | (in-repo) |
| `.claude/skills/` | Slash commands (loaded on-demand) | (in-repo) |
| `docs/` | Guides & context reference | — |
| `tests/` | Bash compat & E2E tests | — |
| `tui/cmd/scaffy/` + `tui/internal/scaffy/` | Scaffy template engine (sub-package of tui) | `~/.local/bin/doey-scaffy` |

**Config hierarchy (last wins):** Hardcoded defaults → `~/.config/doey/config.sh` (global) → `.doey/config.sh` (project). Only the default config is created by install — user config is optional.

## Hooks

| Hook | Event | Purpose |
|------|-------|---------|
| `common.sh` | — | Shared library: `init_hook()`, `parse_field()`, role checks, `send_notification()` |
| `on-session-start.sh` | Session start | Injects DOEY_* env vars (ROLE, PANE_INDEX, WINDOW_INDEX, RUNTIME, etc.) |
| `on-prompt-submit.sh` | Before prompt | Sets BUSY status, restores collapsed columns |
| `on-pre-tool-use.sh` | Before each tool | Role-based safety guards |
| `on-pre-compact.sh` | Before compaction | Preserves task context, role identity, recent file list |
| `post-tool-lint.sh` | After Write/Edit on .sh | Bash 3.2 compatibility lint (catches violations automatically) |
| `stop-status.sh` | On stop (sync) | Sets FINISHED/RESERVED status, blocks incomplete research |
| `stop-results.sh` | On stop (async) | Captures output, files changed, tool counts → JSON result |
| `stop-notify.sh` | On stop (async) | Notification chain: Worker → Subtaskmaster → Taskmaster → desktop |
| `stop-plan-tracking.sh` | On stop (async) | Plan tracking on stop |
| `on-notification.sh` | Notification | Notification routing |
| `post-push-complete.sh` | After git push | Post-push operations |
| `taskmaster-wait.sh` | Taskmaster idle | Multi-trigger sleep: messages, results, crash alerts |

Hook exit codes: `0` = allow, `1` = block + error, `2` = block + feedback

**Intent Fallback:** Unknown `doey` commands are routed through a Haiku-powered correction layer (`shell/intent-fallback.sh` + `shell/doey-intent-dispatch.sh`). Silent on failure, refuses destructive auto-corrects without a tty `[y/N]`, opt out with `DOEY_NO_INTENT_FALLBACK=1`. See `docs/intent-fallback.md`.

## Conventions

- **Agents:** YAML frontmatter in `agents/` (name, model, color, memory, description)
- **Skills:** YAML frontmatter in `.claude/skills/<name>/SKILL.md`
- **Naming:** sessions `doey-<project>`, runtime `/tmp/doey/<project>/`. Always "Taskmaster" and "Subtaskmaster" — never SM, TM, WM, or other abbreviations

## Role Naming System

All role names are centralized in `shell/doey-roles.sh` — the single source of truth. Three tiers:

| Tier | Variable prefix | Purpose | Example |
|------|----------------|---------|---------|
| Display | `DOEY_ROLE_*` | User-facing names | `DOEY_ROLE_COORDINATOR="Taskmaster"` |
| Internal ID | `DOEY_ROLE_ID_*` | Stable identifiers for logic/status files | `DOEY_ROLE_ID_COORDINATOR="coordinator"` |
| File pattern | `DOEY_ROLE_FILE_*` | Agent/skill filenames | `DOEY_ROLE_FILE_COORDINATOR="doey-taskmaster"` |

**How it flows:**

| Layer | Mechanism | Generated from |
|-------|-----------|---------------|
| Shell hooks | `source doey-roles.sh` via `common.sh` | Direct sourcing |
| Agent/skill `.md` files | `shell/expand-templates.sh` | `.md.tmpl` templates with `{{DOEY_ROLE_*}}` placeholders |
| Go TUI | `go generate ./internal/roles/` | `tui/cmd/gen-roles/main.go` reads `doey-roles.sh` |

**Rename procedure:**

1. Edit `shell/doey-roles.sh` — change the display name(s)
2. Run `bash shell/expand-templates.sh` — regenerates all `.md` from `.md.tmpl`
3. Run `cd tui && go generate ./internal/roles/` — regenerates Go constants
4. Run `cd tui && go build ./...` — verify Go compiles
5. Run `bash tests/test-bash-compat.sh` — verify shell compatibility

Never edit generated `.md` files directly — edit the `.md.tmpl` template instead.

## STATUS CHECK PROTOCOL

Rules for observing whether a pane is active or idle. Apply before telling the user "X is working" or "X is stuck".

- **ctx% is NOT an activity signal** — ignore it for activity determination. Idle panes at the `❯ ` prompt can display any ctx%
- **Preferred tool:** `doey-ctl status observe <pane>` — returns canonical JSON with `active`, `indicator`, and `ages`
- **Minimum capture depth:** `tmux capture-pane -p -S -20` (20 lines, never 4)
- **Spinner indicators** (glyphs `✻` `●` `⎿` paired with verbs): Sketching, Running, Cogitated, Baked, Sautéed, Brewed, Cooked, Thinking, Frolicking, Crystallizing, Pondering, Mulling, Ruminating, Contemplating, Musing
- **Idle signature:** pane ends with `❯ ` prompt on the last non-empty line AND no trailing spinner glyph

## Testing Changes

| Changed | Action |
|---------|--------|
| Agents | Restart Subtaskmaster |
| Hooks | Restart ALL workers (`doey reload --workers`) — hooks load at startup |
| Skills | No restart needed (loaded on-demand) |
| Shell scripts | Run `tests/test-bash-compat.sh` |
| Launcher | `doey reload` or `doey stop && doey` |
| Install script | Test with fresh install: `doey uninstall && ./install.sh && doey doctor` |

## Important Files

**Shell:** `shell/doey.sh` (CLI entry — most logic lives in `shell/doey-*.sh` modules), `shell/info-panel.sh` (dashboard), `shell/context-audit.sh` (context auditor), `shell/pane-border-status.sh` (pane borders), `shell/tmux-statusbar.sh` (status bar)

**Docs:** `docs/context-reference.md` (authoritative architecture reference), `docs/improving-agents.md` (agent customization guide)
