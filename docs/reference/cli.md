# Doey CLI Reference

Authoritative reference for the `doey` and `doey-ctl` command surface, the
shell library functions teams source, and the hook contract enforced by
`.claude/hooks/`.

Every entry below cites the file it lives in. If something is not in this
document, it is not in the code. If you need to add a flag, add it here in the
same commit so this stays the source of truth.

---

## 1. `doey` command

Entry point: `shell/doey.sh` (installed to `~/.local/bin/doey`). The dispatch
table is at `shell/doey.sh:160-669`.

A first dispatch case forwards a fixed set of subcommands directly to
`doey-ctl` when the binary is on `PATH` (`shell/doey.sh:160-169`):

```
msg | status | health | task | tmux | team | agent | event | error |
nudge | migrate | interaction | briefing
```

These are documented under `doey-ctl` (section 2). The rest of this section
covers the subcommands handled directly inside `shell/doey.sh`.

### 1.1 Lifecycle and project management

| Subcommand | Source | Description | Example |
|---|---|---|---|
| `doey` (bare) | `shell/doey.sh:671-689` | Smart launch — attach existing session, otherwise launch with default grid, otherwise show project picker. | `doey` |
| `doey new <name>` | `shell/doey.sh:306-312` (`shell/doey-new.sh`) | Create `~/projects/<name>`, init git, register, launch. | `doey new my-app` |
| `doey init` | `shell/doey.sh:298-305` | Register the current directory as a project and launch it. | `doey init` |
| `doey list` | `shell/doey.sh:245` | Show all registered projects and their status. | `doey list` |
| `doey open <query>` / `doey switch <query>` | `shell/doey.sh:635-660` | Fuzzy-find a registered project by name and attach (or launch). | `doey open my-app` |
| `doey stop` | `shell/doey.sh:319-323` | Stop the session for the current project. | `doey stop` |
| `doey reload [--workers]` | `shell/doey.sh:324` | Hot-reload the running session. `--workers` also restarts worker panes. | `doey reload --workers` |
| `doey purge [...]` | `shell/doey.sh:313-318` (`shell/doey-purge.sh`) | Audit and clean stale runtime files / context bloat. | `doey purge` |
| `doey doctor` | `shell/doey.sh:246-251` (`shell/doey-doctor.sh`) | Check installation health and prerequisites. | `doey doctor` |
| `doey version` / `--version` / `-v` | `shell/doey.sh:252` | Show install version. | `doey version` |
| `doey update` / `doey reinstall` | `shell/doey.sh:259-266` (`shell/doey-update.sh`) | Pull latest changes and reinstall. | `doey update` |
| `doey uninstall` | `shell/doey.sh:253-257` | Remove all Doey files (keeps git repo and agent memory). | `doey uninstall` |
| `doey remove [<name>\|<col-num>]` | `shell/doey.sh:396-416` | Remove a worker column (number, dynamic grid only) or unregister a project (name). | `doey remove 2` / `doey remove my-app` |

### 1.2 Grid and worker management

| Subcommand | Source | Description | Example |
|---|---|---|---|
| `doey NxM` | `shell/doey.sh:629-633` | Launch with an explicit grid (e.g. `4x3`, `6x2`, `3x2`). | `doey 4x3` |
| `doey dynamic` / `doey d` | `shell/doey.sh:376-390` | Launch with the dynamic grid (start minimal, grow on demand). | `doey dynamic` |
| `doey add` | `shell/doey.sh:391-395` | Add a worker column (2 workers) to a dynamic-grid session. | `doey add` |
| `doey add-team <name>` | `shell/doey.sh:417-428` | Add a team window from a `*.team.md` definition. | `doey add-team rd` |
| `doey add-window [...]` | `shell/doey.sh:503-541` | Add a team window directly. Flags: `--worktree`, `--type <type>`, `--grid NxM`, `--reserved`, `--workers N`, `--name <name>`, `--task-id <id>`. | `doey add-window --type freelancer --workers 4` |
| `doey kill-window <idx>` / `doey kill-team <idx>` | `shell/doey.sh:542-547` | Kill a team window by window index. | `doey kill-team 2` |
| `doey list-windows` / `doey list-teams` | `shell/doey.sh:548-552` | Show all team windows and their status. | `doey list-teams` |
| `doey teams` | `shell/doey.sh:553-576` | List available premade and project team definitions (`*.team.md`). | `doey teams` |

