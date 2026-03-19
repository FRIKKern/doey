# Context Reference -- Window Manager & Watchdog Agents

## Context Layer Model

Load order (bottom = first loaded, top = highest precedence):

| # | Layer | Source | Applies To | Load Time |
|---|-------|--------|------------|-----------|
| 10 | CLAUDE.md | Project root | All | Startup |
| 9 | Runtime State | `/tmp/doey/<name>/` tree | All | Runtime |
| 8 | tmux Integration | Session config, pane structure | All | Startup |
| 7 | CLI Launch Flags | `--agent`, `--model`, `--dangerously-skip-permissions` | Per-instance | Startup |
| 6 | Environment Vars | `session.env`, tmux env | All | Startup + Runtime |
| 5 | Persistent Memory | `~/.claude/agent-memory/<agent>/MEMORY.md` | Window Manager | Startup |
| 4 | Skills/Commands | `commands/doey-*.md` | Window Manager primarily | On-demand |
| 3 | Hook System | `.claude/hooks/` modular scripts | All | Runtime (on events) |
| 2 | Settings | 4-file merge chain | All | Startup |
| 1 | Agent Definitions | `agents/doey-*.md` | Manager, Session Mgr, Watchdog | Startup (`--agent`) |


## Layer 1: Agent Definitions

Files in `agents/` (installed to `~/.claude/agents/`). Body text = system prompt.

| Field | Manager | Session Mgr | Watchdog | Effect |
|-------|---------|-------------|----------|--------|
| `model` | `opus` | `opus` | `opus` | CLI `--model` overrides |
| `color` | `green` | `#FF6B35` | `yellow` | Status line color |
| `memory` | `user` | `user` | `none` | Stored in `~/.claude/agent-memory/<name>/` |

Precedence: CLI `--model` > frontmatter `model` > settings `model`.


## Layer 2: Claude Code Settings

Merge order (later wins for scalars; arrays additive; objects deep-merged):

| # | File | Notes |
|---|------|-------|
| 1 | `~/.claude/settings.json` | Agent teams, model, notifications |
| 2 | `~/.claude/settings.local.json` | User-level overrides |
| 3 | `<project>/.claude/settings.json` | Project-level (if present) |
| 4 | `<project>/.claude/settings.local.json` | Permission allow-list + hook registration (copied by `doey init`) |

Hooks require explicit registration in `settings.local.json` — NOT auto-discovered from `.claude/hooks/`.


## Layer 3: Hook System

All in `.claude/hooks/`. Exit codes: 0=allow, 1=block+error, 2=block+feedback.

| File | Event | Purpose |
|------|-------|---------|
| `common.sh` | — | Shared utils: `init_hook()`, `parse_field()`, `load_team_env()`, role checks, `send_notification()`, `NL`, `is_numeric()` |
| `on-session-start.sh` | SessionStart | Sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX |
| `on-prompt-submit.sh` | UserPromptSubmit | Sets BUSY; READY on `/compact`; expands collapsed columns |
| `on-pre-tool-use.sh` | PreToolUse | Safety guards (role-based tool blocking) |
| `on-pre-compact.sh` | PreCompact | Preserves orchestration state before compaction |
| `post-tool-lint.sh` | PostToolUse | Bash 3.2 compatibility lint |
| `stop-status.sh` | Stop | Sets FINISHED/RESERVED/READY; blocks research without reports |
| `stop-results.sh` | Stop | Writes result JSON and completion events |
| `stop-notify.sh` | Stop | Session Manager notifications |
| `stop-notify-manager.sh` | Stop | Notifies Window Manager when worker finishes |
| `stop-notify-session-manager.sh` | Stop | Notifies Session Manager when Window Manager finishes |
| `watchdog-scan.sh` | — | Utility: pane scanning (called directly, not a registered hook) |
| `watchdog-wait.sh` | — | Utility: event-driven sleep between scan cycles |

**TMUX_PANE identity:** Hooks must use `tmux display-message -t "$TMUX_PANE"` (with `-t`). Without `-t`, tmux returns the focused pane, causing misidentification.


## Layer 4: Skills/Commands

Installed to `~/.claude/commands/`, invoked via `/skill-name`, loaded on-demand.

