# Context Reference -- Manager & Watchdog Agents

## Context Layer Model

```
Load Order (bottom = first, top = last / highest precedence)

  +----------------------------------------------------------+
  | 10. CLAUDE.md           (project root — loaded by all)   |
  +----------------------------------------------------------+
  |  9. Runtime State       (status files, messages, tasks)  |
  +----------------------------------------------------------+
  |  8. tmux Integration    (session, panes, send-keys)      |
  +----------------------------------------------------------+
  |  7. CLI Launch Flags    (--agent, --model, --dangerously) |
  +----------------------------------------------------------+
  |  6. Environment Vars    (session.env, TMUX_PANE)         |
  +----------------------------------------------------------+
  |  5. Persistent Memory   (~/.claude/agent-memory/)        |
  +----------------------------------------------------------+
  |  4. Skills/Commands     (~/.claude/commands/doey-*.md)   |
  +----------------------------------------------------------+
  |  3. Hook System         (.claude/hooks/ modular scripts) |
  +----------------------------------------------------------+
  |  2. Claude Code Settings (4-file merge chain)            |
  +----------------------------------------------------------+
  |  1. Agent Definitions   (agents/doey-manager.md, etc.)   |
  +----------------------------------------------------------+
```

| Layer | Source Files | Applies To | Load Time |
|-------|-------------|------------|-----------|
| 1. Agent Definitions | `agents/doey-manager.md`, `agents/doey-watchdog.md` | Manager, Watchdog | Startup (via `--agent`) |
| 2. Settings | 4-file merge chain | All | Startup |
| 3. Hooks | `.claude/hooks/` modular scripts | All | Runtime (on events) |
| 4. Skills | `commands/doey-*.md` | Manager primarily | On-demand |
| 5. Memory | `~/.claude/agent-memory/<agent>/MEMORY.md` | Manager | Startup |
| 6. Env Vars | `session.env`, tmux env | All | Startup + Runtime |
| 7. CLI Flags | `--agent`, `--model`, `--dangerously-skip-permissions` | Per-instance | Startup |
| 8. tmux | Session config, pane structure | All | Startup |
| 9. Runtime | `/tmp/doey/<name>/` tree | All | Runtime |
| 10. CLAUDE.md | Project root | All | Startup |


## Layer 1: Agent Definitions

**Files:** `agents/doey-manager.md`, `agents/doey-watchdog.md`, `agents/test-driver.md` (installed to `~/.claude/agents/`)

| Field | Manager | Watchdog | Effect |
|-------|---------|----------|--------|
| `model` | `opus` | `haiku` | Default model; CLI `--model` overrides |
| `color` | `green` | `yellow` | Status line color |
| `memory` | `user` | `none` | Manager stores to `~/.claude/agent-memory/<name>/`; Watchdog has no memory |

Body text below frontmatter becomes the system prompt. Manager: ~253 lines (identity, workflow, delegation rules). Watchdog: ~175 lines (monitoring loop, prompt detection, monitoring rules).

Precedence: CLI `--model` > frontmatter `model` > settings `model`.


## Layer 2: Claude Code Settings

Merge order (later wins for scalars; arrays are additive):

| File | Key Settings |
|------|-------------|
| `~/.claude/settings.json` | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"`, `skipDangerousModePermissionPrompt: true`, `model: "opus"`, `notifications: false` |
| `~/.claude/settings.local.json` | `permissions.allow: ["Bash(brew install:*)"]` |
| `<project>/.claude/settings.json` | Not present |
| `<project>/.claude/settings.local.json` | Registers 6 hook events |

*Note: Values shown for `~/.claude/settings.json` and `~/.claude/settings.local.json` are examples from the project's setup. Your user-level settings may differ.*

Merge: scalars=last-wins, arrays=additive, objects=deep-merged.


## Layer 3: Hook System