### 1.3 Planning, deployment, and remote

| Subcommand | Source | Description | Example |
|---|---|---|---|
| `doey masterplan "<goal>"` / `doey plan "<goal>"` | `shell/doey.sh:429-502` | Spawn a masterplan team (interview + planner + critics) for a goal. Creates a task, writes `<runtime>/<plan_id>/plan.md`, and dispatches the `masterplan` team definition. | `doey plan "rewrite onboarding"` |
| `doey plan list\|get\|create\|update\|delete` | `shell/doey.sh:432-441` | Routed to `doey-ctl plan` (see section 2). | `doey plan list` |
| `doey plan to-tasks <plan_file>` | `shell/doey.sh:442-460` | Convert a CONSENSUS masterplan markdown file into tasks + subtasks via `plan-to-tasks.sh`. | `doey plan to-tasks /tmp/doey/myproj/masterplan-*.md` |
| `doey deploy [start\|gate\|...]` | `shell/doey.sh:364-375` | Deployment validation pipeline. Requires a running session. | `doey deploy start` |
| `doey remote [list\|<name>\|stop <name>\|status <name>\|provision ...]` | `shell/doey.sh:280-287` (`shell/doey-remote.sh`) | Manage remote Hetzner servers. | `doey remote my-app` |
| `doey tunnel <up\|down\|status\|detect>` | `shell/doey.sh:577-628` | Manage the SSH tunnel for the running session. | `doey tunnel up` |

### 1.4 Configuration and tooling

| Subcommand | Source | Description | Example |
|---|---|---|---|
| `doey config` (bare) | `shell/doey.sh:332-362` | Open the local config editor (project if `.doey/` exists, else global). |
| `doey config show` | same | Show the resolved config with source attribution. |
| `doey config --global` / `--reset` | same | Edit global config / reset config to defaults. |
| `doey config get\|set\|list\|delete` | same | Routed to `doey-ctl config` (DB-backed key/value config). | `doey config set foo=bar` |
| `doey settings` | `shell/doey.sh:331` | Open the interactive settings editor window. |
| `doey scaffy <args...>` | `shell/doey.sh:288-296` | Forward to `doey-scaffy` (template engine). |
| `doey build` | `shell/doey.sh:267-279` | Build the in-tree Go binaries via `_build_all_go_binaries`. |
| `doey test [...]` | `shell/doey.sh:325-330` (`shell/doey-test-runner.sh`) | Run the E2E integration test. Flags: `--keep`, `--open`, `--grid NxM`. | `doey test --grid 4x3 --keep` |
| `doey test dispatch` | same | Test the dispatch chain reliability against a running session. |
| `doey help` / `--help` / `-h` | `shell/doey.sh:171-243` | Print the help block. |
| `doey --post-update <arg>` | `shell/doey.sh:258` | Internal: post-install hook used by the updater. |

Anything that does not match the dispatch table above falls through to the
intent-fallback layer (`shell/doey-intent-dispatch.sh`, called from
`shell/doey.sh:661-668`). See `docs/intent-fallback.md`.

---

## 2. `doey-ctl` command

Source: `tui/cmd/doey-ctl/` (Go). Installed binary: `~/.local/bin/doey-ctl`.
This is the orchestration CLI used both by humans and by hooks. Every group
supports `--json` for machine output, and reads `DOEY_RUNTIME` / `SESSION_NAME`
from the environment.

```
doey-ctl <group> <subcommand> [flags]
```

Top-level help: `tui/cmd/doey-ctl/main.go` → `doey-ctl --help`.

### 2.1 `doey-ctl msg` — pane-to-pane messaging

`doey-ctl msg <send|read|read-all|mark-read|list|count|clean|trigger>`

`send` flags (`doey-ctl msg send -h`):

| Flag | Type | Description |
|---|---|---|
| `--from` | string | Sender identifier (pane safe name or role label). |
| `--to` | string | Target pane safe name (e.g. `1.0`, `doey-doey:2.1`). |
| `--subject` | string | Message subject (free-form, but use one of the canonical subjects in `messaging.md`). |
| `--body` | string | Message body. |
| `--task-id` | int | Associated task ID (DB mode). |
| `--project-dir` | string | Project directory. |
| `--runtime` | string | Runtime directory (defaults to `DOEY_RUNTIME`). |
| `--no-nudge` | bool | Skip the tmux send-keys nudge to the target pane after delivery. |
| `--verify` | bool | Verify delivery by checking target pane activity / status change. |
| `--verify-timeout` | int | Seconds to wait for delivery verification (default 10). |
| `--json` | bool | JSON output. |