| Skill | Agent | Purpose |
|-------|-------|---------|
| `/doey-dispatch` | Manager | Send task to idle workers |
| `/doey-delegate` | Manager | Delegate to specific worker |
| `/doey-research` | Manager | Research task with report enforcement |
| `/doey-monitor` | Manager | Detect FINISHED/BUSY/ERROR/READY |
| `/doey-status` | Manager/Workers | Share or check status |
| `/doey-broadcast` | Manager | Message all instances |
| `/doey-team` | Manager | Team layout overview |
| `/doey-reload` | Manager | Hot-reload session |
| `/doey-reinstall` | Manager | Pull + re-install |
| `/doey-repair` | Manager | Dashboard diagnostic and repair |
| `/doey-reserve` | Manager/Workers | Reserve/unreserve panes |
| `/doey-watchdog-compact` | Manager | Compact Watchdog context |
| `/doey-purge` | Manager | Audit & fix context rot + code quality |
| `/doey-stop` | Manager | Stop a specific worker |
| `/doey-clear` | Manager | Clear and restart workers/Watchdog/Manager |
| `/doey-worktree` | Session Mgr/Manager | Transform team to/from worktree isolation |
| `/doey-add-window` | Session Mgr | Add a new team window |
| `/doey-kill-window` | Session Mgr | Kill a team window |
| `/doey-kill-session` | Session Mgr | Kill entire Doey session |
| `/doey-kill-all-sessions` | Session Mgr | Kill all Doey sessions |
| `/doey-list-windows` | Session Mgr | List team windows with status |

Watchdog uses none. Workers use only `/doey-status`, `/doey-reserve`.


## Layer 5: Persistent Memory

Auto-loaded at startup; lines after 200 truncated. Store stable patterns, not session state.

| Agent | Path | Notes |
|-------|------|-------|
| Manager | `~/.claude/agent-memory/doey-manager/MEMORY.md` | Dispatch patterns, delegation rules |
| Session Mgr | `~/.claude/agent-memory/doey-session-manager/MEMORY.md` | Routing, team coordination |
| Watchdog | — | Disabled (`memory: none`) |


## Layer 6: Environment Variables

Bootstrap: `doey.sh` → `tmux set-environment DOEY_RUNTIME` → writes `session.env`.
Read: `tmux show-environment DOEY_RUNTIME | cut -d= -f2-` → `source session.env`.

**Session-level (`session.env`):**

| Variable | Description |
|----------|-------------|
| `PROJECT_DIR`, `PROJECT_NAME` | Project root path and sanitized name |
| `SESSION_NAME` | tmux session name (`doey-<name>`) |
| `GRID` | Layout (e.g., `6x2` or `dynamic`) |
| `ROWS`, `MAX_WORKERS`, `CURRENT_COLS` | Dynamic grid params (dynamic mode only) |
| `TOTAL_PANES` | Total pane count (static mode only) |
| `WORKER_COUNT`, `WORKER_PANES` | Worker count and comma-separated indices |
| `WATCHDOG_PANE` | Watchdog Dashboard slot (e.g., `0.2`) |
| `RUNTIME_DIR` | Runtime state directory |
| `PASTE_SETTLE_MS` | Paste buffer settle time (ms) |
| `IDLE_COLLAPSE_AFTER`, `IDLE_REMOVE_AFTER` | Idle column timers (seconds) |
| `TEAM_WINDOWS` | Active team window indices (e.g., `"0,1,2"`) |
| `WDG_SLOT_1`..`WDG_SLOT_3` | Dashboard Watchdog pane refs per team |
| `SM_PANE` | Session Manager pane ref (e.g., `0.1`) |

**Set by tmux/Claude Code:** `TMUX_PANE`, `CLAUDE_PROJECT_DIR`, `CLAUDECODE`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.

**Set by hooks:** `DOEY_ROLE` (manager/watchdog/worker), `DOEY_PANE_INDEX`, `DOEY_WINDOW_INDEX`, `DOEY_TEAM_WINDOW`.

**Per-window team config (`team_<W>.env`):** `WINDOW_INDEX`, `GRID`, `MANAGER_PANE`, `WATCHDOG_PANE`, `WORKER_PANES`, `WORKER_COUNT`, `SESSION_NAME`. Loaded via `load_team_env()`. Team env overrides session.env for per-window fields.


## Layer 7: CLI Launch Flags

| Instance | Command |
|----------|---------|
| Window Manager | `claude --dangerously-skip-permissions --agent doey-manager` |
| Watchdog | `claude --dangerously-skip-permissions --model opus --agent doey-watchdog` |
| Workers | `claude --dangerously-skip-permissions --model opus --append-system-prompt-file /tmp/doey/<name>/worker-system-prompt-w<W>-<N>.md` |

