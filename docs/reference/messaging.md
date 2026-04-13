# Doey Messaging Reference

How roles inside a Doey session talk to each other: the topology, the message
subjects in use, the trigger-file system that wakes idle panes, and the
tmux send-keys rules enforced by `.claude/hooks/on-pre-tool-use.sh`.

Every claim here is grounded in source. Nothing is invented — if a subject is
not in this document it does not appear in the code.

---

## 1. Role topology

The pane layout (from CLAUDE.md "Architecture") is:

| Role | Pane | Source of truth |
|---|---|---|
| Info Panel | `0.0` | shell script, no Claude |
| Boss | `0.1` | `agents/doey-boss.md` |
| Taskmaster (Coordinator) | `1.0` (Core Team window) | `agents/doey-taskmaster.md` |
| Task Reviewer | `1.1` | `agents/doey-task-reviewer.md` |
| Deployment | `1.2` | `agents/doey-deployment.md` |
| Doey Expert | `1.3` | `agents/doey-doey-expert.md` |
| Subtaskmaster (Team Lead) | `N.0` for team window N≥2 | `agents/doey-subtaskmaster.md` |
| Workers | `N.1+` | `agents/doey-worker.md`, `doey-worker-quick.md`, `doey-worker-deep.md`, `doey-worker-research.md` |
| Freelancers | `F.0+` | `agents/doey-freelancer.md`, in managerless team windows |

Window 0 = Dashboard (Info Panel + Boss). Window 1 = Core Team (Taskmaster +
specialists). Windows 2+ = team windows (Subtaskmaster + Workers, or
Freelancers in managerless mode).

The communication shape is strictly hierarchical:

```
                            User
                              │
                              ▼
                  ┌──────────────────────┐
                  │       Boss (0.1)     │  user-facing PM
                  └──────────┬───────────┘
                             │ relay only
                             ▼
                  ┌──────────────────────┐
                  │  Taskmaster (1.0)    │  sole executor / coordinator
                  └──┬───────────────┬───┘
        (cross-team) │               │ (specialist)
                     ▼               ▼
       ┌─────────────────────┐  ┌────────────────────┐
       │ Subtaskmaster (N.0) │  │ Task Reviewer 1.1  │
       └──────────┬──────────┘  │ Deployment    1.2  │
                  │             │ Doey Expert   1.3  │
                  ▼             └────────────────────┘
       ┌─────────────────────┐
       │ Workers (N.1+)      │
       └─────────────────────┘
```

Returning information always flows back through the same chain:

```
Worker  ──Stop hook──▶  Subtaskmaster  ──Stop hook──▶  Taskmaster  ──msg──▶  Boss
```

The stop-time fan-out is implemented in `.claude/hooks/stop-notify.sh`:
worker → subtaskmaster (`subject: task_complete` to `<session>:<TASKMASTER_PANE>`,
see `:285`), all-workers-done detection (`subject: all_workers_done`,
see `:254`), and Taskmaster → Boss summaries (`subject: taskmaster_update`,
see `:314`).

---

## 2. Full request flow

Path of a single user request from prompt to result:

```
1. User types prompt in Boss pane (0.1).
2. Boss creates a task via `doey task create` and dispatches by sending
   the task summary to Taskmaster (1.0) with `tmux send-keys`.
   on-pre-tool-use.sh:580-603 only allows Boss send-keys to the
   Coordinator pane; everything else is BLOCKED + FORWARDED.
3. Taskmaster picks up the task on its next wait-loop wake. It either:
     a) Spawns or selects a team window and sends a dispatch_task message
        to that team's Subtaskmaster (N.0) via `doey msg send`, or
     b) Dispatches via tmux send-keys directly. on-pre-tool-use.sh:986-1031
        requires an active .task file before any send-keys to a team window
        (otherwise: "BLOCKED: Create a .task file before dispatching work").
4. Subtaskmaster reads the task, plans subtasks via
   `doey task subtask add`, and dispatches each subtask to a worker
   pane via `tmux send-keys` to N.<worker_idx>.
5. Worker executes. Before stopping, the worker writes
     PROOF_TYPE: <type>
     PROOF: <summary>
   to <runtime>/proof/<pane_safe>.proof. stop-status.sh:24-36 blocks the
   stop until proof is present (or DOEY_PROOF_EXEMPT=1).
6. stop-results.sh writes <runtime>/results/pane_<W>_<P>.json with the
   worker's output, files changed, and tool counts.
7. stop-notify.sh fires the notification chain:
     - Touch <runtime>/triggers/<subtaskmaster_safe>.trigger
     - When all workers in the team are FINISHED/RESERVED, send
       subject all_workers_done to the Subtaskmaster (stop-notify.sh:254).
     - On the Subtaskmaster's own stop, send subject task_complete
       to the Taskmaster (stop-notify.sh:285).
     - On the Taskmaster's own stop, send subject taskmaster_update
       to the Boss (stop-notify.sh:314).
8. Each wait hook (taskmaster-wait.sh, reviewer-wait.sh) wakes from
   inotifywait or its sleep, prints WAKE_REASON=<reason>, and the agent
   resumes.
```