Other `msg` subcommands:

| Subcommand | What it does |
|---|---|
| `read --to <pane>` | Read pending messages for a pane. `--unread` filters to new only. |
| `read-all --to <pane>` | Read all messages for a pane and mark them read. |
| `mark-read --to <pane>` | Mark all messages for a pane as read (no output). |
| `list` | List messages (DB mode). |
| `count --to <pane>` | Count unread messages. Used by `taskmaster-wait.sh:492`. |
| `clean` | Clean processed messages. |
| `trigger --to <pane>` | Touch the trigger file for a pane (wakes its wait loop). |

### 2.2 `doey-ctl status` — pane status

`doey-ctl status <get|set|list|observe>`

`set` flags (`doey-ctl status set -h`):

| Flag | Description |
|---|---|
| `--pane` / `--pane-id` | Pane identifier (e.g. `W1.2`). |
| `--status` | Status value (e.g. `BUSY`, `READY`, `FINISHED`, `RESERVED`, `CRASHED`, `RESPAWNING`). |
| `--task-id` / `--task-title` / `--task` | Current task association. |
| `--role` / `--agent` | Pane role / agent name (DB mode). |
| `--window-id` / `--project-dir` / `--runtime` | Scoping. |
| `--json` | JSON output. |

`status observe <pane>` returns the canonical activity signal as JSON
(spinner indicator, status, heartbeat ages). This is the preferred way to
decide if a pane is active or idle — see CLAUDE.md "STATUS CHECK PROTOCOL".

### 2.3 `doey-ctl task` — task management

`doey-ctl task <create|update|list|get|delete|subtask|log|decision|export|done|start|pause|block|ready|failed|cancel|confirm>`

`create` flags (`doey-ctl task create -h`):

| Flag | Description |
|---|---|
| `--title` (required) | Task title. |
| `--type` | Task type (default `task`). |
| `--description` | Task description. |
| `--intent` | Task intent / user goal. |
| `--phase` | `research`, `review`, or `implementation`. |
| `--priority` | Integer (lower = higher). |
| `--shortname` | Auto-generated from title if empty. |
| `--depends-on` | Comma-separated task IDs this task depends on. |
| `--plan-id` | Plan ID (DB mode). |
| `--team` | Team name (DB mode). |
| `--dispatch-mode` | Dispatch mode. |
| `--created-by` | Creator name. |
| `--origin-prompt` / `--origin-prompt-file` | Verbatim user message that triggered the task. |
| `--project-dir` | Project directory. |
| `--json` | JSON output. |

Transition subcommands (`done`, `start`, `pause`, `block`, `ready`, `failed`,
`cancel`, `confirm`) accept multiple IDs. `done` marks a task done, `start`
moves to `in_progress`, `ready` to `active`, `confirm` to
`pending_user_confirmation`, etc.

Sub-groups:

| Group | Subcommands |
|---|---|
| `doey-ctl task subtask` | `add`, `update`, `list` |
| `doey-ctl task log` | `add`, `list` |
| `doey-ctl task decision` | `add` |
| `doey-ctl task export` | export tasks to JSON |

### 2.4 Other `doey-ctl` groups

| Group | Subcommands | Source |
|---|---|---|
| `doey-ctl health` | check pane liveness | `tui/cmd/doey-ctl/observe_cmd.go` |
| `doey-ctl tmux` | tmux session operations | `tui/cmd/doey-ctl/commands.go` |
| `doey-ctl plan` | `list`, `get`, `create`, `update`, `delete` | `tui/cmd/doey-ctl/store_cmds.go` |
| `doey-ctl team` | `list`, `get`, `set`, `delete` | same |
| `doey-ctl config` | `get`, `set`, `list`, `delete` | same |
| `doey-ctl agent` | `list`, `get`, `set`, `delete` | same |
| `doey-ctl event` | `log`, `list` | `tui/cmd/doey-ctl/store_cmds.go` |
| `doey-ctl error` | `list`, `search` | same |
| `doey-ctl interaction` | interaction events | `tui/cmd/doey-ctl/interaction_cmds.go` |
| `doey-ctl nudge [--all] [--cascade] [--prompt <text>] [pane]` | Unstick Claude instances (Escape + re-prompt). `--cascade` also nudges the team Subtaskmaster and the Taskmaster. `--all` nudges all stuck panes (skips `READY` and `RESERVED`). | `tui/cmd/doey-ctl/commands.go` |
| `doey-ctl migrate` | run database migrations | `tui/cmd/doey-ctl/store_cmds.go` |
| `doey-ctl briefing` | live state dashboard (tasks, workers, activity) | `tui/cmd/doey-ctl/commands.go` |
| `doey-ctl stats` | `emit`, `query` | `tui/cmd/doey-ctl/stats.go`, `stats_tasks.go` |

