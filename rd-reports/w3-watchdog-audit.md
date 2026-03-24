# W3 Audit: watchdog-scan.sh Anomaly Detection

**File:** `.claude/hooks/watchdog-scan.sh`
**Date:** 2026-03-24
**Analyst:** Worker 3 (R&D team)

---

## Environment Setup

**Does it source common.sh?** NO — `watchdog-scan.sh` is fully standalone. It defines its own local versions of:
- `_log()` (writes to `$RUNTIME_DIR/logs/${DOEY_PANE_ID:-watchdog}.log`)
- `_pane_log()` (writes to `$RUNTIME_DIR/logs/<pane_id>.log`)
- `_atomic_write()`, `is_numeric()`, `NL`

**Env vars loaded:**
- `RUNTIME_DIR` — from tmux environment (`DOEY_RUNTIME`)
- `PANE_INFO`, `WINDOW_INDEX`, `PANE_INDEX` — from current pane
- `TARGET_WINDOW` — resolved by scanning `team_*.env` files for WATCHDOG_PANE match
- `WORKER_PANES`, `SESSION_NAME` — read from team env file
- `SESSION_SAFE`, `SCAN_TIME` — computed
- `PREV_STATE_<i>` — loaded from `watchdog_pane_states_W<N>.json`
- `SNAPSHOT_EVENTS` — accumulated in-memory, flushed to snapshot file at end

**Output channels:**
1. `stdout` — consumed by the Watchdog LLM as its input
2. `_log()` — watchdog's own log file
3. `_pane_log()` — per-pane log files
4. Status files in `$RUNTIME_DIR/status/`
5. `SNAPSHOT_EVENTS` string → `team_snapshot_W<N>.txt` EVENTS section

---

## Detection Points

### 1. Manager Crashed
**Lines:** 191–204
**Detection:** Manager pane's `pane_current_command` is a bare shell (`bash`/`zsh`/`sh`/`fish`) — Claude process has exited.
**Context available:** `TARGET_WINDOW`, timestamp via `date +%s`
**Action:**
- `echo "MANAGER_CRASHED"` → stdout
- Creates crash alert file `status/manager_crashed_W<N>` (one-time, contains `TEAM_WINDOW` + `TIMESTAMP`)
- If crash already flagged, skips write (idempotent)

**Logging gaps:**
- NOT logged via `_log()`
- NOT added to `SNAPSHOT_EVENTS`
- Crash file is created but never referenced in the events stream → watchdog sees the echo on stdout but team snapshot's EVENTS section has nothing

---

### 2. Manager Logged Out
**Lines:** 211–215
**Detection:** Manager pane capture contains `"Not logged in"`
**Context available:** `TARGET_WINDOW`, pane capture text
**Action:**
- Sets `PANE_STATE_0="LOGGED_OUT"`
- `echo "MANAGER_LOGGED_OUT"` → stdout

**Logging gaps:**
- NOT logged via `_log()`
- NOT added to `SNAPSHOT_EVENTS`
- `_update_duration` is never called for manager states → no STATE_CHANGE event either
- Completely silent in persistent logs

---

### 3. Manager Completed (WORKING → IDLE)
**Lines:** 221–225
**Detection:** Previous scrape state was `WORKING`, current is `IDLE`
**Context available:** states from `manager_prev_state_W<N>` file
**Action:**
- `echo "MANAGER_COMPLETED"` → stdout

**Logging gaps:**
- NOT logged via `_log()`
- NOT added to `SNAPSHOT_EVENTS`
- Purely ephemeral stdout signal

---

### 4. Manager Possibly Stuck
**Lines:** 233–251
**Detection:** Hook status is `READY`/`FINISHED` but screen-scrape shows `WORKING`
**Context available:** `_mgr_hook_status`, screen-scraped state
**Action:**
- `echo "MANAGER_POSSIBLY_STUCK (hook=... scrape=WORKING)"` → stdout
- `SNAPSHOT_EVENTS += "MANAGER_POSSIBLY_STUCK ..."`
- `_log()` called with detail

**Coverage:** WELL COVERED — logged, in snapshot events, on stdout.

---

### 5. Manager Activity Events
**Lines:** 253–272
**Detection:** File `status/manager_activity_W<N>` exists with an `EVENT` key
**Context available:** `EVENT`, `TASK` fields
**Action:**
- `echo "MANAGER_ACTIVITY ..."` → stdout
- `SNAPSHOT_EVENTS += "MANAGER_ACTIVITY ..."`
- `_log()` called
- Event file consumed (deleted)

**Coverage:** WELL COVERED.

---

### 6. Worker Crashed
**Lines:** 296–318
**Detection:** Worker pane's current command is a bare shell AND hook status is not `FINISHED`/`RESERVED`
**Context available:** pane index, timestamp, last 10 lines of pane output (stored in crash file), hook status
**Action:**
- Creates crash file `status/crash_pane_<W>_<i>` (one-time) with `PANE_INDEX`, `TIMESTAMP`, `LAST_OUTPUT` (last 5 lines)
- `_report_pane "$i" "CRASHED"` → echoes `"PANE <i> CRASHED"`, calls `_pane_log()`, calls `_update_duration()`