| File | Purpose |
|------|---------|
| `common.sh` | Shared: pane identity, runtime dir, reservation helpers (`is_reserved()`, `reserve_pane()`, etc.) |
| `on-session-start.sh` | SessionStart: initial setup |
| `on-prompt-submit.sh` | UserPromptSubmit: sets BUSY |
| `on-pre-tool-use.sh` | PreToolUse: safety guards |
| `on-pre-compact.sh` | PreCompact: context preservation |
| `post-tool-lint.sh` | PostToolUse: linting after tool use |
| `stop-status.sh` | Stop: sets FINISHED/RESERVED, blocks research workers without reports (exit 2) |
| `stop-results.sh` | Stop: collects and writes results |
| `stop-notify.sh` | Stop: Manager notifications |
| `watchdog-scan.sh` | Utility: called directly by Watchdog for pane scanning (not a registered hook) |

Exit codes: 0=allow, 1=block+error, 2=block+feedback.

**TMUX_PANE identity:** Hooks use `tmux display-message -t "$TMUX_PANE"` (with `-t`) to resolve the correct pane. Without `-t`, tmux returns the focused pane (usually 0.0), causing all workers to misidentify as Manager.


## Layer 4: Skills/Commands

15 skills installed to `~/.claude/commands/`, invoked via `/skill-name`. Loaded on-demand as additional user-turn instructions.

| Skill | Primary Agent | Purpose |
|-------|---------------|---------|
| `/doey-dispatch` | Manager | Send task to idle workers |
| `/doey-delegate` | Manager | Delegate to specific worker |
| `/doey-research` | Manager | Research task with report enforcement |
| `/doey-monitor` | Manager | Detect FINISHED/BUSY/ERROR/READY |
| `/doey-status` | Manager/Workers | Share or check status |
| `/doey-broadcast` | Manager | Message all instances |
| `/doey-send` | Manager | Message specific pane |
| `/doey-inbox` | Any | Read messages |
| `/doey-team` | Manager | Team layout overview |
| `/doey-stop-all` | Manager | Stop all sessions |
| `/doey-restart-workers` | Manager | Restart workers + Watchdog |
| `/doey-reinstall` | Manager | Pull + re-install |
| `/doey-reserve` | Manager/Workers | Reserve/unreserve panes |
| `/doey-stop` | Manager | Stop a specific worker |
| `/doey-watchdog-compact` | Manager | Compact Watchdog context |

Agent usage: Manager uses all except `/doey-inbox`. Watchdog uses none. Workers use `/doey-inbox`, `/doey-status`, `/doey-reserve`.


## Layer 5: Persistent Memory

| Agent | Path | Notes |
|-------|------|-------|
| Manager | `~/.claude/agent-memory/doey-manager/MEMORY.md` | Stores dispatch patterns, delegation rules, hook behavior |
| Watchdog | `~/.claude/agent-memory/doey-watchdog/MEMORY.md` | May be empty (Haiku rarely accumulates memory) |

Auto-loaded at startup; lines after 200 truncated. Store stable patterns, not session state.


## Layer 6: Environment Variables

Bootstrap: `doey.sh` → `tmux set-environment DOEY_RUNTIME` → writes `session.env`.
Agents read: `tmux show-environment DOEY_RUNTIME | cut -d= -f2-` → `source session.env`.

| Variable | Description |
|----------|-------------|
| `PROJECT_DIR` | Absolute path to project root |
| `PROJECT_NAME` | Sanitized project name |
| `SESSION_NAME` | tmux session name (`doey-<name>`) |
| `GRID` | Grid layout (e.g., `6x2`) |
| `TOTAL_PANES` | Total pane count |
| `WORKER_COUNT` | Number of workers |
| `WATCHDOG_PANE` | Watchdog pane index |
| `WORKER_PANES` | Comma-separated worker indices |
| `RUNTIME_DIR` | Runtime state directory |
| `TMUX_PANE` | tmux auto-set pane ID (e.g., `%0`) |
| `CLAUDE_PROJECT_DIR` | Claude Code project dir |
| `CLAUDECODE` | Set when inside Claude Code |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `1` — enables Agent Teams |


## Layer 7: CLI Launch Flags

