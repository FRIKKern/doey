# W5 Audit: Stop Hooks — Error Paths and Silent Failures

**Files:** `stop-status.sh`, `stop-results.sh`, `stop-notify.sh`
**Date:** 2026-03-24

---

## 1. stop-status.sh

**Sources common.sh:** YES

### Error Paths

#### BLOCK-SS1 — Research report enforcement (lines 8–14)
- Worker has research task but no report → exit 2 (block)
- Context: PANE_SAFE, RUNTIME_DIR, REPORT_FILE path

#### SILENT-SS1 — write_pane_status failure (lines 22, 26)
- No error check on atomic write — disk full/permissions → silently wrong status

#### SILENT-SS2 — DOEY_PANE_ID missing (line 25)
- Dual-write skipped if unset — only old-style PANE_SAFE file written, no warning

---

## 2. stop-results.sh

### Error Paths

#### CRITICAL-SR1 — False "error" status (lines 54–58)
- Pattern: `*[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*`
- False positives: "0 errors found", "error handling improved", "ErrorBoundary"
- W6 live logs confirm: 100% of result files showed status=error despite success
- Once set, never reset

#### SILENT-SR1 — tmux capture failure (line 16)
- `|| OUTPUT=""` — result gets empty last_output, no indication of failure

#### SILENT-SR2 — git diff timeout/failure (lines 22–35)
- Both paths swallow errors → files_changed: []

#### SILENT-SR3 — mktemp failure (lines 70–73)
- Falls back to non-atomic write; logs to doey-warnings.log (never monitored)

#### SILENT-SR4 — JSON encoding triple-fallback (lines 64–66)
- jq → python3 → '""'; if all fail, output lost

#### SILENT-SR5 — Completion event write failure (lines 93–99)
- No error check on cat/mv — watchdog never sees completion

---

## 3. stop-notify.sh

### Error Paths

#### SILENT-SN1 — Target pane gone (lines 68, 76, 93)
- `tmux display-message ... || exit 0` — silent exit, no log, notification vanishes

#### SILENT-SN2 — Message delivery failure chain (lines 43–44)
- _send_message_file fails → send_to_pane fallback → if both fail, silent loss

#### SILENT-SN3 — parse_field empty (lines 62, 105)
- Worker: MSG has no summary but delivers. SM: exits 0 silently, no desktop notification

#### SILENT-SN4 — send_notification failure (line 109)
- osascript/notify-send failure undetected; 60s cooldown can silently drop

#### SILENT-SN5 — _read_team_key failure (lines 49, 66, 74)
- Returns empty → reasonable defaults, but no logging of lookup failure

---

## Summary

| ID | Hook | Severity | Issue |
|---|---|---|---|
| CRITICAL-SR1 | stop-results | **HIGH** | False "error" from naive string match — 100% false positive in live logs |
| SILENT-SN1 | stop-notify | **HIGH** | Notifications silently dropped when target gone |
| SILENT-SR1 | stop-results | MEDIUM | tmux capture failure → empty output |
| SILENT-SN2 | stop-notify | MEDIUM | Delivery failure chain — both paths fail silently |
| SILENT-SR5 | stop-results | MEDIUM | Completion event lost → watchdog blind |
| SILENT-SS1 | stop-status | LOW | Status write failure undetected |
| SILENT-SS2 | stop-status | LOW | Missing DOEY_PANE_ID → no dual-write |
| SILENT-SR2 | stop-results | LOW | Git diff failure swallowed |
| SILENT-SR4 | stop-results | LOW | JSON encoding failure → empty output |
| SILENT-SN4 | stop-notify | LOW | Desktop notification failure undetected |