Sequence diagram for the happy path:

```
User    Boss(0.1)   Taskmaster(1.0)   Subtaskmaster(N.0)   Worker(N.k)
 │         │              │                    │                │
 │ prompt  │              │                    │                │
 │────────▶│              │                    │                │
 │         │ task create  │                    │                │
 │         │─────────────▶│ (DB / .doey/tasks) │                │
 │         │ send-keys    │                    │                │
 │         │─────────────▶│                    │                │
 │         │              │ msg send           │                │
 │         │              │ subject:dispatch_task                │
 │         │              │───────────────────▶│                │
 │         │              │                    │ send-keys      │
 │         │              │                    │───────────────▶│
 │         │              │                    │                │ work...
 │         │              │                    │                │ proof file
 │         │              │                    │   trigger      │ Stop
 │         │              │                    │◀───────────────│
 │         │              │                    │ all_workers_done│
 │         │              │                    │◀───────────────│
 │         │              │ task_complete      │ Stop           │
 │         │              │◀───────────────────│                │
 │         │ taskmaster_update                 │                │
 │         │◀─────────────│ Stop               │                │
 │ reply   │              │                    │                │
 │◀────────│              │                    │                │
```

---

## 3. Message subjects in use

`doey msg send --subject <subject>` is the canonical send. Subjects are
free-form strings, but the codebase uses a small fixed vocabulary. Below is
the complete set found in `.claude/hooks/`, `shell/`, and `agents/` as of
this commit. Search command:

```
grep -rE '"--subject"|--subject [a-zA-Z_:-]+' \
  /home/doey/doey/.claude/hooks /home/doey/doey/shell /home/doey/doey/agents
```

| Subject | Sender → Receiver | Meaning | Source |
|---|---|---|---|
| `dispatch_task` | Taskmaster → Subtaskmaster | "Here is a task assignment for your team." Carries task id and brief. | `agents/doey-taskmaster.md`, `agents/doey-subtaskmaster.md` |
| `task_request` | Boss / Subtaskmaster → Taskmaster | "Create or pick up this task." | `agents/doey-boss.md`, `agents/doey-subtaskmaster.md` |
| `task_complete` | Subtaskmaster → Taskmaster | Subtaskmaster reports a finished team task. | `.claude/hooks/stop-notify.sh:285` |
| `all_workers_done` | stop-notify (worker) → Subtaskmaster | Last worker in a team finished — wake the Subtaskmaster to validate and synthesize. | `.claude/hooks/stop-notify.sh:254` |
| `taskmaster_update` | Taskmaster → Boss | Status update / result summary for the user. | `.claude/hooks/stop-notify.sh:314` |
| `sleep_report` | Taskmaster → Boss | "All tasks resolved. Coordinator entering sleep." Posted once per idle cycle (`taskmaster_sleep_reported` flag). | `.claude/hooks/taskmaster-wait.sh:597` |
| `status_report` | Worker / Subtaskmaster → coordinator | Periodic status update on a long-running task. | `agents/doey-subtaskmaster.md` |
| `review_request` | Taskmaster → Task Reviewer | Ask the reviewer to validate a finished task. | `agents/doey-taskmaster.md` |
| `subtask_review_request` | Worker → Subtaskmaster | Ask the team lead to validate a finished subtask. | `agents/doey-worker.md` |
| `subtask_review_passed` | Subtaskmaster → Worker | Subtask validated. | `.claude/hooks/stop-notify.sh` (review chain) |
| `subtask_review_failed` | Subtaskmaster → Worker | Subtask rejected, with reason. | same |
| `review_failed` | Task Reviewer → Taskmaster | Task rejected, with reason. | same |
| `dispatch_failed` | Taskmaster / Subtaskmaster | Dispatch attempt could not deliver. | `agents/doey-taskmaster.md` |
| `needs_specifics` | Taskmaster / Boss | Caller did not provide enough detail; ask the user. | `agents/doey-boss.md` |
| `deploy_request` | Taskmaster → Deployment | Run the deployment pipeline on a finished task. | `agents/doey-taskmaster.md` |
| `deployment_request` | (alias used by some skills) | Same as `deploy_request`. | hooks |
| `deployment_complete` | Deployment → Taskmaster | Deployment pipeline finished successfully. | hooks |
| `deployment_failed` | Deployment → Taskmaster | Deployment pipeline failed. | hooks |
| `interview_complete` | Interviewer (team_lead/team_role=interviewer) → Taskmaster | Deep-interview output ready, plan created. | `agents/doey-interviewer.md` |
| `masterplan_spawned` | masterplan launcher → Taskmaster | New masterplan team window spawned. | `shell/doey-masterplan-spawn.sh` |
| `stale_recovery` | watchdog / Taskmaster | Recover a pane reported stale (heartbeat too old). | hooks |
| `polling_loop_breaker` | `common.sh:594` | Anti-polling guard: forces wait-loop break when a role is spinning. | `.claude/hooks/common.sh:594` |
| `action_request` | `on-pre-tool-use.sh:189-203` | A blocked role is forwarding a tool-use request to its coordinator. Body includes the original tool name and arguments. | `.claude/hooks/on-pre-tool-use.sh:189-203` |

