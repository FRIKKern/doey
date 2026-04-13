# Doey Cookbook

Copy-paste patterns for interacting with Doey's task, message, status,
and result stores. Every command below is a literal call into
`shell/doey-*.sh` or the `doey-ctl` binary built from `tui/cmd/doey-ctl/`.

For field layouts and file locations, see
`docs/reference/storage.md`.

## 1. Create a task

`doey task add` creates a new `.task` file under
`<project>/.doey/tasks/` and, when `doey-ctl` is installed, inserts a
row into `.doey/doey.db`. Implemented in
`shell/doey-task-cli.sh:285`.

```bash
doey task add "Fix status observer staleness" \
  --description "Taskmaster sees BUSY panes as idle after 60s; fix in doey-ctl status observe." \
  --attach "docs/reference/storage.md"
```

Task id is printed on stdout. Positional arg is the title. `--description`
and `--attach` are the only flags. Task starts in status `active`
(see `task_create` in `shell/doey-task-helpers.sh:112`).

Transition the lifecycle via subcommands (defined at
`shell/doey-task-cli.sh:318`):

```bash
doey task start  576        # → in_progress
doey task pause  576        # → paused
doey task block  576        # → blocked
doey task confirm 576       # → pending_user_confirmation
doey task done   576
doey task failed 576
doey task cancel 576
```

Inspect a task:

```bash
doey task list
doey task show 576
doey task describe 576 "New description text"
doey task attach  576 "docs/reference/storage.md"
```

`doey task list` hides `done` and `cancelled` rows
(`shell/doey-task-cli.sh:255`).

### Programmatic task creation from a shell script

Direct helper (no CLI subshell):

```bash
source /home/doey/doey/shell/doey-task-helpers.sh
TASK_ID=$(task_create "/home/doey/doey" "Migrate storage to DB" "refactor" "Boss" "Full DB migration")
echo "Created task $TASK_ID"
```

Update a field atomically:

```bash
source /home/doey/doey/shell/doey-task-helpers.sh
task_update_field "/home/doey/doey/.doey/tasks/${TASK_ID}.task" \
  "TASK_SUCCESS_CRITERIA" "go build passes|go vet passes"
```

## 2. Send a message between panes

`doey msg send` delivers a message to another pane's queue and fires
a wake trigger. Defined in `tui/cmd/doey-ctl/main.go:224`.

```bash
doey msg send \
  --from "doey_doey_2_1" \
  --to   "doey_doey_1_0" \
  --subject "task_576_complete" \
  --body "Storage + cookbook docs written; see .doey/tasks/576.result.json" \
  --project-dir "/home/doey/doey"
```

Required flags: `--from`, `--to`, `--subject`. `--to` takes a
`PANE_SAFE` identifier (e.g. `doey_doey_1_0` for
`doey-doey:1.0`). Optional:

| Flag | Effect |
|------|--------|
| `--body` | Free-form body text. |
| `--task-id` | Associate with a task row in the DB. |
| `--runtime` | Override `RUNTIME_DIR` detection. |
| `--no-nudge` | Skip the tmux `send-keys` wake-up on the target pane. |
| `--verify` | Block until target pane shows an activity change. |
| `--verify-timeout <sec>` | Verification window (default 10). |
| `--json` | JSON output. |

Inside a hook or shell script, the canonical helper is
`send_msg_to_taskmaster` in `shell/doey-ipc-helpers.sh:66`:

```bash
source /home/doey/doey/shell/doey-ipc-helpers.sh
send_msg_to_taskmaster "$RUNTIME_DIR" "$SESSION_NAME" \
  "task_576_complete" "Docs written — see storage.md + cookbook.md"
```

This writes a `.msg` file to
`$RUNTIME_DIR/messages/doey_doey_1_0_<epoch>_<pid>.msg`, touches
`$RUNTIME_DIR/status/taskmaster_trigger` and
`$RUNTIME_DIR/triggers/<taskmaster_safe>.trigger`, and falls back to
the DB path via `doey msg send --verify` when `doey-ctl` is present.

### Broadcast to every pane in a window

`shell/doey-send.sh` provides the fan-out helper used by
`stop-notify.sh` and masterplan spawn. Call it directly:

```bash
bash /home/doey/doey/shell/doey-send.sh broadcast \
  --runtime "$RUNTIME_DIR" \
  --window 2 \
  --subject "phase_1_start" \
  --body   "Read the masterplan and begin Phase 1"
```

### Just wake a pane (no message)

```bash
doey msg trigger --pane "doey_doey_1_0"
```

Touches the trigger without writing a message file
(`tui/cmd/doey-ctl/main.go:621`).

### Read or count messages

```bash
doey msg count --to "doey_doey_1_0" --project-dir "$PROJECT_DIR"
doey msg list  --project-dir "$PROJECT_DIR"                # DB only
doey msg read  --pane "doey_doey_1_0" --project-dir "$PROJECT_DIR"
doey msg read-all --to "doey_doey_1_0" --project-dir "$PROJECT_DIR"
doey msg mark-read --pane "doey_doey_1_0" --project-dir "$PROJECT_DIR"
doey msg clean --pane "doey_doey_1_0" --project-dir "$PROJECT_DIR"
```

