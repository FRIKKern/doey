# W6 Live Logs Audit
**Date:** 2026-03-24
**Session:** doey-doey
**Log window:** 02:44 – 02:55 UTC (11 minutes)
**Files examined:** 18 log files, 2 result JSONs, 5 anomaly/status files

---

## Log Structure Overview

| File pattern | Content | Lines (typical) |
|---|---|---|
| `{W}.{P}.log` | Watchdog-observed pane state changes only | 3–6 |
| `t{W}-wd.log` | Watchdog cycle summaries for window W | 31–45 |
| `t3-wd.log` | Window 3 watchdog — only 3 lines (very early) | 3 |
| `unknown.log` | Unified event log: task_started, stop-status, stop-notify, stop-results | 84 |
| `results/pane_*.json` | Stop-hook result dumps with last_output | varies |
| `status/anomaly_*.event` | Watchdog-detected anomaly events | per-pane |
| `status/anomaly_count_*` | Counter for anomaly occurrences | 1 line |

---

## Real Errors Found

### Error 1 — PROMPT_STUCK false positives
**Pane/role:** W1.1, W1.2, W1.3 (Workers)
**Type:** Watchdog anomaly — `TYPE=PROMPT_STUCK`
**Count:** W1.1 = 3 occurrences, W1.2 = 1, W1.3 = 1
**Evidence:**
```
# status/anomaly_1_1.event
TYPE=PROMPT_STUCK
PANE=1
WINDOW=1
TIMESTAMP=1774317307
SNIPPET=|||
```
**Context available:** Timestamp, pane/window ID, anomaly type.
**Context missing:** The `SNIPPET=|||` value is empty/sentinel — no actual pane content captured. No reason for why it was classified as stuck (idle threshold, expected vs. actual state). No correlation with what task was running.
**Assessment:** Likely false positive. The result JSONs for panes 1.1 and 1.2 show tasks completed successfully. Pane 1.1 had count=3, suggesting it was flagged stuck repeatedly while actually working.

---

### Error 2 — `status=error` in result files despite task success
**Pane/role:** W1.1 (`⠐ T1 W1`), W1.2 (`⠂ T1 W2`)
**Type:** Stop-hook status mismatch — result written with `status=error` but task output shows success
**Count:** 2 panes in this session
**Evidence:**
```
# unknown.log
[2026-03-24T02:53:20] stop-results: wrote result to /tmp/doey/doey/results/pane_1_1.json (status=error, tools=2)

# pane_1_1.json (excerpt from last_output):
"=== Bash 3.2 Compat: 26 files, 0 violations ===\nPASS"
"status": "error"  ← contradicts the successful output
```
The actual `last_output` in both JSONs shows:
- common.sh modified, bash -n passed, compat test PASS
- post-tool-lint.sh modified, bash -n passed, compat test PASS

**Context available:** Last output text, tool call count, pane title, timestamp.
**Context missing:** The exit code or condition that triggered `status=error`. No hook stderr captured. No indication of which stop hook set the error status. The `pane_id` field is `"unknown"` in both results — DOEY_* env vars not available at stop time.

---

### Error 3 — `manager hook=BUSY overrides scrape=IDLE`
**Pane/role:** W1.0 (Manager), W2.0 (Manager)
**Type:** State reconciliation conflict — hook-reported BUSY contradicts screen-scrape result
**Count:** Appears in 4 of 13 W1 watchdog cycles (31%), 1 of 21 W2 cycles (5%)
**Evidence:**
```
# t1-wd.log
[2026-03-24 02:44:24] watchdog-scan: manager hook=BUSY overrides scrape=IDLE
[2026-03-24 02:52:08] watchdog-scan: manager hook=BUSY overrides scrape=IDLE
[2026-03-24 02:53:07] watchdog-scan: manager hook=BUSY overrides scrape=IDLE
[2026-03-24 02:54:08] watchdog-scan: manager hook=BUSY overrides scrape=IDLE
```
**Context available:** Which pane, which window, time, direction of override.
**Context missing:** What the screen scrape actually saw vs. what the hook file contained. No way to distinguish legitimate override (manager actually busy) from stale hook file (manager finished but hook file not cleared). No hook file age/freshness info.