Adjacent stale-* signals used by `taskmaster-wait.sh` (not subjects, but
status-file flag names): `stale_bins`, `stale_booting`, `stale_dir`,
`stale_heartbeats`, `stale_info`, `stale_output`, `stale_pending`,
`stale_recovery`, `stale_restart`.

When you add a new subject, prefer one of the verbs above
(`request` / `complete` / `failed` / `update` / `report`) and document it here.

---

## 4. Trigger file system

Triggers are zero-byte files that wake idle wait loops without parsing
content. They live under:

```
${DOEY_RUNTIME}/triggers/        # per-pane wake triggers
${DOEY_RUNTIME}/status/taskmaster_trigger    # legacy global Taskmaster wake
${DOEY_RUNTIME}/status/reviewer_trigger      # Task Reviewer wake
${DOEY_RUNTIME}/messages/        # actual message files (FROM/SUBJECT/body)
${DOEY_RUNTIME}/results/         # worker result JSON
${DOEY_RUNTIME}/proof/           # worker proof files (worker stop gate)
${DOEY_RUNTIME}/research/        # research task assignments
${DOEY_RUNTIME}/reports/         # research reports (write-once)
${DOEY_RUNTIME}/respawn/         # respawn requests
${DOEY_RUNTIME}/locks/           # per-pane send-keys locks
```

### 4.1 Message file format

`stop-notify.sh:35-39`:

```
mkdir -p "${RUNTIME_DIR}/messages" "${RUNTIME_DIR}/triggers"
printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$sender" "$subject" "$body" \
  > "${msg_file}.tmp" \
  && mv "${msg_file}.tmp" "${msg_file}" \
  && touch "${RUNTIME_DIR}/triggers/${target_safe}.trigger"
```

The atomic `tmp+mv` write guarantees that wait loops never see a
half-written message. The trigger file is touched only after the message is
on disk.

### 4.2 Who touches what

| File | Writer | Reader |
|---|---|---|
| `<runtime>/messages/<target>_<ts>_<pid>.msg` | `doey-ctl msg send`, `stop-notify.sh:37`, `taskmaster-wait.sh:597` | `doey-ctl msg read`, `taskmaster-wait.sh:497`, `reviewer-wait.sh:64` |
| `<runtime>/triggers/<target>.trigger` | `doey-ctl msg send` (after delivery), `stop-notify.sh:39`, `stop-notify.sh:107`, `on-pre-tool-use.sh:193,203`, `stop-status.sh:197` | `taskmaster-wait.sh:55,81,486,620`, `reviewer-wait.sh:58,102` |
| `<runtime>/status/taskmaster_trigger` | `stop-notify.sh:107`, `stop-status.sh:196` | `taskmaster-wait.sh:30,485,619` |
| `<runtime>/status/reviewer_trigger` | external | `reviewer-wait.sh:57,101` |
| `<runtime>/results/pane_<W>_<P>.json` | `stop-results.sh` | `taskmaster-wait.sh:_has_new_results` |
| `<runtime>/proof/<pane_safe>.proof` | worker | `stop-status.sh:27-35` (gate) |
| `<runtime>/respawn/<pane_safe>.request` | external | `stop-status.sh:12`, `stop-respawn.sh` |
| `<runtime>/locks/<pane_safe>.lock` | `_doey_send_lock` | `_doey_send_lock` (mutex via `mkdir`) |

