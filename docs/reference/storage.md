# Doey Storage Reference

Where Doey keeps state, what the files look like, and which process writes them.

All paths below are authoritative — every claim is grounded in a file in this
repo (absolute paths provided). Doey has two storage tiers:

- **Persistent** — survives reboots. Lives under `<project>/.doey/` and
  `~/.config/doey/`. Safe to commit or back up.
- **Ephemeral** — disappears on reboot or session stop. Lives under
  `/tmp/doey/<project>/` (`RUNTIME_DIR`). Written by hooks and CLI.

The SQLite database `<project>/.doey/doey.db` is the primary store for
tasks, messages, pane statuses, and events. File-based artifacts in
`.doey/tasks/` and `RUNTIME_DIR/` remain as the fallback and as the
read-path for tmux status scripts, shell hooks, and migration.

## 1. Layout summary

### Persistent (per-project)

| Path | Purpose | Writer |
|------|---------|--------|
| `<project>/.doey/doey.db` | SQLite: tasks, messages, pane statuses, events, attachments | `doey-ctl` (tui/cmd/doey-ctl/) |
| `<project>/.doey/doey.db-wal`, `doey.db-shm` | SQLite WAL + shared-memory index | SQLite |
| `<project>/.doey/stats.db` (+WAL/SHM) | Stats SQLite | `shell/doey-stats-emit.sh` |
| `<project>/.doey/tasks/<id>.task` | Task file (bash KEY=VALUE, v3 schema) | `shell/doey-task-helpers.sh` |
| `<project>/.doey/tasks/.next_id` | Next task ID counter | `shell/doey-task-helpers.sh` |
| `<project>/.doey/tasks/<id>.status` | Terminal status written by `stop-status.sh` | `.claude/hooks/stop-status.sh:110` |
| `<project>/.doey/tasks/<id>.result.json` | Copy of final result JSON for a task | `.claude/hooks/stop-results.sh:357` |
| `<project>/.doey/tasks/<id>.report` | Copy of pane report file | `.claude/hooks/stop-results.sh:363` |
| `<project>/.doey/tasks/<id>/attachments/` | Completion/research/media attachments | `.claude/hooks/stop-results.sh:370` |
| `<project>/.doey/task-attachments/` | Misc task attachment store | product code |
| `<project>/.doey/plans/` | Masterplan drafts and consensus docs | `shell/masterplan-*.sh` |
| `<project>/.doey/reports/`, `research/`, `scratch/` | Worker report/research/scratch checked in long-term | hooks + workers |
| `<project>/.doey/violations/` | Hook rule violations | `.claude/hooks/common.sh` (`_violations_dir`) |
| `<project>/.doey/config.sh` | Project-scoped config overrides | user |
| `<project>/.doey/*.team.md` | Team definitions | user |
| `~/.config/doey/config.sh` | Global config overrides | user (template: `shell/doey-config-default.sh`) |
| `~/.config/doey/teams.json`, `teams/`, `remotes/`, `tunnel.conf` | Global team/remote metadata | `shell/doey-team-mgmt.sh`, `doey-remote*.sh` |

### Ephemeral (runtime)

Runtime root: `RUNTIME_DIR="/tmp/doey/<project>"`, set in
`shell/doey-session.sh:616` and exported via `tmux set-environment DOEY_RUNTIME`.