| Instance | Command |
|----------|---------|
| Manager | `claude --dangerously-skip-permissions --agent doey-manager` |
| Watchdog | `claude --dangerously-skip-permissions --model haiku --agent doey-watchdog` |
| Workers | `claude --dangerously-skip-permissions --model opus --append-system-prompt-file /tmp/doey/<name>/worker-system-prompt-<N>.md` |

Precedence: CLI flags > agent frontmatter > settings files.

Workers use `--append-system-prompt-file` (not `--agent`) to inject per-worker rules and identity.


## Layer 8: tmux Integration

Default grid: 6x2 (12 panes). Pane 0.0 = Manager. Watchdog = pane at column count index. Rest = workers.

```
+--------+--------+--------+--------+--------+--------+
|  0.0   |  0.1   |  0.2   |  0.3   |  0.4   |  0.5   |
|  MGR   |  W1    |  W2    |  W3    |  W4    |  W5    |
+--------+--------+--------+--------+--------+--------+
|  0.6   |  0.7   |  0.8   |  0.9   |  0.10  |  0.11  |
|  WDG   |  W6    |  W7    |  W8    |  W9    |  W10   |
+--------+--------+--------+--------+--------+--------+
```

| Method | Use Case |
|--------|----------|
| `send-keys` | Short commands (< 200 chars) |
| `load-buffer` + `paste-buffer` | Long/multi-line tasks |
| `capture-pane` | Read pane output |

Bell suppression: `bell-action none`, `visual-bell off`. Notifications via `osascript` in hooks.
Display: `pane-border-status top`, heavy borders, role-aware colors, mouse enabled, status bar shows NB/NR/NF counts.


## Layer 9: Runtime State

```
/tmp/doey/<project>/
  session.env                        # Session manifest
  worker-system-prompt-N.md          # Per-worker prompt (base + identity)
  status/
    <pane_safe>.status               # 4-line: PANE, UPDATED, STATUS, TASK
    <pane_safe>.reserved             # contains "permanent"
  research/
    <pane_safe>.task                  # Research task marker
  reports/
    <pane_safe>.report               # Research report
  messages/                          # Inter-pane messages
  broadcasts/                        # Broadcast messages
```

**Status values:** READY, BUSY, FINISHED, RESERVED.

**Reservation:** Created by `/doey-reserve` (permanent only). Consumed by `is_reserved()`, statusbar, and Manager dispatch.

**Research lifecycle:** Manager dispatches → `.task` created → worker investigates → Stop hook blocks until `.report` written → Manager reads report.


## Layer 10: CLAUDE.md

Loaded by all instances. Contains: project overview, architecture, key directories, conventions, testing guidance, file reference.


## Debugging

| Symptom | Check |
|---------|-------|
| Manager writes code itself | Memory lacks delegation-first rules |
| Manager uses wrong session | `tmux show-environment DOEY_RUNTIME` invalid |
| Manager dispatches to Watchdog | `WATCHDOG_PANE` in session.env wrong |
| Manager sends empty tasks | Task text empty before Enter |
| Manager gets no stop notifications | `stop-notify.sh` not registered; pane not resolving to 0.0 |
| Watchdog stops monitoring | Stop hook keep-alive failing; check `WATCHDOG_PANE` |
| Watchdog spams notifications | State tracking lost after compaction |
| All panes think they're Manager | Hook using bare `tmux display-message` without `-t "$TMUX_PANE"` |
| Hooks not firing | `.claude/settings.local.json` missing |
| Research worker stops without report | Check exit 2 path in `stop-status.sh`; verify `.task` created |
| Workers don't pick up hook changes | Restart workers (`/doey-restart-workers`) |
| Dispatch to reserved pane | Check `.reserved` file exists; verify `is_reserved()` |

**Trace order:** 1. Agent definition → 2. Memory → 3. Settings (4-file merge) → 4. Hook scripts → 5. Skill files → 6. session.env / tmux env → 7. Runtime state → 8. CLI flags in doey.sh.