### 4.3 `taskmaster-wait.sh` wake reasons

`taskmaster-wait.sh` is the wait hook for the Taskmaster pane and, in
"passive role" mode (`:38-115`), for the Core Team specialists (Task
Reviewer, Deployment, Doey Expert) when the same script is invoked from
their pane. It prints exactly one `WAKE_REASON=<reason>` to stdout before
exiting 0:

| WAKE_REASON | Trigger |
|---|---|
| `MSG` | New unread message for this pane (counted via `doey msg count` or by enumerating `messages/`). |
| `TRIGGERED` | A trigger file (per-pane or `taskmaster_trigger`) was found and consumed. Used by `stop-notify.sh`, `on-pre-tool-use.sh`, and the cycle-tick watchdog. |
| `FINISHED` | New worker result JSON appeared in `<runtime>/results/`. |
| `CRASH` | A `<runtime>/status/crash_pane_*` file appeared. |
| `STALE` | `_check_stale_heartbeats` matched. |
| `RESTART` | `_enforce_stale_restart` requested a restart. |
| `BOOT_STUCK` | `_check_stale_booting` matched. |
| `QUEUED` | At least one task is `active` (and not assigned to a team) and either freshly created or older than 30s — see `:533-535`. |
| `ALL_DONE` | (passive mode only) All workers in the caller's team window are FINISHED or RESERVED — see `:107-110`. |
| `TIMEOUT` | (passive mode only) Wait timed out with no work to do. |

The Taskmaster wait blocks via `inotifywait` on `status/`, `results/`,
`messages/`, and `triggers/` if available, otherwise `sleep 60`
(`:606-616`). The passive wait blocks for 30s (`:69-78`).

The Subtaskmaster has a separate wait hook configured in its agent
definition; its wake reasons are the per-pane subset of the above (`MSG`,
`TRIGGERED`, `ALL_DONE`).

---

## 5. Tmux send-keys rules

Tmux send-keys is the channel that actually delivers a message into a
running Claude pane. The canonical helper is `doey_send_verified` in
`shell/doey-send.sh:187`. Use it instead of raw `tmux send-keys` whenever
delivery confirmation matters.

### 5.1 What `doey_send_verified` does

`shell/doey-send.sh:187-316`:

1. Pre-send BUSY check with queue fallback (`_doey_send_precheck`). Returns
   2 if the precheck queued the message instead of sending immediately.
2. Acquires a per-pane atomic mkdir lock under `<runtime>/locks/`. Stale
   locks (PID dead or older than 30s) are reaped.
3. For up to 4 attempts with exponential backoff:
   - Wait up to 30s (10s on retries) for the visible Claude prompt `❯`.
     If it never appears, send `C-c` to unstick the pane and retry.
   - Pre-clear input: `copy-mode -q`, `Escape`, `C-u`.
   - Atomic delivery via `tmux set-buffer` + `tmux paste-buffer`.
   - Settle (`PASTE_SETTLE_MS`, default 800ms), then send `Enter`.
   - Poll for up to 3s for `BUSY` status or activity indicators
     (`Reading`, `Writing`, `Editing`, `Bash`, `Glob`, `Grep`, `Agent`,
     spinner glyphs). At the halfway mark, attempt an `Escape`+`Enter`
     recovery in case the pane was in a modal state.
4. Returns 0 on success, 1 on failure after all retries, 2 if precheck
   queued.

`doey_send_command` (`shell/doey-send.sh:322`) is the fire-and-forget
counterpart for shell commands — no readiness gate, no verification.

### 5.2 Role restrictions enforced by `on-pre-tool-use.sh`

Every send-keys call passes through the pre-tool-use hook before tmux
sees it. The role-based rules are:

| Role | Send-keys policy | Source |
|---|---|---|
| Boss (0.1) | Only allowed to send-keys to the Taskmaster pane. Anything else is BLOCKED with `FORWARDED: Command relay request sent to ${DOEY_ROLE_COORDINATOR}.` and the original command is forwarded as an `action_request` message. | `on-pre-tool-use.sh:580-603` |
| Taskmaster (1.0) | May send-keys to any pane in window 0 (Boss/Info Panel) and to any team window pane. Dispatching to a team window requires at least one `active`/`in_progress` task — otherwise BLOCKED `:1024-1029`. Dispatching to a worker pane in a reserved team window is BLOCKED — `Route through the team Subtaskmaster.` (`:991-1007`). |
| Subtaskmaster / Team Lead (N.0) | Free to send-keys within its own team window (workers + own pane). |
| Workers (N.1+) | All `tmux send-keys`, `tmux paste-buffer`, `tmux load-buffer`, `tmux kill-*` are blocked, with one explicit exception: a worker may send-keys to its team's coordinator pane (resolved from `session.env`'s `TASKMASTER_PANE` — `:1057-1067`). Anything else is FORWARDED to the team Subtaskmaster as an `action_request` message. |
| Task Reviewer (1.1) | All `tmux send-keys` are blocked: "Report results via task files." (`:700-705`) |
| Core Team specialists (Task Reviewer, Deployment, Doey Expert) | `Agent` tool blocked. Project-source `Read/Edit/Write/Glob/Grep` blocked except for `.doey/tasks/*`, `.doey/plans/*`, `<runtime>/*`, and `/tmp/doey/*`. |
| Info Panel (0.0) | Shell-only pane, no Claude — early exit `allow_info_panel`. |

Universal guards on `tmux send-keys` payloads:

| Pattern | Result | Source |
|---|---|---|
| `tmux send-keys ... /rename ...` (any role) | BLOCKED. The slash-rename command would silently rename a Claude session and break wait-hook scoping. | `on-pre-tool-use.sh:946-951` |
| `tmux kill-session` / `tmux kill-server` / `tmux kill-window` | BLOCKED for managers — "Managers cannot run destructive tmux commands." | `on-pre-tool-use.sh:849-853` |
| `git push --force` / `--force-with-lease` | BLOCKED for everyone. | `on-pre-tool-use.sh:752-758` |
| Pushing to `main`/`master` directly | BLOCKED for everyone except Deployment. | `on-pre-tool-use.sh:725-...` |
| Empty send-keys body | Don't do it. The verified helper guards against pre-clear-only sends, but raw `tmux send-keys -t <pane>` with no payload will leave the target waiting on a stray `Enter`. |

### 5.3 Practical rules

- Workers: never call `tmux send-keys` directly. Stop the worker, write
  proof, and let `stop-notify.sh` handle the chain. The one allowed
  exception (worker → coordinator) is for emergency forwarding only.
- Subtaskmaster: if you must address a worker, address its full pane
  (`<session>:<window>.<pane>`), not the bare `<window>.<pane>` — the
  hook resolution is more reliable when the session prefix is present.
- Boss: never craft tmux commands manually. Prefer `doey-ctl msg send`
  with `--to <pane>`, which writes the message file and touches the
  trigger atomically.
- Always use `doey_send_verified` from inside scripts instead of raw
  `tmux send-keys`. It is the only path that handles BUSY pre-check,
  per-pane locking, prompt readiness, paste-buffer atomicity, retry, and
  submission verification.
- Never embed `/rename` or any other slash-command of Claude Code inside a
  send-keys payload — the pre-tool-use hook will block the call (see
  `on-pre-tool-use.sh:946`).
- Never send an empty string. There is no use case and the hook will
  silently drop a malformed buffer.

---

## 6. Agent-level message contracts

Each role's outbound and inbound message vocabulary is specified in its
agent file:

| Role | File |
|---|---|
| Boss | `agents/doey-boss.md` |
| Taskmaster | `agents/doey-taskmaster.md` |
| Subtaskmaster | `agents/doey-subtaskmaster.md` |
| Worker | `agents/doey-worker.md` (also `doey-worker-quick.md`, `doey-worker-deep.md`, `doey-worker-research.md`) |
| Freelancer | `agents/doey-freelancer.md` |
| Task Reviewer | `agents/doey-task-reviewer.md` |
| Deployment | `agents/doey-deployment.md` |
| Doey Expert | `agents/doey-doey-expert.md` |
| Interviewer | `agents/doey-interviewer.md` |

When in doubt about whether a subject exists or who consumes it, grep:

```
grep -rE "subject:|--subject" /home/doey/doey/.claude/hooks /home/doey/doey/shell /home/doey/doey/agents
```

That command produced the table in section 3 of this document.