## 3. Observe a pane's status

Preferred API: `doey-ctl status observe` — returns canonical JSON with
`active`, `indicator`, and `ages` (`tui/cmd/doey-ctl/observe_cmd.go`).
Used by the `STATUS CHECK PROTOCOL` in `CLAUDE.md`.

```bash
doey-ctl status observe "1.0" --runtime /tmp/doey/doey
```

Read a single pane's canonical status:

```bash
doey status get "doey_doey_1_0" --project-dir /home/doey/doey
# pane_id=... status=BUSY role=... updated_at=...
```

Set a pane status (DB + file write-through, see
`tui/cmd/doey-ctl/main.go:771`):

```bash
doey status set "doey_doey_1_0" "READY" --project-dir /home/doey/doey
```

List all pane statuses for a window:

```bash
doey status list --window 1 --project-dir /home/doey/doey
```

Shell fallback (no `doey-ctl`) — read directly:

```bash
STATUS=$(grep '^STATUS: ' /tmp/doey/doey/status/doey_doey_1_0.status \
         | head -1 | sed 's/^STATUS: //')
echo "$STATUS"
```

Tmux capture-pane (used by `doey-ctl status observe`; minimum depth per
CLAUDE.md is `-S -20`):

```bash
tmux capture-pane -t doey-doey:1.0 -p -S -20
```

## 4. Read worker results from a result JSON

Completed worker results land at two locations:

- `RUNTIME_DIR/results/pane_<W>_<P>.json` (hot, written by
  `.claude/hooks/stop-results.sh:324`).
- `<project>/.doey/tasks/<task_id>.result.json` (persistent copy,
  same file, copied at `stop-results.sh:357`).

Extract what a worker actually changed:

```bash
RESULT="/home/doey/doey/.doey/tasks/576.result.json"

jq '.status'                         < "$RESULT"   # "done" or "error"
jq '.files_changed[]'                < "$RESULT"
jq '.proof_type + " — " + .proof_content' < "$RESULT"
jq '.proof_of_success'               < "$RESULT"
jq '.verification_steps[]'           < "$RESULT"
jq '.tool_calls'                     < "$RESULT"
```

`last_output` is a structured object: `{text, tool_calls, file_edits, error}`.
`.text` holds the filtered tmux capture; `.tool_calls` is an array of
`{name,count}` entries; `.file_edits` lists files touched by Edit/Write;
`.error` is the last captured error line or `null`. Readers that expect the
legacy raw-string form should use `(.last_output | if type=="object" then .text else . end)`.

Completion events (the tiny bash-escaped file written alongside the
JSON) are handy for quick polling:

```bash
. /tmp/doey/doey/status/completion_pane_1_2
echo "$STATUS $PANE_TITLE @ $(date -r "$TIMESTAMP" 2>/dev/null || echo $TIMESTAMP)"
```

## 5. Wait reactively for work

The canonical pattern is `.claude/hooks/taskmaster-wait.sh`. It
combines:

1. A named trigger file (`$RUNTIME_DIR/status/taskmaster_trigger`
   or `$RUNTIME_DIR/triggers/<pane_safe>.trigger`).
2. A message-queue check (`doey msg count --to <pane>`).
3. `inotifywait` on the `messages/` and `triggers/` directories when
   available; `sleep 15`/`sleep 30` fallback otherwise.

Minimum reproduction for a custom wait loop:

```bash
#!/usr/bin/env bash
set -euo pipefail
source /home/doey/doey/.claude/hooks/common.sh
init_hook   # populates $RUNTIME_DIR, $PANE_SAFE, $SESSION_NAME

MSG_DIR="$RUNTIME_DIR/messages"
TRIG="$RUNTIME_DIR/triggers/${PANE_SAFE}.trigger"

while :; do
  # Fast path: inotifywait blocks until something appears or timeout expires
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -qq -t 30 -e create,modify "$MSG_DIR/" "$RUNTIME_DIR/triggers/" || true
  else
    sleep 15
  fi

  # Trigger wins — consume it and return
  if [ -f "$TRIG" ] || [ -f "$RUNTIME_DIR/status/taskmaster_trigger" ]; then
    rm -f "$TRIG" "$RUNTIME_DIR/status/taskmaster_trigger" 2>/dev/null || true
    echo "WAKE_REASON=TRIGGER"
    exit 0
  fi

  # Any unread message also wakes us
  if [ "$(doey msg count --to "$PANE_SAFE" --project-dir "$PROJECT_DIR" 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "WAKE_REASON=MSG"
    exit 0
  fi
done
```

Key rules (from CLAUDE.md and memory
`feedback_reactive_not_polling.md`):

- Don't busy-poll status files. React to triggers or `inotifywait`.
- `doey msg count` is the right idle-wake signal — it hits SQLite
  when available and short-circuits on `.msg` files otherwise.

## 6. Dispatch work to a worker

