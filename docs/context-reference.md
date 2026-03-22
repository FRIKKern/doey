# Context Reference

How Claude Code instances in a Doey session receive their configuration, from lowest to highest precedence.

| Precedence | Source | Applies To |
|------------|--------|------------|
| Lowest | Agent definitions (`agents/`) | Manager, Session Mgr, Watchdog |
| | Settings (4-file merge) | All |
| | Hooks (`.claude/hooks/`) | All |
| | Skills (`.claude/skills/`) | Manager (+ 2 for Workers) |
| | Persistent memory | Manager, Session Mgr |
| | Environment vars (`session.env`) | All |
| | CLI launch flags | Per-instance |
| | tmux layout | All |
| | Runtime state (`/tmp/doey/`) | All |
| Highest | CLAUDE.md | All |


## Agent Definitions

Files in `agents/` (installed to `~/.claude/agents/`). Body = system prompt.

| Field | Manager | Session Mgr | Watchdog |
|-------|---------|-------------|----------|
| `model` | `opus` | `opus` | `haiku` |
| `color` | `green` | `#FF6B35` | `yellow` |
| `memory` | `user` | `user` | `none` |

Precedence: CLI `--model` > frontmatter > settings.


## Settings

Merge order (later wins for scalars; arrays additive; objects deep-merged):

1. `~/.claude/settings.json` — agent teams, model, notifications
2. `~/.claude/settings.local.json` — user-level overrides
3. `<project>/.claude/settings.json` — project-level
4. `<project>/.claude/settings.local.json` — permissions + hooks (copied by `doey init`)

Hooks require explicit registration in `settings.local.json` — not auto-discovered.


## Hooks

All in `.claude/hooks/`. Exit codes: 0=allow, 1=block+error, 2=block+feedback.

| File | Event | Purpose |
|------|-------|---------|
| `common.sh` | — | Shared utils: `init_hook()`, `parse_field()`, `_read_team_key()`, role checks, `send_notification()` |
| `on-session-start.sh` | SessionStart | Sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX, DOEY_TEAM_WINDOW, DOEY_TEAM_DIR, DOEY_RUNTIME |
| `on-prompt-submit.sh` | UserPromptSubmit | BUSY status; READY on `/compact`; column expansion |
| `on-pre-tool-use.sh` | PreToolUse | Role-based tool blocking |
| `on-pre-compact.sh` | PreCompact | Preserves orchestration state before compaction |
| `post-tool-lint.sh` | PostToolUse | Bash 3.2 compatibility lint |
| `stop-status.sh` | Stop | FINISHED/RESERVED/READY; blocks research without reports |
| `stop-results.sh` | Stop | Result JSON and completion events |
| `stop-notify.sh` | Stop | Unified stop notifications: Worker→Manager, Manager→Session Mgr, Session Mgr→desktop |
| `session-manager-wait.sh` | — | Session Manager sleep/wake between cycles (trigger, message, result, crash) |
| `watchdog-scan.sh` | — | Pane scanning (called directly, not registered) |
| `watchdog-wait.sh` | — | Event-driven sleep between scans |

**Identity:** Hooks must use `tmux display-message -t "$TMUX_PANE"` — without `-t`, tmux returns the focused pane.


## Skills

Project-level in `.claude/skills/<name>/SKILL.md`, invoked via `/skill-name`, loaded on-demand.

**Manager skills:**
`/doey-dispatch` (send to idle workers), `/doey-delegate` (to specific worker), `/doey-research` (with report enforcement), `/doey-monitor` (detect pane states), `/doey-status` (share/check status), `/doey-broadcast` (message all), `/doey-reload` (hot-reload), `/doey-reinstall` (pull + install), `/doey-repair` (dashboard diagnostic), `/doey-reserve` (reserve/unreserve panes), `/doey-watchdog-compact`, `/doey-purge` (audit context rot), `/doey-simplify-everything` (full codebase simplification), `/doey-stop` (stop worker), `/doey-clear` (restart workers/Watchdog/Manager)

**Session Manager skills:**
`/doey-worktree` (also Manager), `/doey-add-window`, `/doey-kill-window`, `/doey-kill-session`, `/doey-kill-all-sessions`, `/doey-list-windows`

**Worker skills:** `/doey-status`, `/doey-reserve`, `/doey-stop`. Watchdog uses none.


## Persistent Memory

Auto-loaded at startup; lines after 200 truncated. Store stable patterns, not session state.

- Manager: `~/.claude/agent-memory/doey-manager/MEMORY.md`
- Session Mgr: `~/.claude/agent-memory/doey-session-manager/MEMORY.md`
- Watchdog: disabled (`memory: none`)


## Environment Variables

Bootstrap: `doey.sh` → `tmux set-environment DOEY_RUNTIME` → writes `session.env`.

**Session-level (`session.env`):**
`PROJECT_DIR`, `PROJECT_NAME`, `SESSION_NAME`, `GRID`, `ROWS`, `MAX_WORKERS`, `CURRENT_COLS`, `TOTAL_PANES`, `WORKER_COUNT`, `WORKER_PANES`, `WATCHDOG_PANE`, `RUNTIME_DIR`, `PASTE_SETTLE_MS`, `IDLE_COLLAPSE_AFTER`, `IDLE_REMOVE_AFTER`, `TEAM_WINDOWS`, `WDG_SLOT_1`..`WDG_SLOT_3`, `SM_PANE`