Environment variables read by every group:

| Var | Default | Purpose |
|---|---|---|
| `DOEY_RUNTIME` | `/tmp/doey/<project>/` | Runtime directory. |
| `SESSION_NAME` | (none) | Tmux session name. |

Universal flags: `--json` (machine output), `--help`.

---

## 3. Sourceable shell library functions

These functions live in `shell/doey-*.sh` modules and may be sourced from
other Doey scripts. Loaded via `shell/doey.sh` and `shell/doey-*.sh` chains.

| Function | File | What it does |
|---|---|---|
| `doey_send_verified <target> <message> [skip_precheck]` | `shell/doey-send.sh:187` | Canonical send-keys helper. Acquires a per-pane lock, waits for the Claude prompt (`❯`), pre-clears input, injects via `tmux set-buffer`+`paste-buffer`, settles, sends Enter, then polls for `BUSY` or activity indicators. Up to 4 retries with backoff. Returns 0 on success, 1 on failure, 2 if the precheck queued the message. |
| `doey_send_command <target> <cmd>` | `shell/doey-send.sh:322` | Fire-and-forget shell command into a pane (no readiness gate, no verification). |
| `doey_wait_for_prompt <target> <timeout_s>` | `shell/doey-send.sh` | Poll `tmux capture-pane` until the `❯` prompt is visible. |
| `_doey_send_check_activity <captured>` | `shell/doey-send.sh:18` | Return 0 if the captured pane output shows Claude tool-use markers. |
| `_doey_send_check_busy <target>` | `shell/doey-send.sh:25` | Return 0 if the target pane's status file shows `STATUS: BUSY`. |
| `_doey_send_lock <pane_safe>` / `_doey_send_unlock` | `shell/doey-send.sh:42` | Atomic per-pane mkdir lock with stale-lock cleanup (>30s). |
| `ensure_taskmaster_alive` | `shell/doey-ipc-helpers.sh` | Verify the Taskmaster pane is alive before dispatch. |
| `send_msg_to_taskmaster` | `shell/doey-ipc-helpers.sh` | Send a message to the Taskmaster pane (writes to `<runtime>/messages/`). |
| `find_project <dir>` | `shell/doey-helpers.sh` | Look up the registered project name for a directory. |
| `find_project_by_name <query>` | `shell/doey-helpers.sh` | Fuzzy lookup by name → `name:path`. |
| `session_exists <session>` | `shell/doey-helpers.sh` | True if the tmux session is alive. |
| `register_project <dir>` | `shell/doey-helpers.sh` | Register a directory as a Doey project. |
| `read_team_windows <runtime>` | `shell/doey-helpers.sh` | Enumerate team windows from `<runtime>/team_*.env`. |
| `team_state_get` / `team_state_set` | `shell/doey-helpers.sh` | Read/write team-window state values. |
| `task_create` / `task_read` / `task_update_field` / `task_update_status` / `task_list` | `shell/doey-task-helpers.sh` | Direct file-mode CRUD on `.doey/tasks/<id>.task`. The DB-backed equivalents live in `doey-ctl task`. |
| `task_add_subtask` / `task_update_subtask` | `shell/doey-task-helpers.sh` | Subtask management (file mode). |
| `task_add_decision` / `task_add_note` / `task_add_related_file` | `shell/doey-task-helpers.sh` | Append-only task log helpers. |
| `task_dir <project_dir>` / `task_next_id <tasks_dir>` | `shell/doey-task-helpers.sh` | Path + id allocation helpers. |
| `_generate_shortname <title>` | `shell/doey-task-helpers.sh` | Slugify a title (≤16 chars, lowercase, stop-words removed). |
| `init_hook` / `init_named_hook <name>` | `.claude/hooks/common.sh:56` | Bootstraps a hook: reads `INPUT` from stdin, resolves `RUNTIME_DIR`, computes `PANE`, `PANE_SAFE`, `SESSION_NAME`, `PANE_INDEX`, `WINDOW_INDEX`, `NOW`. |
| `parse_field <name>` | `.claude/hooks/common.sh:229` | Extract a field from the hook JSON (jq preferred, grep fallback). |
| `_parse_tool_field <field>` | `.claude/hooks/common.sh:104` | Parse a tool-input field by dotted name. |
| `team_role` / `is_manager` / `is_taskmaster` / `is_boss` / `is_worker` / `is_planner` / `is_task_reviewer` / `is_deployment` / `is_doey_expert` / `is_core_team` | `.claude/hooks/common.sh:252-330` | Role predicates for the current pane. |
| `get_taskmaster_pane` / `get_core_team_window` | `.claude/hooks/common.sh:299-309` | Resolve the Taskmaster pane and Core Team window index. |
| `send_to_pane <target> <text>` | `.claude/hooks/common.sh:334` | Hook-side wrapper around `doey_send_verified`. |
| `sanitize_message <text>` | `.claude/hooks/common.sh:352` | Strip control characters and tmux-unsafe sequences. |
| `is_reserved` | `.claude/hooks/common.sh:361` | True if the current pane is reserved. |
| `_pane_alive <pane>` | `.claude/hooks/common.sh:369` | True if the tmux pane exists and has a live process. |
| `write_pane_status <file> <status> <task>` | `.claude/hooks/common.sh:391` | Atomic pane status write (used as fallback when `doey-ctl status set` is unavailable). |
| `transition_state <from> <to>` | `.claude/hooks/common.sh:408` | Validate + execute a pane status transition against the state machine. |
| `notify_taskmaster <event>` | `.claude/hooks/common.sh:487` | Lifecycle event → Taskmaster wake trigger. (Note: as of `common.sh:498` the explicit Taskmaster wake trigger is removed; `stop-notify.sh` is the sole wake source.) |
| `send_notification <key> <title> <body>` | `.claude/hooks/common.sh:517` | Cooldown-gated desktop notification. |
| `doey_log_error <category> <message>` | `.claude/hooks/common.sh:211` | Append a structured error to `<runtime>/errors/errors.log`. |
| `atomic_write <file> <content>` | `.claude/hooks/common.sh:389` | `tmp+mv` atomic file write. |