| Path | Purpose | Writer |
|------|---------|--------|
| `RUNTIME_DIR/session.env` | Session manifest (shell-sourceable KEY=VALUE) | `shell/doey-session.sh:607` |
| `RUNTIME_DIR/team_<N>.env` | Per-window team manifest | `shell/doey-team-mgmt.sh` |
| `RUNTIME_DIR/status/<pane_safe>.status` | Current pane state (`PANE/UPDATED/STATUS/TASK`) | `.claude/hooks/common.sh:405` (`write_pane_status`) |
| `RUNTIME_DIR/status/<pane_safe>.heartbeat` | Liveness marker | hooks (`stop-status.sh:105`) |
| `RUNTIME_DIR/status/<pane_safe>.task_id`, `.subtask_id` | Current task/subtask for hooks | `.claude/hooks/on-prompt-submit.sh` |
| `RUNTIME_DIR/status/<pane_safe>.tool_used_this_turn` | One-shot per turn | `.claude/hooks/on-pre-tool-use.sh` |
| `RUNTIME_DIR/status/<pane_safe>.launch_cmd` | Last launch command | `shell/doey-session.sh` |
| `RUNTIME_DIR/status/<pane_safe>.role` | Role identity cache | `.claude/hooks/on-session-start.sh` |
| `RUNTIME_DIR/status/<pane_safe>.busy_started_ms` | Busy-duration start ms | `.claude/hooks/on-prompt-submit.sh` |
| `RUNTIME_DIR/status/context_pct_<W>_<P>` | Context percentage per pane | TUI / hooks |
| `RUNTIME_DIR/status/completion_pane_<W>_<P>` | Fire-and-forget completion event | `.claude/hooks/stop-results.sh:454` |
| `RUNTIME_DIR/status/taskmaster_trigger` | Wake flag for Taskmaster | `shell/doey-ipc-helpers.sh:90`, `stop-status.sh:196` |
| `RUNTIME_DIR/status/notif_cooldown_<key>` | Dedup timestamp for notifications | `.claude/hooks/common.sh:101` |
| `RUNTIME_DIR/messages/<safe>_<epoch>_<pid>.msg` | Plain-text inter-pane message | `shell/doey-ipc-helpers.sh:100`, `stop-notify.sh:36` |
| `RUNTIME_DIR/triggers/<pane_safe>.trigger` | Wake flag for a specific pane | `shell/doey-ipc-helpers.sh:104`, `stop-notify.sh:39` |
| `RUNTIME_DIR/results/pane_<W>_<P>.json` | Structured worker result | `.claude/hooks/stop-results.sh:14` |
| `RUNTIME_DIR/reports/<pane_safe>.report` | Research report (required before stop) | worker Write tool, validated by `stop-status.sh:18` |
| `RUNTIME_DIR/research/<pane_safe>.task` | Active research assignment marker | `shell/doey-*.sh` |
| `RUNTIME_DIR/proof/<pane_safe>.proof` | `PROOF_TYPE:`/`PROOF:` stanza | worker Bash, required by `stop-status.sh:27` |
| `RUNTIME_DIR/recovery/<pane_safe>.recovering` | Recovery-in-progress marker | recovery hook |
| `RUNTIME_DIR/respawn/<pane_safe>.request` | Respawn request flag | `/doey-respawn-me` skill |
| `RUNTIME_DIR/tasks/` | Cache of `.task` files for TUI (best-effort mirror of `.doey/tasks/`) | `shell/doey-task-cli.sh:169` |
| `RUNTIME_DIR/plans/<id>/` | Plan viewer runtime state | `shell/plan-viewer.sh`, `plan-to-tasks.sh` |
| `RUNTIME_DIR/activity/<pane>.jsonl` | JSONL activity log | `.claude/hooks/common.sh:469` (`write_activity`) |
| `RUNTIME_DIR/logs/` | Hook and subsystem logs | hooks (all) |
| `RUNTIME_DIR/errors/errors.log` | Hook ERR trap log | `.claude/hooks/common.sh:54` |
| `RUNTIME_DIR/issues/state_transitions.log` | Invalid state-machine transitions | `.claude/hooks/common.sh:459` |
| `RUNTIME_DIR/broadcasts/` | Fan-out messages | `shell/doey-send.sh` |
| `RUNTIME_DIR/daemon/` | `doey-daemon` pids, logs | `shell/doey-session.sh:649` |
| `RUNTIME_DIR/doey-router.pid`, `doey-daemon.pid` | Launcher pidfiles | `shell/doey-session.sh:641,649` |
| `RUNTIME_DIR/session_id` | Opaque session identity | `shell/doey-session.sh` |
| `RUNTIME_DIR/trace.jsonl` | Trace events | daemons |
| `RUNTIME_DIR/wait-state-<pane_safe>.json` | Wait-hook state | `.claude/hooks/taskmaster-wait.sh` |
| `RUNTIME_DIR/mcp/`, `mcp/pids/` | MCP server state | `shell/doey-mcp.sh` |
| `RUNTIME_DIR/scratch/`, `scratchpad/` | Free-form worker scratch | workers |
| `RUNTIME_DIR/startup-progress/` | Init progress markers | `shell/doey-session.sh` |