**Set by tmux/Claude Code:** `TMUX_PANE`, `CLAUDE_PROJECT_DIR`

**Set by hooks:** `DOEY_ROLE`, `DOEY_PANE_INDEX`, `DOEY_WINDOW_INDEX`, `DOEY_TEAM_WINDOW`, `DOEY_TEAM_DIR`, `DOEY_RUNTIME`

**Per-window (`team_<W>.env`):** `WINDOW_INDEX`, `GRID`, `MANAGER_PANE`, `WATCHDOG_PANE`, `WORKER_PANES`, `WORKER_COUNT`, `SESSION_NAME`. Loaded via `_read_team_key()`, overrides session.env for per-window fields.


## CLI Launch Flags

| Instance | Command |
|----------|---------|
| Manager | `claude --dangerously-skip-permissions --model opus --name "T<N> Window Manager" --agent doey-manager` |
| Watchdog | `claude --dangerously-skip-permissions --model haiku --name "T<N> Watchdog" --agent doey-watchdog` |
| Workers | `claude --dangerously-skip-permissions --model opus --name "T<N> W<P>" --append-system-prompt-file <prompt>.md` |

Workers use `--append-system-prompt-file` (not `--agent`) for per-worker identity. Precedence: CLI flags > agent frontmatter > settings.

**Note:** `_launch_team_manager()` in `doey.sh` should pass `--model opus` explicitly to ensure the Manager always uses opus regardless of settings defaults.


## tmux Layout

```
Dashboard: [0.0 Info] [0.1 Session Mgr] [0.2-0.7 Watchdog slots]
Team W:    [W.0 Mgr] [W.1 W1 | W.2 W2] [W.3 W3 | W.4 W4] ...
```

Dynamic grid auto-expands when all workers are busy.

**Pane communication:**
- `send-keys` — short commands (< 200 chars)
- `load-buffer` + `paste-buffer` — long/multi-line tasks
- `capture-pane` — read pane output

**Key details:**
- **PANE_SAFE escaping:** `${PANE//[:.]/_}` — e.g. `doey-project:0.5` → `doey-project_0_5`
- **Pane titles:** `"T<N> Window Manager"`, `"T<N> Watchdog"`, `"Session Manager"`, `"T<N> W<P>"`
- **Startup timing:** Manager briefing 8s; workers ready ~15s
- **Notifications:** `bell-action none`, `visual-bell off`; uses `osascript` instead


## Runtime State

Root: `/tmp/doey/<project>/`. Directories created by `doey init`, ensured by `init_hook()`.

| Path | Purpose |
|------|---------|
| `session.env` | Session manifest |
| `team_<W>.env` | Per-window team config |
| `worker-system-prompt-w<W>-<N>.md` | Per-worker prompt |
| `status/<pane_safe>.status` | 4-line: PANE, UPDATED, STATUS, TASK |
| `status/<pane_safe>.reserved` | Permanent reservation marker |
| `status/pane_hash_<pane_safe>` | Output hash (change detection) |
| `status/unchanged_count_<W>_<index>` | Stuck-detection counter |
| `status/watchdog_W<W>.heartbeat` | Watchdog liveness |
| `status/watchdog_pane_states_W<W>.json` | Watchdog state snapshot |
| `status/completion_pane_<W>_<index>` | Worker completion event |
| `status/crash_pane_<W>_<index>` | Crash alert |
| `status/manager_crashed_W<N>` | Manager crash marker |
| `status/pane_map` | Pane ID-to-index cache |
| `status/col_*.collapsed` | Collapsed column markers |
| `research/<pane_safe>.task` | Research task marker |
| `reports/<pane_safe>.report` | Research report |
| `results/` | Structured result JSON |
| `broadcasts/` | Broadcast messages (created on-demand by `/doey-broadcast`) |
| `messages/` | Inter-instance messages (created by `init_hook()`) |

**Status values:** READY, BUSY, FINISHED, RESERVED.

**Research lifecycle:** dispatch → `.task` created → worker investigates → Stop hook blocks until `.report` written → Manager reads report.


## Debugging

| Symptom | Check |
|---------|-------|
| Manager writes code itself | Memory lacks delegation-first rules |
| Manager dispatches to Watchdog | `WATCHDOG_PANE` wrong in session.env |
| Manager sends empty tasks | Task text empty before Enter |
| All panes think they're Manager | Hook missing `-t "$TMUX_PANE"` |
| Hooks not firing | `.claude/settings.local.json` missing (`doey init`) |
| Watchdog stops monitoring | Stop hook keep-alive failing |
| Watchdog spams notifications | State tracking lost after compaction |
| Research stops without report | Check exit 2 in `stop-status.sh`; verify `.task` exists |
| Workers ignore hook changes | Restart workers (`/doey-clear workers`) |
| Dispatch to reserved pane | Check `.reserved` file; verify `is_reserved()` |
| Runtime file not found | Verify PANE_SAFE escaping; check `init_hook()` ran |