Precedence: CLI flags > agent frontmatter > settings files.

Workers use `--append-system-prompt-file` (not `--agent`) to inject per-worker rules and identity.


## Layer 8: tmux Integration

**Dashboard (window 0):** 0.0=Info Panel, 0.1=Session Manager, 0.2-0.7=Watchdog slots (one per team).
**Team windows (1+):** W.0=Window Manager, W.1+=Workers. Dynamic grid auto-expands when all busy.

```
Dashboard: [0.0 Info] [0.1 Session Mgr] [0.2-0.7 Watchdog slots]
Team W:    [W.0 Mgr] [W.1 W1 | W.2 W2] [W.3 W3 | W.4 W4] [W.5 W5 | W.6 W6] ...
```

Static grid (legacy, `doey 6x2`): W.0=Manager, all others=Workers.

| Method | Use Case |
|--------|----------|
| `send-keys` | Short commands (< 200 chars) |
| `load-buffer` + `paste-buffer` | Long/multi-line tasks |
| `capture-pane` | Read pane output |

**Key details:**
- **PANE_SAFE escaping:** `${PANE//[:.]/_}` — e.g., `doey-project:0.5` → `doey-project_0_5`
- **Pane titles:** `"T<N> Window Manager"`, `"T<N> Watchdog"`, `"Session Manager"`, `"T<N> W<P>"`
- **Info Panel:** `shell/info-panel.sh` — live dashboard, refreshes every 5 minutes
- **Display:** pane-border-status top, role-aware colors, mouse enabled, NB/NR/NF/NRsv status counts
- **Startup timing:** Manager briefing after 8s; workers ready in ~15s
- **Bell suppression:** `bell-action none`, `visual-bell off`; notifications via `osascript`


## Layer 9: Runtime State

Root: `/tmp/doey/<project>/`

| Path | Purpose |
|------|---------|
| `session.env` | Session manifest |
| `team_<W>.env` | Per-window team config |
| `worker-system-prompt-w<W>-<N>.md` | Per-worker prompt (base + identity) |
| `status/<pane_safe>.status` | 4-line: PANE, UPDATED, STATUS, TASK |
| `status/<pane_safe>.reserved` | Permanent reservation marker |
| `status/pane_hash_<pane_safe>` | Watchdog output hash (change detection) |
| `status/unchanged_count_<W>_<index>` | Stuck-detection counter |
| `status/watchdog_W<W>.heartbeat` | Watchdog liveness marker |
| `status/watchdog_pane_states_W<W>.json` | Watchdog state snapshot |
| `status/completion_pane_<W>_<index>` | Worker completion event |
| `status/crash_pane_<W>_<index>` | Crash alert |
| `status/manager_crashed_W<N>` | Manager crash marker |
| `status/pane_map` | Pane ID-to-index mapping cache |
| `status/col_*.collapsed` | Collapsed column markers |
| `research/<pane_safe>.task` | Research task marker |
| `reports/<pane_safe>.report` | Research report |
| `results/` | Structured result JSON |
| `broadcasts/` | Broadcast messages |

Directories created by `doey init` and eagerly ensured by `init_hook()`.

**Status values:** READY, BUSY, FINISHED, RESERVED.

**Research lifecycle:** dispatch → `.task` created → worker investigates → Stop hook blocks until `.report` written → Manager reads report.


## Layer 10: CLAUDE.md

Loaded by all instances. Project overview, architecture, conventions, file reference.


## Debugging

| Symptom | Check |
|---------|-------|
| Manager writes code itself | Memory lacks delegation-first rules |
| Manager dispatches to Watchdog | `WATCHDOG_PANE` in session.env wrong |
| Manager sends empty tasks | Task text empty before Enter |
| All panes think they're Manager | Hook missing `-t "$TMUX_PANE"` in `tmux display-message` |
| Hooks not firing | `.claude/settings.local.json` missing (`doey init`) |
| Watchdog stops monitoring | Stop hook keep-alive failing |
| Watchdog spams notifications | State tracking lost after compaction |
| Research stops without report | Check exit 2 in `stop-status.sh`; verify `.task` exists |
| Workers ignore hook changes | Restart workers (`/doey-clear workers`) |
| Dispatch to reserved pane | Check `.reserved` file; verify `is_reserved()` |
| Runtime file not found | Verify PANE_SAFE escaping; check `init_hook()` ran |