The typical dispatch path used by Subtaskmasters is `doey dispatch`:

```bash
doey dispatch "1.2" "Worker 1.2 — please implement subtask 261752 for task 576."
```

See `shell/doey.sh` command table at `shell/doey.sh:150` and the
`doey-dispatch` skill at `.claude/skills/doey-dispatch/`. The dispatch
skill writes the task id into
`$RUNTIME_DIR/status/<pane_safe>.task_id` so that the worker's
`on-prompt-submit.sh` hook can associate the next prompt with a task.

Low-level send-keys delivery lives in `send_to_pane`
(`.claude/hooks/common.sh:334`). It is **not** callable from worker
panes — the pre-tool-use hook denies `send-keys` for workers except
for the single allowed exception of sending to their own Subtaskmaster
(see `.claude/hooks/on-pre-tool-use.sh`).

If you're inside a hook context and need to nudge a specific pane
from a privileged role:

```bash
source /home/doey/doey/.claude/hooks/common.sh
send_to_pane "2.1" "please re-read the task brief"
```

## 7. Common debugging patterns

### Is the pane actually busy?

```bash
doey-ctl status observe "1.0" --runtime /tmp/doey/doey
tmux capture-pane -t doey-doey:1.0 -p -S -20
cat /tmp/doey/doey/status/doey_doey_1_0.status
```

If the status file says `BUSY` but `status observe` says `active=false`
for more than 60s, the pane is stuck. Do **not** kill it without
multi-check proof (memory `feedback_no_premature_kills.md`).

### Who did each worker report to recently?

```bash
ls -lt /tmp/doey/doey/messages/ | head -20
for m in /tmp/doey/doey/messages/doey_doey_1_0_*.msg; do
  head -2 "$m"; echo '---'
done
```

### What did the last worker change?

```bash
RESULT=/tmp/doey/doey/results/pane_8_1.json
jq '{status, tool_calls, files_changed, proof_type, proof_content}' "$RESULT"
```

### Which triggers are pending?

```bash
ls -la /tmp/doey/doey/triggers/
ls -la /tmp/doey/doey/status/taskmaster_trigger 2>/dev/null || echo "no taskmaster trigger"
```

A stale trigger (older than a few minutes) usually means the wait hook
crashed or is sleeping through it — check
`/tmp/doey/doey/errors/errors.log`.

### Stream every hook error as they happen

```bash
tail -F /tmp/doey/doey/errors/errors.log \
        /tmp/doey/doey/logs/hook-prompt-submit.log
```

### Check unread message queues across all panes

```bash
for f in /tmp/doey/doey/status/*.status; do
  pane=$(basename "$f" .status)
  unread=$(doey msg count --to "$pane" --project-dir /home/doey/doey 2>/dev/null || echo 0)
  [ "$unread" -gt 0 ] && echo "$pane: $unread unread"
done
```

### Find recent completion events

```bash
ls -lt /tmp/doey/doey/status/completion_pane_* | head
for f in /tmp/doey/doey/status/completion_pane_*; do
  ( . "$f" && echo "$STATUS  $PANE_TITLE  $TIMESTAMP" )
done | sort -k3
```

### Read a task file without sourcing anything

```bash
grep -E '^TASK_(ID|TITLE|STATUS|TYPE|SUBTASKS|TIMESTAMPS|UPDATED)=' \
  /home/doey/doey/.doey/tasks/576.task
```

### Tail the activity log for a specific pane

```bash
tail -F /tmp/doey/doey/activity/doey_doey_1_0.jsonl
```

Written by `write_activity` in `.claude/hooks/common.sh:469`. Each
line is a JSONL event.

### Inspect task store state from SQLite

```bash
sqlite3 /home/doey/doey/.doey/doey.db '.tables'
sqlite3 /home/doey/doey/.doey/doey.db \
  'SELECT id, title, status FROM tasks ORDER BY id DESC LIMIT 20;'
```

SQLite is the source of truth when `doey-ctl` is installed; the
`.task` file is the fallback. Use `doey task get --id N --project-dir …`
via `doey-ctl` for a shell-friendly display.

### Purge stale runtime files

```bash
doey purge                     # interactive scan + clean, see shell/doey-purge.sh
```

`doey purge` audits `RUNTIME_DIR` for context bloat and cleans stale
status/result/message files. Do **not** `rm -rf /tmp/doey/doey` — use
`doey purge` or `trash` so the session's PID files are unlinked
cleanly.

## 8. See also

- `docs/reference/storage.md` — persistence layout, schemas, writers.
- `CLAUDE.md` — architecture, role table, hook table, tool restrictions.
- `docs/context-reference.md` — authoritative architecture reference.
- `.claude/hooks/common.sh` — shared hook library (functions referenced
  throughout this cookbook).
- `shell/doey-task-helpers.sh` — task CRUD primitives.
- `shell/doey-ipc-helpers.sh` — messaging / triggers primitives.
- `tui/cmd/doey-ctl/main.go` — `doey-ctl` subcommand dispatch (source
  of truth for flags).