Directory creation guarantees live in:

- `.claude/hooks/common.sh:117` — `_ensure_dirs` creates
  `status/ research/ reports/ results/ messages/ logs/ errors/`.
- `shell/doey.sh:824` — session setup creates
  `messages broadcasts status logs mcp mcp/pids`.

## 2. `.task` file schema (v3)

Defined in `shell/doey-task-helpers.sh:19` with
`_TASK_SCHEMA_VERSION_CURRENT="3"`. Format is a bash `KEY=VALUE` file, one
field per line. Values are raw strings — multi-line content is encoded
with escape markers or pipe-separated.

### Field catalogue

| Field | Type | Meaning |
|-------|------|---------|
| `TASK_SCHEMA_VERSION` | int | Schema version (`3`). |
| `TASK_ID` | int | Primary key, matches filename `<id>.task`. |
| `TASK_TITLE` | string | One-line title. |
| `TASK_STATUS` | enum | `draft active in_progress paused blocked pending_user_confirmation done cancelled` (+`failed`, CLI-only, see `doey-task-cli.sh:102`). |
| `TASK_TYPE` | enum | `bug feature bugfix refactor research audit docs infrastructure` (`doey-task-helpers.sh:17`). Defaults to `feature`. |
| `TASK_TAGS` | string | Comma/space-delimited tags. |
| `TASK_CREATED_BY` | string | Originating role, defaults to `Boss`. |
| `TASK_ASSIGNED_TO` | string | Pane id or role. |
| `TASK_DESCRIPTION` | string | Free-form description. |
| `TASK_ACCEPTANCE_CRITERIA` | string | Checklist text. |
| `TASK_HYPOTHESES` | string | Worker hypotheses. |
| `TASK_DECISION_LOG` | `epoch:text` entries, newline-joined | Append-only decisions. |
| `TASK_SUBTASKS` | `N:title:status` entries, `\n`-joined | Subtask list. `N` is the subtask ordinal. |
| `TASK_RELATED_FILES` | pipe-joined paths | Linked files. |
| `TASK_BLOCKERS` | string | Blocker text. |
| `TASK_TIMESTAMPS` | `key=epoch\|key=epoch\|…` | `created=`, `started=`, `done=`, `failed=`, etc. Parser in `doey-task-helpers.sh:209`. |
| `TASK_CURRENT_PHASE`, `TASK_TOTAL_PHASES` | int | Phase counters. |
| `TASK_NOTES` | string | Free-form notes. |
| `TASK_SUCCESS_CRITERIA` | pipe-joined strings | Consumed by `stop-results.sh:206` for auto verification. |
| `TASK_SHORTNAME` | string | Generated slug from title. |
| `TASK_UPDATED` | epoch | Touched on every field update via `_touch_task_updated` (`doey-task-helpers.sh:40`). |
| `TASK_FILES` | comma/CSV | Files changed (mirrored into DB in `stop-results.sh:435`). |
| `TASK_ATTACHMENTS` | pipe-joined paths | Legacy field. Populated by `stop-results.sh:23` via `_append_attachment`. |
| `TASK_SUBTASK_<N>_TITLE`, `..._STATUS`, `..._WORKER`, `..._CREATED_AT`, `..._COMPLETED_AT` | mixed | Expanded subtask records written by `doey_task_update_subtask` in `doey-task-helpers.sh`. |

### Subtask encoding

Subtasks live in two forms:

1. Compact list: `TASK_SUBTASKS=1:W2.1: Phase 1 validate…:done\n2:W2.1: Cluster A …:done\n…`
   — used for display, newline-escaped.
2. Expanded records: `TASK_SUBTASK_<N>_TITLE=…`, `TASK_SUBTASK_<N>_STATUS=…`,
   `TASK_SUBTASK_<N>_WORKER=…`, `TASK_SUBTASK_<N>_CREATED_AT=…`,
   `TASK_SUBTASK_<N>_COMPLETED_AT=…` — written by `doey_task_update_subtask`
   inside `shell/doey-task-helpers.sh`.