---

## 4. Hook contract

Hooks live in `.claude/hooks/` and are triggered by Claude Code based on
events. They all source `common.sh` (which defines `init_hook` /
`init_named_hook`) and inherit the env vars set by `on-session-start.sh`.

### 4.1 Env vars injected by `on-session-start.sh`

Set on `Session start` and exported into every hook process
(`.claude/hooks/on-session-start.sh:166-178`):

| Variable | Source line | Meaning |
|---|---|---|
| `DOEY_RUNTIME` | `:166` | Per-project runtime dir (`/tmp/doey/<project>/`). |
| `DOEY_ROLE` | `:170` | Internal role id (`coordinator`, `boss`, `team_lead`, `worker`, `task_reviewer`, `deployment`, `doey_expert`, `freelancer`, `info_panel`). |
| `DOEY_PANE_INDEX` | `:171` | Pane index within the window. |
| `DOEY_WINDOW_INDEX` | `:172` | Window index. |
| `DOEY_TEAM_WINDOW` | `:173` | The owning team window (or own window for core team). |
| `DOEY_TEAM_DIR` | `:174` | Project directory or worktree directory if the team is on a worktree. |
| `DOEY_PANE_ID` | `:176` | Stable human-friendly pane id (e.g. `taskmaster`, `boss`, `t2-mgr`, `t2-w1`). |
| `DOEY_PANE_SAFE` | `:178` | tmux-target → safe filename form (`session_window_pane`). |
| `DOEY_TEAM_ROLE` (optional) | `:202` | Team-level role label, when set in the team env. |
| `DOEY_TEAM_PANE_NAME` (optional) | `:203` | Pane label inside a team. |

### 4.2 Hook table

Hooks are registered via `~/.claude/settings.json` (set up by `install.sh` and
`on-session-start.sh`). All hook scripts are bash 3.2 compatible.