**Logging gaps:**
- Crash file is written but NOT referenced in `SNAPSHOT_EVENTS`
- `_update_duration` will add a `STATE_CHANGE <i> <prev>->CRASHED` to `SNAPSHOT_EVENTS` only if the previous display state differs — if the pane was already "CRASHED" in the prior cycle, no event fires
- No explicit `"CRASH <i>"` event type in snapshot — only generic STATE_CHANGE
- `_log()` is NOT called directly (only `_pane_log()` via `_report_pane`)

---

### 7. Worker Booting
**Lines:** 320–328
**Detection:** Pane has no prompt marker (`❯`, `bypass permissions`) AND current command is `node`
**Context available:** pane index
**Action:**
- `_report_pane "$i" "BOOTING" "" "BOOTING ${i}"` → stdout + `_pane_log()` + adds `"BOOTING <i>"` to `SNAPSHOT_EVENTS`

**Coverage:** ADEQUATE — logged and in snapshot events.

---

### 8. Worker Logged Out
**Lines:** 330–333
**Detection:** Pane capture contains `"Not logged in"`
**Context available:** pane index
**Action:**
- `_report_pane "$i" "LOGGED_OUT"` → stdout + `_pane_log()` + `_update_duration()` adds STATE_CHANGE if state changed

**Logging gaps:**
- No explicit `"LOGGED_OUT"` event in `SNAPSHOT_EVENTS` — only a generic `STATE_CHANGE` (and only if previously different state)
- If already logged out last cycle, no event fires at all

---

### 9–11. Worker Anomalies: PROMPT_STUCK / WRONG_MODE / QUEUED_INPUT
**Lines:** 337–355
**Detection:**
- `PROMPT_STUCK` (L338–344): pane contains `"Esc to cancel"` or `"Tab to amend"`
- `WRONG_MODE` (L345–347): pane contains `"accept edits on"`
- `QUEUED_INPUT` (L348–350): pane contains `"queued messages"` or `"Press up to edit"`

**Context available:** pane index, pane capture (used for snippet in `_process_anomalies`)
**Action (lines 352–355):**
- `echo "PANE <i> <anomaly_type>"` → stdout
- `SNAPSHOT_EVENTS += "ANOMALY <i> <type>"`

**For PROMPT_STUCK specifically:** auto-sends `Enter` to the stuck pane (L343) — remediation action

**Logging gaps:**
- NO `_log()` call for any anomaly detection
- NO `_pane_log()` call
- The auto-Enter keypress for `PROMPT_STUCK` is **completely unlogged** — no trace anywhere
- `_process_anomalies()` (L572–615) later writes `.event` files per anomaly and escalates after 3 cycles, but still no `_log()` call there either

---

### 12. Worker STUCK
**Lines:** 391–410
**Detection:** Content hash unchanged for ≥6 cycles while CPU is active or hook says `BUSY`
**Context available:** pane index, `NEW_COUNT` (cycles stuck), CPU delta
**Action:**
- `echo "PANE <i> STUCK (CPU active but no output for <N> cycles)"` → stdout
- `_pane_log()` called with `unchanged_cycles=<N>`
- `_update_duration "$i" "WORKING" "WORKING"` — **same-state call**

**Logging gaps:**
- `_update_duration("WORKING", "WORKING")` never fires a `STATE_CHANGE` event → **STUCK is never recorded in `SNAPSHOT_EVENTS`**
- Logged to pane log, visible on stdout, but absent from the team snapshot's EVENTS section
- The Watchdog Manager reads the snapshot; STUCK won't appear in its events feed

---

### 13. Wave Complete (All Workers Idle)
**Lines:** 489–502
**Detection:** Transition from `HAS_WORKING` to `ALL_IDLE` (no working/stuck/crashed workers)
**Context available:** worker counts
**Action:**
- `echo "WAVE_COMPLETE"` → stdout
- `SNAPSHOT_EVENTS += "WAVE_COMPLETE all_workers_idle"`

**Logging gaps:**
- NOT logged via `_log()`
- Goes to snapshot events (good), but no persistent log entry

---

### 14. Anomaly Escalation
**Line:** 606
**Detection:** An anomaly `.event` file persists across ≥3 scan cycles (counted in `anomaly_count_<W>_<pane>`)
**Context available:** pane, anomaly type, count
**Action:**
- `echo "ESCALATE ANOMALY <pane> <type> (<N> consecutive)"` → stdout only

**Logging gaps:**
- NOT logged via `_log()`
- NOT added to `SNAPSHOT_EVENTS`
- Stdout-only escalation signal — not persisted anywhere

---

