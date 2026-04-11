# Violations

Structured event stream for self-inflicted Doey regressions. Detected at hook
fire-time, recorded in `.doey/doey.db`, surfaced in the Go TUI under
**Logs → Violations**. The first class is `violation_polling` (task #525);
future classes reserve slots under the same schema.

---

## 1. Overview

### 1.1 The bug class we are permanently fixing

Task #523 burned 8k+ tokens in 14 minutes when a Subtaskmaster pane forever-
looped on `WAKE_REASON=MSG`. The mechanism:

1. `taskmaster-wait.sh` checks `doey msg count --to <pane>` (non-consuming).
2. If unread > 0 it fires `WAKE_REASON=MSG` and exits.
3. The agent runs `doey msg read --pane X` — **non-consuming by default**.
4. Messages stay unread. Control returns to the wait hook.
5. Unread count is still > 0. Goto 2.

The root fix is `--unread` on every agent call (or the explicit
Taskmaster `msg read` → `msg read-all` two-step). The Violations system is
the safety net: it detects the loop if it ever re-emerges, circuit-breaks
the offending pane, and makes the event visible.

### 1.2 Why an event stream instead of just the fix

- The agents/templates are always one refactor away from regressing. A
  regression guard in the form of a regex-based audit (`test-unread-audit.sh`)
  catches static drift; a runtime detector catches dynamic drift.
- Future violation classes (AskUserQuestion misuse from #522, premature-kill
  checks, etc.) can reuse the same schema, same TUI view, same contract.
- Task #521's Stats system lives in the same `events` table. Coordinating
  once keeps `.doey/doey.db` as the single source of truth.

---

## 2. Schema reference

### 2.1 Table: `events`

The `events` table pre-exists in `tui/internal/store/schema.go`. Task #525
extends it with a transactional `ADD COLUMN` batch that runs inside the
same transaction as `ensureSchema` — partial-migration state is impossible.

| Column | Type | Source | Notes |
|---|---|---|---|
| `id` | INTEGER PK | auto | legacy |
| `type` | TEXT | legacy | free-form event type string |
| `source` | TEXT | legacy | often `PANE_SAFE` |
| `target` | TEXT | legacy | — |
| `task_id` | INTEGER | legacy | — |
| `data` | TEXT | legacy | free-form |
| `created_at` | INTEGER | legacy | unix seconds |
| **`class`** | TEXT | #525 | discriminator: `violation_polling`, `stat_*`, … |
| **`severity`** | TEXT | #525 | `warn` \| `breaker` \| `info` \| `debug` |
| **`session`** | TEXT | #525 | `SESSION_NAME`; disambiguates across concurrent sessions |
| **`role`** | TEXT | #525 | role id (e.g. `subtaskmaster`, `coordinator`) |
| **`window_id`** | TEXT | #525 | `W2`, `C`, `0`, etc. |
| **`wake_reason`** | TEXT | #525 | `MSG`, `TIMEOUT`, `TRIGGERED`, … |
| **`unread_msg_ids`** | TEXT | #525 | CSV of positive integers; empty `""` allowed |
| **`extra_json`** | TEXT | #525 | escape hatch — do **not** use for indexable fields |
| **`consecutive_count`** | INTEGER | #525 | counter value at emit time |
| **`window_sec`** | INTEGER | #525 | elapsed seconds of the rolling window at emit time |

### 2.2 Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_events_class_created
    ON events(class, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_severity
    ON events(severity);
```

Both are covering for the hot read path
(`SELECT … WHERE class='violation_polling' ORDER BY created_at DESC LIMIT 100`).

### 2.3 Migration discipline

- **Idempotent.** `ADD COLUMN` is re-run on every `store.Open`; a
  "duplicate column" error is filtered by `isDuplicateColumnErr`, every
  other error rolls back the enclosing transaction.
- **Transactional.** All #525 statements share the `ensureSchema` transaction.
  Half-migrated schemas cannot exist.
- **Additive.** No column is renamed or dropped. Readers can open older DBs
  without crashing.

### 2.4 `PRAGMA table_info` column cache (belt-and-braces)

`store.Open` also builds an in-memory column cache via
`PRAGMA table_info(events)`. `store.ListEventsByClass` consults this cache
and skips columns that do not exist in this particular DB — so a reader
opening a DB that was initialized by an older binary (or a partially
upgraded DB from a crashed install) returns an empty slice rather than
crashing with `no such column: class`.

### 2.5 Format spec: `unread_msg_ids`

- Comma-separated list of positive integers.
- No spaces, no quotes, no trailing comma.
- Empty list is `""` (empty string).
- The hook emitter must **not** embed quotes, newlines, or `extra_json`-
  style structure in this column.
- If an emitter has more than ~64 IDs, truncate with a trailing `+` marker
  (e.g. `1,2,3,...,64+`). Display-only; do not rely on parse round-trips.

---

## 3. Class taxonomy

| Class literal | Owner task | Status | Description |
|---|---|---|---|
| `violation_polling` | #525 | **shipped** | Wait-hook polling loop detected |
| `violation_ask_user` | #522 | reserved | AskUserQuestion misuse (inline questions in text) |
| `violation_kill_premature` | future | reserved | Worker killed before proof |
| `stat_session_start` | #521 | shipped | Session start event |
| `stat_team_spawn` | #521 | shipped | Team spawn event |
| `stat_task_completed` | #521 | shipped | Task completion event |
| `stat_intent_fallback` | #521 | shipped | Intent fallback fired |
| `stat_install_run` | #521 | shipped | install.sh invocation |

The `class` column is the **discriminator**. Two orthogonal namespaces live
in the same table:

- `violation_*` classes represent self-inflicted regressions — expected
  count: zero. Non-zero is an alert.
- `stat_*` classes represent normal telemetry — expected count: non-zero.

TUI sub-views filter on `class` for their scope. Violations sub-view shows
only `violation_*`; Stats sub-view shows only `stat_*`.

### Adding a new class

1. Pick a literal: `violation_<noun>` or `stat_<noun>`.
2. Add a const in `tui/internal/store/events.go`:
   `const ViolationAskUser = "violation_ask_user"`.
3. Extend the emitter side (hook or Go code) to set `--class <literal>`.
4. Extend the reader side if needed: add a
   `store.ListEventsByClass(store.ViolationAskUser, limit)` call.
5. Optionally add a TUI sub-view (new file mirroring
   `tui/internal/model/violations.go`), or reuse the existing Violations
   view with a wider filter.
6. Document the class in this file (section 3 table above).

---

## 4. `violation_bump_counter` contract

The shell helper that powers detection. Lives in `.claude/hooks/common.sh`.
Called from `taskmaster-wait.sh` and `reviewer-wait.sh` at the top of the
hook, before any wake-reason branching.

### 4.1 Parameters

```
violation_bump_counter <pane_safe> <wake_reason> <session> <role> <window_id>
```

All positional. No array args, no namerefs (bash 3.2).

### 4.2 Wake-state ledger

File: `/tmp/doey/<session>/wait-state-<pane_safe>.json`

```json
{
  "last_wake_reason": "MSG",
  "consecutive_count": 3,
  "window_start_ts": 1712834567,
  "last_wake_ts": 1712834612,
  "next_wake_earliest": 0,
  "breaker_tripped": false
}
```

- Plain-text JSON emitted via `printf`, read via `grep -oE`.
- No `jq` dependency (fresh-install invariant).
- Field values constrained to `[A-Z_]` (wake_reason), `[0-9]+` (integers),
  `true`/`false` (breaker_tripped) — no escaping required.
- Ledger is wiped by session teardown along with the rest of
  `/tmp/doey/<session>/`.

### 4.3 Reset signal

The **only** mechanism that clears `consecutive_count` and `breaker_tripped`
is the tool-use sentinel:

File: `${RUNTIME_DIR}/status/<pane_safe>.tool_used_this_turn`

- Written by `.claude/hooks/on-pre-tool-use.sh` on every successful tool
  call (after the existing allow-path guards).
- Checked by `violation_bump_counter` at the top of every invocation.
- If present → counter + latch clear, sentinel deleted, helper returns 0.
- If absent → continue to the bump path.

Rationale: `on-prompt-submit.sh` fires on **every** wake-delivered turn —
the very event the detector is counting. Using prompt-submit as reset
would guarantee the counter never reaches the warn threshold. Tool use is
the only signal that correlates with "the agent actually did something
this turn."

### 4.4 Logic (pseudocode)

```
1.  if DOEY_ENFORCE_VIOLATIONS == "off" → return 0
2.  if command -v doey-ctl fails → return 0  (fresh-install safety)
3.  mkdir lock, retry 3× with 50ms backoff; on 4th failure → log
    "violation_lock_contention" and return 0 (fail-open)
4.  if sentinel exists → reset counter + latch, delete sentinel, return 0
5.  if next_wake_earliest > now → return 0  (backoff in progress)
6.  read ledger (initialize if missing)
7.  if wake_reason != last_wake_reason → window_start_ts=now,
       consecutive_count=1  (breaker latch NOT cleared — only tool use clears)
8.  else if now - window_start_ts > 120 → window_start_ts=now,
       consecutive_count=1  (window expiry)
9.  else consecutive_count++
10. write back: last_wake_reason, last_wake_ts, consecutive_count,
       window_start_ts, breaker_tripped, next_wake_earliest
11. if consecutive_count == 3 → emit warn event
       (all modes except "off", which short-circuited at step 1;
        "shadow" still emits)
12. if consecutive_count == 5 AND NOT breaker_tripped
       AND DOEY_ENFORCE_VIOLATIONS == "on" →
         breaker_tripped = true
         next_wake_earliest = now + 30
         emit breaker event
         send nudge message to owner
13. if consecutive_count == 5 AND NOT breaker_tripped
       AND DOEY_ENFORCE_VIOLATIONS == "shadow" →
         emit breaker event only
         (no latch set, no next_wake_earliest, no nudge)
14. release lock (rmdir)
```

### 4.5 Window expiry

Rolling window of **120 seconds** from the first wake in the current run.
If a same-reason wake arrives after the window expires, the window resets
and the counter restarts at 1. Slow, sporadic wakes will never trip warn
no matter how long the process runs.

### 4.6 Owner resolution for nudge

- If the affected pane's role is `coordinator` (Taskmaster self-loop) →
  owner is `0.1` (Boss).
- Otherwise → owner is `${DOEY_CORE_WINDOW}.0` (Taskmaster).

Nudge subject: `polling_loop_breaker`. Body template:
`pane=<pane_safe> reason=<reason> consecutive=5 window_sec=<N> session=<session>`.

**Accepted risk:** when the owner is Boss, the nudge sits in the Boss
inbox until the user returns. That is fine — the breaker's job is
"stop burning tokens," not "instant remediation."

---

## 5. Env knobs

### 5.1 Production

| Env | Values | Default | Effect |
|---|---|---|---|
| `DOEY_ENFORCE_VIOLATIONS` | `on` \| `shadow` \| `off` | `on` | see below |

- **`on`** (default). Full detection + latched breaker + nudge.
- **`shadow`**. Detection runs, warn + breaker events are written to the
  DB, but `next_wake_earliest` is **not** set, `breaker_tripped` is **not**
  latched, and no nudge is sent. Use for canary rollouts: observe the
  signal without changing runtime behavior.
- **`off`**. Helper returns 0 at step 1. Zero overhead, zero events, zero
  side effects.

### 5.2 Test-only

| Env | Purpose |
|---|---|
| `DOEY_VIOLATION_STUB` | Path to a JSONL file. When set, `violation_bump_counter` appends each event as a JSON line **instead of** calling `doey-ctl event log`. Tests use this to avoid a real DB + binary. |
| `DOEY_SKIP_MSG_COUNT` | When set, `taskmaster-wait.sh` skips the `doey msg count` call and assumes `WAKE_REASON` from `DOEY_TEST_WAKE_REASON`. Avoids needing a seeded DB for repro tests. |
| `DOEY_TEST_CLOCK` | Overrides `now` inside `violation_bump_counter` for deterministic window-expiry assertions. Unix seconds. |

All three are marked with `# TEST-ONLY ENV` comments in `common.sh` so a
`grep` pass can find them at audit time.

---

## 6. Nudge latch contract

**"At most one breaker nudge per `(pane, wake_reason)` tuple until the
reset signal."**

Mechanism:

1. First time `consecutive_count` hits 5, the helper sets
   `breaker_tripped=true` and emits one `breaker` event + one nudge.
2. Subsequent wakes at count ≥ 5 observe `breaker_tripped=true` and emit
   **nothing** — no event, no nudge. The counter keeps bumping but the
   side-effects are suppressed.
3. When the reset sentinel appears (a successful tool call in a later
   turn), the helper clears both `consecutive_count` and `breaker_tripped`.
4. If the loop re-emerges, the cycle restarts from zero.

Without this latch, a persistently broken pane would emit a nudge every
wake after count 5 — turning the safety net into the next polling loop.

---

## 7. Shadow-mode semantics

`DOEY_ENFORCE_VIOLATIONS=shadow` is the canary mode for rolling out new
detection classes without risking runtime disruption.

- ✅ Detection runs.
- ✅ Counter bumps normally.
- ✅ `warn` events are emitted.
- ✅ `breaker` events are emitted (to the DB, as observation signal).
- ❌ `breaker_tripped` latch is **not** set.
- ❌ `next_wake_earliest` backoff is **not** applied.
- ❌ Nudge message is **not** sent.

Use shadow mode to validate a new class literal against real traffic
before flipping to `on`.

---

## 8. Hook integration recipe

A new hook that wants to emit a violation follows this shape:

```bash
# Load helpers from common.sh (already sourced by all wait hooks)
source "$(dirname "$0")/common.sh"

# Call the helper — it does the rest
violation_bump_counter \
    "$PANE_SAFE" \
    "$WAKE_REASON_YOU_OBSERVED" \
    "$SESSION_NAME" \
    "$DOEY_ROLE_ID" \
    "$DOEY_TEAM_WINDOW"
```

For ad-hoc (non-counter-based) violation emission, call `doey-ctl` directly:

```bash
(doey-ctl event log \
    --class violation_ask_user \
    --severity warn \
    --session "$SESSION_NAME" \
    --role "$DOEY_ROLE_ID" \
    --window-id "$DOEY_TEAM_WINDOW" \
    --extra-json '{"line":42}' \
    --project-dir "$PROJECT_DIR" &) 2>/dev/null
```

Background subshell + stderr-to-null is the established pattern (see
`stop-status.sh:143-149`). Event loss on `doey-ctl` panic is acceptable
for observability classes.

---

## 9. TUI walkthrough

### Logs → Violations sub-view

```
┌─ Logs ──────────────┐  ┌─ Violations ─────────────────────────────────┐
│  ◆ Logs             │  │ polling: 2 warn / 1 breaker                  │
│  → Messages         │  │                                              │
│  • Debug            │  │ ⛔ 14:32:07  W2.0  subtaskmaster   BREAKER   │
│  › Info             │  │ ⛔ 14:31:55  W2.0  subtaskmaster   WARN      │
│  ⚡ Activity         │  │ ⛔ 14:18:22  C.2   deployment      WARN      │
│  ◇ Interactions     │  │                                              │
│▶ ⛔ Violations      │  │ ─────────────────────────────────────────── │
│                     │  │ pane:         W2.0                           │
│                     │  │ role:         subtaskmaster                  │
│                     │  │ wake_reason:  MSG                            │
│                     │  │ consecutive:  5                              │
│                     │  │ window_sec:   47                             │
│                     │  │ session:      doey-doey                      │
│                     │  │                                              │
│                     │  │ [f] filter: all | warn | breaker             │
└─────────────────────┘  └──────────────────────────────────────────────┘
```

Key bindings:

- `j` / `k` — navigate
- `f` — cycle severity filter (`all` → `warn` → `breaker` → `all`)
- Enter / mouse click — select row (detail panel updates)

Empty state (fresh install, no events yet):

```
No violations recorded.
```

---

## 10. Troubleshooting

### I see a `warn` row. What now?

One `warn` row means a pane wake-looped 3 times within 120 seconds without
using a tool in between. Most likely causes:

1. An agent template reverted to a non-`--unread` `doey msg read` call.
   Run `bash tests/test-unread-audit.sh` and fix any offenders.
2. A hook other than the wait hook is pushing stale trigger files.
3. The agent is legitimately looping on non-tool-using turns (pure
   thinking). Rare; usually indicates a bug in the agent prompt.

Inspect the row's `role`, `window_id`, `wake_reason`, `unread_msg_ids` to
locate the pane and the message(s) involved.

### I see a `breaker` row. What now?

The pane tripped the 5-consecutive threshold. It is now on a 30s backoff
and the owner (Taskmaster or Boss) has received a `polling_loop_breaker`
nudge. Actions:

1. Read the nudge in the owner's inbox for pane coordinates.
2. Check `doey msg list --to <pane>` — what's queued?
3. Check the pane's recent activity via `doey monitor`.
4. If the pane is stuck, manually dispatch a real task or respawn via
   `/doey-respawn-me`.
5. Fix the root cause — revert a bad template edit, restart the hook with
   fixed code, etc.

### Breaker keeps re-firing

It should not. The latch is per-`(pane, wake_reason)` tuple until the
reset sentinel appears. If you see duplicate `breaker` rows with the same
pane + reason AND no intervening tool use, the latch is broken — file a
bug.

### No events visible in the TUI but the DB has rows

`store.ListEventsByClass` uses the column cache. If the cache thinks
`class` does not exist (e.g. the DB was opened by an older binary first),
the query returns empty. Close the dashboard, run any `doey-ctl event log`
invocation once (which re-runs `ensureSchema` with the new migrations),
reopen the dashboard.

### `DOEY_VIOLATION_STUB` is set in production

It should not be. `DOEY_VIOLATION_STUB`, `DOEY_SKIP_MSG_COUNT`, and
`DOEY_TEST_CLOCK` are **test-only** env vars. If one is set in a live
session, events will appear in a JSONL file instead of the DB — grep for
`TEST-ONLY ENV` in `common.sh` to find which knob leaked.

---

## 11. Contract with task #521 (Stats)

Task #521 lands a Stats sub-view on the same Logs tab, reading from the
same `events` table via the same `store` package.

**Ordering contract.**

- Whichever task merges first lands the #525 migration columns (they are
  additive and idempotent).
- The second task rebases onto the first and finds the columns already
  present — `ADD COLUMN` errors are silently absorbed.
- Neither task drops or renames anything.

**Read-path contract.**

- Stats reads `WHERE class LIKE 'stat_%'`; Violations reads
  `WHERE class = 'violation_polling'` (and future `violation_*` classes).
- The two read paths are orthogonal — neither can starve the other.
- Both ride the existing 2-second `SnapshotMsg` tick. No new tickers.

**Flag-namespace contract.**

- Stats uses `--type`, `--source`, `--data`, `--task-id` (legacy columns).
- Violations uses `--class`, `--severity`, `--session`, `--role`,
  `--window-id`, `--wake-reason`, `--unread-msg-ids`, `--extra-json`,
  `--consecutive`, `--window-sec` (new columns).
- No collision.

**Invariant.** `.doey/doey.db` is the **single** sqlite file. There is no
`.doey/stats.db` — earlier drafts of both briefs used that name; it was
a misnomer. Creating a second file would split locks and break the
dashboard's single-reader design.