| Hook script | Event | Exit codes | Purpose |
|---|---|---|---|
| `common.sh` | (sourced library) | — | Shared helpers: `init_hook`, role predicates, status writes, notifications, debug logging. |
| `on-session-start.sh` | `SessionStart` | `0` always | Inject `DOEY_*` env vars into the Claude Code process. Exits 0 on every short-circuit (no tmux, no runtime, etc.). |
| `on-prompt-submit.sh` | `UserPromptSubmit` | `0` | Set pane status to `BUSY`, restore collapsed columns, persist `DOEY_TASK_ID` to `<runtime>/status/<pane>.task_id`. |
| `on-pre-tool-use.sh` | `PreToolUse` | `0` allow / `2` block + feedback | Role-based tool guards (see "Tool restrictions" in CLAUDE.md). Universal credential check on `git commit` (`:547-553`). Universal force-push and main-branch push guards (`:725-758`). |
| `post-tool-lint.sh` | `PostToolUse` (Write/Edit on `*.sh`) | `0` / `2` | Bash 3.2 compatibility lint. Catches `declare -A`, `mapfile`, `&>>`, etc. |
| `on-pre-compact.sh` | `PreCompact` | `0` | Preserve task context, role identity, recent file list across compaction. |
| `stop-status.sh` | `Stop` (sync) | `0` / `2` block | Set `FINISHED`/`READY`/`RESERVED`/`RESPAWNING` status. Workers are blocked from stopping until they emit `PROOF_TYPE:` to `<runtime>/proof/<pane>.proof` (unless `DOEY_PROOF_EXEMPT=1`) and, for research tasks, until a report file exists (`stop-status.sh:18-37`). |
| `stop-results.sh` | `Stop` (async) | `0` | Capture worker output, files changed, tool counts → `<runtime>/results/pane_<W>_<P>.json`. |
| `stop-notify.sh` | `Stop` (async) | `0` | Notification chain: Worker → Subtaskmaster → Taskmaster → desktop. Writes to `<runtime>/messages/` and touches trigger files in `<runtime>/triggers/`. |
| `stop-plan-tracking.sh` | `Stop` (async) | `0` | Update plan tracking on stop. |
| `stop-recovery.sh` | `Stop` (async) | `0` | Recovery actions on stop. |
| `stop-respawn.sh` | `Stop` (async) | `0` | Honour `<runtime>/respawn/<pane>.request` to relaunch the pane. |
| `stop-enforce-ask-user-question.sh` | `Stop` | `0` / `2` | Block stops from Boss/Subtaskmaster that ended on an inline question instead of `AskUserQuestion`. See `docs/enforce-ask-user-question.md`. |
| `taskmaster-wait.sh` | Idle wait (Taskmaster + Core Team passive panes) | `0`; prints `WAKE_REASON=<MSG\|TRIGGERED\|FINISHED\|CRASH\|STALE\|RESTART\|BOOT_STUCK\|QUEUED\|ALL_DONE\|TIMEOUT>` | Multi-trigger sleep: messages, results, crash alerts, stale heartbeats, trigger files, ALL_DONE detection in passive mode. Uses `inotifywait` if available. |
| `reviewer-wait.sh` | Idle wait (Task Reviewer) | `0` | Wait for `<runtime>/status/reviewer_trigger` or `<runtime>/triggers/reviewer_*`. |
| `on-notification.sh` | `Notification` | `0` | Notification routing into the desktop notification chain. |
| `post-push-complete.sh` | After `git push` | `0` | Post-push housekeeping. |

Deprecated, kept for compatibility:

| Hook | Status |
|---|---|
| `watchdog-scan.sh` | DEPRECATED (kept on disk; not invoked). |
| `watchdog-wait.sh` | DEPRECATED. |

### 4.3 Hook exit-code convention

| Code | Meaning |
|---|---|
| `0` | Allow — let Claude Code proceed. |
| `1` | Block + error. The harness surfaces the error to the user. |
| `2` | Block + feedback. The hook prints a message to stderr that Claude Code shows back to the agent. Used by `on-pre-tool-use.sh` for nearly every guard, and by `stop-status.sh` when the proof gate fails. |

Hook stderr shows up in the agent's tool-output stream when exit code is `2`,
so always print a one-line, self-explanatory `BLOCKED:` or `FORWARDED:`
message before exiting.