Valid subtask statuses (`doey-task-helpers.sh:18`):
`pending in_progress done skipped failed`.

### Reports

Completion and research reports are attached back into
`<project>/.doey/tasks/<id>/attachments/` and referenced by
`TASK_ATTACHMENTS`. See `stop-results.sh:370` and `:387`. Reports also
get appended to the task via `doey_task_add_report` (`stop-results.sh:420`).

### Minimal example

```
TASK_SCHEMA_VERSION=3
TASK_ID=576
TASK_TITLE=Write storage and cookbook docs
TASK_STATUS=in_progress
TASK_TYPE=docs
TASK_CREATED_BY=Boss
TASK_DESCRIPTION=Write two reference docs from the code, no invention
TASK_DECISION_LOG=1776104200:Created task
TASK_SUBTASKS=1:Worker read source:done\n2:Worker write docs:in_progress
TASK_TIMESTAMPS=created=1776104200|started=1776104300
TASK_CURRENT_PHASE=0
TASK_TOTAL_PHASES=0
TASK_UPDATED=1776104300
```

### Concurrency

`task_update_field` (`doey-task-helpers.sh:238`) performs an atomic
upsert: `sed` to a `.tmp` copy and `mv` back. One worker per task file
is enforced socially via the dispatcher — the file format is not
lock-protected. When `doey-ctl` is available, mutations go through
SQLite (`.doey/doey.db`), which is the source of truth; the `.task`
file is written through for compatibility.

## 3. Pane status file format

Writer: `.claude/hooks/common.sh:391` (`write_pane_status`).
Reader: `.claude/hooks/common.sh:376` (`_read_pane_status`).

Canonical form is four `KEY: VALUE` lines (colon + space):

```
PANE: doey_doey_1_0
UPDATED: 2026-04-13T18:40:49+0000
STATUS: BUSY
TASK:
```

Additional lines may be appended later:

| Line | Source |
|------|--------|
| `TASK_ID: <id>` | `stop-status.sh:90` |
| `LAST_TASK_TAGS:`, `LAST_TASK_TYPE:`, `LAST_FILES:` | `stop-status.sh:92` |
| `ACTIVITY: <prompt prefix>`, `SINCE: <epoch>` | `on-prompt-submit.sh` |
| `TOOL: <name>`, `LAST_ACTIVITY: <ts>` | `on-pre-tool-use.sh` |

Runtime fields (`TOOL:`, `ACTIVITY:`, `SINCE:`, `LAST_ACTIVITY:`) are
stripped on stop by `stop-status.sh:100`.

### State machine

From `transition_state` in `.claude/hooks/common.sh:408`:

```
BOOTING  → READY
READY    → BUSY
BUSY     → FINISHED | ERROR | RESERVED | RESPAWNING
FINISHED → READY
ERROR    → READY
```

Invalid transitions are logged to `RUNTIME_DIR/issues/state_transitions.log`.

### Filename

`PANE_SAFE` is the pane key. It is produced by replacing `:`, `.`, `-`
with `_` in a `session:window.pane` string
(`.claude/hooks/common.sh:64`), so pane `doey-doey:1.0` becomes
`doey_doey_1_0`. Two files may exist per pane: one under `PANE_SAFE`
and one under `DOEY_PANE_ID` (`stop-status.sh:81`).

### DB mirror

`statusSet` in `tui/cmd/doey-ctl/main.go:771` writes both to
`.doey/doey.db` (`UpsertPaneStatus`) and to the runtime file
(`ctl.WriteStatus`). Tmux border scripts depend on the file form.

## 4. Message file format

Writer: `send_msg_to_taskmaster` (`shell/doey-ipc-helpers.sh:66`),
`_send_message_file` (`.claude/hooks/stop-notify.sh:33`), and
`ctl.WriteMsg` via `doey msg send` (`tui/cmd/doey-ctl/main.go:224`).

Filename: `<target_safe>_<epoch>_<pid>.msg` where `<target_safe>` is
the recipient's `PANE_SAFE`. Example from a live runtime:
`doey_doey_1_0_1776097610_1188302.msg`.