### 15. Context Pressure (COMPACT_NOW)
**Lines:** 625–634
**Detection:** Watchdog's own context meter (scraped from its own pane) is ≥60%
**Context available:** context percentage
**Action:**
- `echo "⚠️  COMPACT_NOW — context at ${_ctx_pct}% ..."` → stdout

**Logging gaps:**
- NOT logged via `_log()`
- NOT in `SNAPSHOT_EVENTS`
- Stdout-only signal; if Watchdog misses it, no trace

---

## Summary Table

| Detection Point | stdout | `_log()` | `_pane_log()` | SNAPSHOT_EVENTS | Status file |
|---|---|---|---|---|---|
| Manager Crashed | ✓ | ✗ | ✗ | ✗ | ✓ (crash file) |
| Manager Logged Out | ✓ | ✗ | ✗ | ✗ | ✗ |
| Manager Completed | ✓ | ✗ | ✗ | ✗ | ✗ |
| Manager Possibly Stuck | ✓ | ✓ | ✗ | ✓ | ✗ |
| Manager Activity | ✓ | ✓ | ✗ | ✓ | consumed |
| Worker Crashed | ✓ | ✗ | ✓ | STATE_CHANGE only | ✓ (crash file) |
| Worker Booting | ✓ | ✗ | ✓ | ✓ | ✗ |
| Worker Logged Out | ✓ | ✗ | ✓ | STATE_CHANGE only | ✗ |
| PROMPT_STUCK | ✓ | ✗ | ✗ | ✓ | .event file |
| WRONG_MODE | ✓ | ✗ | ✗ | ✓ | .event file |
| QUEUED_INPUT | ✓ | ✗ | ✗ | ✓ | .event file |
| Auto-Enter keypress | ✗ | ✗ | ✗ | ✗ | ✗ |
| Worker STUCK | ✓ | ✗ | ✓ | **MISSING** | ✗ |
| Wave Complete | ✓ | ✗ | ✗ | ✓ | ✗ |
| Anomaly Escalation | ✓ | ✗ | ✗ | ✗ | count file |
| Context Pressure | ✓ | ✗ | ✗ | ✗ | ✗ |

---

## Critical Gaps

### [HIGH] STUCK state absent from SNAPSHOT_EVENTS (line 409)
`_update_duration "$i" "WORKING" "WORKING"` passes identical prev/cur states, so `STATE_CHANGE` never fires. The Watchdog LLM reads the snapshot; STUCK workers are invisible in the EVENTS feed. The only trace is stdout (ephemeral) and `_pane_log()`.

### [HIGH] Manager state events not in SNAPSHOT_EVENTS (lines 193, 214, 224)
`MANAGER_CRASHED`, `MANAGER_LOGGED_OUT`, and `MANAGER_COMPLETED` are echo-only. They vanish from the persistent record. If the Watchdog doesn't act on them during the current cycle, the information is lost — no snapshot entry, no log file entry.

### [MEDIUM] Auto-Enter for PROMPT_STUCK is completely untraced (line 343)
The watchdog silently sends `Enter` to a stuck worker pane. There is no log, no snapshot event noting the remediation action was taken. Audit trail is zero.

### [MEDIUM] Anomaly escalation not logged (line 606)
`ESCALATE ANOMALY` goes to stdout only. If the Watchdog LLM misses it or is mid-compact, the escalation is silently dropped.

### [MEDIUM] Manager Logged Out / Completed not logged anywhere persistent
Both are pure stdout. These are notable state transitions but leave no file trace (no `_log()`, no `.status` update, no snapshot event).

### [LOW] Wave Complete not in `_log()` (line 501)
Goes to `SNAPSHOT_EVENTS` but not the watchdog's own log file. Minor gap since snapshot is persistent.

### [LOW] Context pressure (COMPACT_NOW) not logged (line 632)
Could be useful for post-hoc debugging of why the watchdog compacted, but leaves no trace.

---

## Notable Design Observations

1. **Does not source common.sh** — fully standalone. `_log()` here writes to the watchdog's log (DOEY_PANE_ID), while `_pane_log()` writes to the scanned pane's log. The common.sh `_log()` would write to the caller's pane log. Intentionally decoupled.

2. **`_process_anomalies()` runs after snapshot write** — anomaly `.event` files are written and escalation fires after the snapshot is already flushed to disk. Escalation `ESCALATE` lines only go to stdout, not back into the snapshot.

3. **Manager health uses two independent signals** — screen-scrape (`PANE_CAPTURE`) and hook-written `.status` file. Only the reconciliation conflict (possibly stuck) is logged; normal override (hook=BUSY overrides scrape=IDLE) is logged but not evented.

4. **Crash files are one-shot** — both manager and worker crash files use a `[ ! -f "$CRASH_FILE" ]` guard, so they only capture the first crash occurrence. Re-crashes (e.g., after restart) won't update the file until it's manually cleared or expires.