---

### Error 4 — `pane_id: "unknown"` in all result files
**Pane/role:** All workers (W1.1, W1.2)
**Type:** Identity resolution failure at stop time
**Count:** Both result files affected (100% of results in this session)
**Evidence:**
```json
{
  "pane": "1.1",
  "pane_id": "unknown",
  "full_pane_id": "unknown",
  ...
}
```
**Context available:** The `pane` field correctly shows `"1.1"` but both `pane_id` and `full_pane_id` are `"unknown"`.
**Context missing:** The tmux pane ID (e.g., `%23`) was not resolvable at stop-hook time. No indication of why — could be tmux session not found, TMUX env var missing, or lookup timing issue.

---

### Error 5 — t3-wd.log prematurely truncated
**Pane/role:** W3 Watchdog
**Type:** Log stall — watchdog stopped producing log entries after 3 lines
**Count:** 1 instance
**Evidence:**
```
# t3-wd.log — only 3 entries, all from 02:44–02:46
[2026-03-24 02:44:39] watchdog-scan: start cycle W3 panes=0,1,2,3,4,5
[2026-03-24 02:44:44] watchdog-scan: start cycle W3 panes=0,1,2,3,4,5
[2026-03-24 02:46:05] watchdog-scan: start cycle W3 panes=0,1,2,3,4,5
```
No "end cycle" lines, no pane states. W3 appears to have stopped logging after startup. Could be watchdog crash, W3 being torn down, or log-file path mismatch.
**Context missing:** No exit reason, no crash signal, no final state.

---

## Top 5 Most Common Error Patterns

| Rank | Pattern | Count | Impact |
|---|---|---|---|
| 1 | **PROMPT_STUCK false positives** | 5 events across 3 panes | Noise in anomaly tracking; could trigger spurious interventions |
| 2 | **status=error despite success** | 2/2 result files (100%) | Manager sees workers as errored when they succeeded — corrupts task tracking |
| 3 | **manager hook=BUSY overrides scrape=IDLE** | 4/13 W1 cycles (31%) | Frequent; may cause watchdog to skip real stuck detection |
| 4 | **pane_id "unknown" in results** | 2/2 result files (100%) | Prevents result correlation back to specific pane instances |
| 5 | **Watchdog log stall (t3-wd.log)** | 1 window | Silent failure — W3 team health is invisible |

---

## What's Missing From Current Logs

### Critical gaps:
1. **Hook blocking events not logged anywhere.** `on-pre-tool-use.sh` blocks tools but there is no `BLOCKED` entry in any log file. When a worker has a tool denied, there's no record of what tool, what hook rule triggered, or which worker.

2. **Error cause for `status=error`.** The stop-results hook writes `status=error` but the log only says "wrote result" — no context about what set the error status (which condition, which variable, what the exit was).

3. **Empty SNIPPET in anomaly events.** `SNIPPET=|||` provides no signal. The watchdog detected stuck panes but couldn't (or didn't) capture what was actually on screen. This makes it impossible to distinguish real stuck vs. fast-finishing.

4. **No hook execution timing.** Hooks run synchronously but there's no log of how long each hook took. Slow hooks (especially `watchdog-scan.sh`) could cause cascading delays with no visibility.

5. **No worker stdout/stderr capture.** Pane logs (`1.1.log`, etc.) only record watchdog-observed state. The actual Claude output, tool call details, and any stderr from hook scripts are not persisted anywhere outside the result JSON `last_output` field (which is only the last message).

6. **W3 (freelancer window) health is unobservable.** Only 3 log entries; no cycle completion data, no pane states, no end-of-cycle summaries.

7. **pane_id resolution context missing.** When `pane_id` resolution fails, there's no logged reason — was tmux unavailable? Was `$TMUX` unset? Knowing why would allow fixing it.

8. **No cross-session error aggregation.** Each session starts fresh logs. No historical baseline for "how often do PROMPT_STUCK anomalies normally fire" — makes it hard to distinguish a regression from normal noise.