Body is flat text:

```
FROM: <sender_pane_safe_or_role>
SUBJECT: <short subject>
<free-form body, newline-terminated>
```

Written atomically as `${msg_file}.tmp` then `mv` into place. A trigger
is always touched alongside:

- `RUNTIME_DIR/triggers/<target_safe>.trigger`
- `RUNTIME_DIR/status/taskmaster_trigger` (when targeting Taskmaster)

### DB mirror

When `doey-ctl` is installed and `.doey/doey.db` exists, `doey msg send`
writes to SQLite via `store.SendMessage` (`tui/cmd/doey-ctl/main.go:266`)
and cleans messages older than 1 hour with `CleanOldMessages(time.Hour)`.
Flat-file delivery is used only when the DB path fails
(`tui/cmd/doey-ctl/main.go:275`).

CLI subcommands (`main.go:202`):

| Subcommand | Purpose |
|------------|---------|
| `send` | Deliver a message. Flags: `--from --to --subject --body --task-id --runtime --project-dir --verify --verify-timeout --no-nudge --json`. |
| `read` | Read messages for a pane. `--pane <safe>`. |
| `read-all` | Mark-and-drain. `--to` or `--pane`. |
| `mark-read` | Flip the read bit. |
| `list` | List unread (DB only). |
| `count` | Count unread for `--to`. |
| `clean` | Purge old messages for `--pane`. |
| `trigger` | Touch the trigger for a pane without sending a message. |

## 5. Result JSON

Writer: `.claude/hooks/stop-results.sh:324`.

Location: `RUNTIME_DIR/results/pane_<WINDOW_INDEX>_<PANE_INDEX>.json`,
copied to `<project>/.doey/tasks/<task_id>.result.json` when a task id
is known (`stop-results.sh:357`).

Written atomically via `mktemp` + `mv` (`stop-results.sh:307`).

Schema:

```json
{
  "pane":             "1.2",
  "pane_id":          "doey_doey_1_2",
  "full_pane_id":     "doey-doey:1.2",
  "title":            "⠂ T1 W2",
  "status":           "done | error",
  "timestamp":        1776104142,
  "files_changed":    ["path/one.sh", "path/two.md"],
  "tool_calls":       14,
  "last_output":      {
    "text":       "…tmux capture-pane -S -80, filtered…",
    "tool_calls": [{"name": "Edit", "count": 3}, {"name": "Read", "count": 7}],
    "file_edits": ["path/one.sh"],
    "error":      null
  },
  "task_id":          "576",
  "subtask_id":       "261752",
  "hypothesis_updates": [],
  "evidence":         [],
  "needs_follow_up":  false,
  "summary":          "…",
  "proof_type":       "research | docs | auto_build | unverified | …",
  "proof_content":    "…",
  "verification_steps": ["[go build] exit 0", "[bash -n x.sh] exit 0"],
  "verification_status": "passed | failed | \"\"",
  "proof_of_success": {
    "criteria_results": [
      {"criterion": "go build passes", "status": "pass", "evidence": "exit 0"}
    ],
    "human_verification_guide": "",
    "auto_verified_count": 1,
    "needs_human_count": 0,
    "failed_count": 0
  }
}
```

`files_changed` is produced from `git diff --name-only HEAD`. Proof
fields are sourced from `RUNTIME_DIR/proof/<pane_safe>.proof` (written
by the worker) plus auto verification (`stop-results.sh:161`). `go build`,
`go vet`, and `bash -n` are auto-run against changed files.

### Completion event

Alongside the JSON result, `stop-results.sh:454` writes a short
completion file at `RUNTIME_DIR/status/completion_pane_<W>_<P>` with
bash-escaped KEY="VALUE" fields:

```
PANE_INDEX="1"
PANE_TITLE="⠂ T8 W1"
STATUS="done"
TIMESTAMP=1776104142
```

This file is how wake hooks (`taskmaster-wait.sh`, `stop-notify.sh`)
detect that a worker just finished.

## 6. Trigger files

A trigger is a **zero-byte, mtime-only** file. `touch`-ing it is the
signal; its contents are never read. Known triggers:

| Path | Meaning | Touched by |
|------|---------|-----------|
| `RUNTIME_DIR/status/taskmaster_trigger` | Wake the Taskmaster | `shell/doey-ipc-helpers.sh:90,105`, `stop-status.sh:196`, anything calling `notify_taskmaster` |
| `RUNTIME_DIR/triggers/<pane_safe>.trigger` | Wake a specific pane | `stop-notify.sh:39`, `shell/doey-ipc-helpers.sh:104` |

`taskmaster-wait.sh` polls these plus message counts. When any trigger
appears, the wait hook removes it and returns to let Claude resume.
`inotifywait` is used when available (`taskmaster-wait.sh` passive-role
branch, line ~70) to avoid polling.

## 7. Session and team env files

### `RUNTIME_DIR/session.env`

Written by `shell/doey-session.sh:607`. Bash-sourceable. Canonical
fields:

```
PROJECT_DIR="/home/doey/doey"
PROJECT_NAME="doey"
PROJECT_ACRONYM="d"
SESSION_NAME="doey-doey"
GRID="dynamic"
TOTAL_PANES="2"
WORKER_COUNT="0"
WORKER_PANES=""
RUNTIME_DIR="/tmp/doey/doey"
PASTE_SETTLE_MS="800"
IDLE_COLLAPSE_AFTER="60"
IDLE_REMOVE_AFTER="300"
TEAM_WINDOWS="2"
BOSS_PANE="0.1"
TASKMASTER_PANE="1.0"
REMOTE="true"
PROJECT_LANGUAGE="go"
BUILD_CMD=""
TEST_CMD=""
LINT_CMD=""
```

Language detection fields are appended by `_write_project_type_env`
(`shell/doey-session.sh:97`). `safe_source_session_env` (line 235)
auto-quotes malformed lines before sourcing.

### `RUNTIME_DIR/team_<N>.env`

Written by `shell/doey-team-mgmt.sh`. Per-window manifest:

```
WINDOW_INDEX="1"
GRID="2x2"
MANAGER_PANE="0"
WORKER_PANES="1,2"
WORKER_COUNT="2"
SESSION_NAME="doey-doey"
WORKTREE_DIR=""
WORKTREE_BRANCH=""
TEAM_NAME="Core Team"
TEAM_ROLE="core"
WORKER_MODEL=""
MANAGER_MODEL=""
TEAM_TYPE=""
TEAM_DEF=""
RESERVED=""
TASK_ID=""
```

Read via `_read_team_key` (`.claude/hooks/common.sh:245`).

## 8. Config files

Hierarchy (last wins), implemented in `shell/doey.sh`:

1. Hardcoded defaults in `doey.sh`.
2. Global: `~/.config/doey/config.sh`.
3. Project: `<project>/.doey/config.sh`.

Both global and project files are plain shell scripts setting `DOEY_*`
variables. Template and variable catalogue live in
`shell/doey-config-default.sh`. Neither file is created by install —
copy the template and edit.

## 9. Agent-memory

Doey agents declare a `memory:` frontmatter key in their `.md`
definition (`agents/doey-*.md`, e.g. `memory: user|session|none`).
This controls whether Claude Code persists per-agent memory to
`~/.claude/` on the host. `doey uninstall` in
`shell/doey-update.sh:555` preserves the agent-memory directory on
uninstall but does not otherwise read or write it. Doey itself does
not treat agent-memory as a source of truth.

## 10. Ephemeral vs persistent — quick table

| Concern | Persistent | Ephemeral |
|---------|-----------|----------|
| Task metadata & log | `.doey/doey.db`, `.doey/tasks/*.task` | — |
| Final worker result | `.doey/tasks/<id>.result.json` | `RUNTIME_DIR/results/pane_<W>_<P>.json` |
| Messages | `.doey/doey.db` (DB mode) | `RUNTIME_DIR/messages/*.msg` (fallback, DB-mode auto-expired 1h) |
| Pane status | `.doey/doey.db` (DB mode) | `RUNTIME_DIR/status/*.status` |
| Activity log | `.doey/doey.db` events table | `RUNTIME_DIR/activity/*.jsonl` |
| Session / team env | — | `RUNTIME_DIR/session.env`, `team_<N>.env` |
| Triggers / completion flags | — | `RUNTIME_DIR/status/…`, `RUNTIME_DIR/triggers/…` |
| Logs & errors | — | `RUNTIME_DIR/logs/`, `errors/`, `issues/` |
| Daemon pids | — | `RUNTIME_DIR/doey-router.pid`, `doey-daemon.pid` |
| Config | `~/.config/doey/config.sh`, `.doey/config.sh` | — |

## 11. Concurrency rules

1. **Writes are atomic via `tmp` + `mv`.** See:
   - `write_pane_status` — `.claude/hooks/common.sh:405`
   - `task_update_field` — `shell/doey-task-helpers.sh:238`
   - `send_msg_to_taskmaster` — `shell/doey-ipc-helpers.sh:101`
   - `stop-results.sh:307` — `mktemp` then `mv` for the JSON result.
2. **No shell-level locks.** Coordination is social: "one worker per
   file" is the project rule (see `CLAUDE.md`).
3. **SQLite is the arbiter.** When `doey-ctl` is present, writes flow
   through SQLite with WAL mode (`doey.db-wal` exists in every live
   project). Shell writes go through the DB fast path first and fall
   back to files only if the DB is unavailable. See
   `openStoreIfExists` at `tui/cmd/doey-ctl/main.go:181`.
4. **Stop hooks split work by sync/async.** `stop-status.sh` is
   synchronous and establishes the canonical status. `stop-results.sh`,
   `stop-notify.sh`, and `stop-plan-tracking.sh` run async after it and
   may race each other — they read the status file written by
   `stop-status.sh` rather than each other.
5. **Trigger files are idempotent.** Multiple writers touching the
   same trigger is fine; the wait hook unlinks and exits on any
   mtime change.
6. **Runtime cache is best-effort.** `RUNTIME_DIR/tasks/` is a
   one-way sync from `.doey/tasks/` written by
   `_task_sync_to_runtime` (`shell/doey-task-cli.sh:169`). TUI reads
   from it but never writes back.

## 12. Key writer index

| Path pattern | Writer file:line |
|--------------|-----------------|
| `RUNTIME_DIR/session.env` | `shell/doey-session.sh:607`, `:1206` |
| `RUNTIME_DIR` directory skeleton | `shell/doey.sh:824`, `.claude/hooks/common.sh:117` |
| `<project>/.doey/tasks/<id>.task` | `shell/doey-task-helpers.sh:94` (`task_create`), `:238` (`task_update_field`) |
| `.doey/doey.db` | `tui/cmd/doey-ctl/` (`store` package) |
| `.doey/tasks/<id>.status` | `.claude/hooks/stop-status.sh:110` |
| `.doey/tasks/<id>.result.json` | `.claude/hooks/stop-results.sh:357` |
| `.doey/tasks/<id>/attachments/*` | `.claude/hooks/stop-results.sh:370,387` |
| `RUNTIME_DIR/status/<safe>.status` | `.claude/hooks/common.sh:405` |
| `RUNTIME_DIR/results/pane_*.json` | `.claude/hooks/stop-results.sh:324` |
| `RUNTIME_DIR/messages/*.msg` | `shell/doey-ipc-helpers.sh:100`, `.claude/hooks/stop-notify.sh:36`, `tui/cmd/doey-ctl/main.go:277` |
| `RUNTIME_DIR/proof/<safe>.proof` | worker via Bash (validated by `.claude/hooks/stop-status.sh:27`) |
| `RUNTIME_DIR/status/completion_pane_*` | `.claude/hooks/stop-results.sh:454` |
| `RUNTIME_DIR/status/taskmaster_trigger` | `shell/doey-ipc-helpers.sh:90`, `.claude/hooks/stop-status.sh:196` |
| `RUNTIME_DIR/triggers/<safe>.trigger` | `shell/doey-ipc-helpers.sh:104`, `.claude/hooks/stop-notify.sh:39` |
| `RUNTIME_DIR/activity/*.jsonl` | `.claude/hooks/common.sh:469` |

See `docs/reference/cookbook.md` for copy-paste patterns over these
storage locations.
