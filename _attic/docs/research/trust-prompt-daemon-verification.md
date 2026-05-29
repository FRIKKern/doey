# Trust-Prompt Daemon — Verification Report (Task 596, Subtask 5)

**Verifier:** Worker 2 (d-t2-w2), fresh-eyes review of subtask 4.
**Date:** 2026-04-17.
**Scope:** end-to-end validation of `shell/trust-watcher.sh` + integrations.

## Final Verdict: **NEEDS-FIXES**

Implementation correctness (script + launch integration + smoke) is solid. Two
unrelated out-of-scope changes slipped in, and one coverage gap exists for
static-grid launches. Must be cleaned up before ship.

---

## V1 — Static Review

### V1a. `shell/trust-watcher.sh` — **PASS**

| Check | Result | Note |
|---|---|---|
| `set -euo pipefail` | PASS | line 11 |
| Bash 3.2 compatible (no assoc arrays / mapfile / %T / BASH_REMATCH capture / `\|&` / `&>>` / coproc) | PASS | `shopt -s nullglob` is fine on 3.2 |
| Signature is fixed string `Quick safety check: Is this a project you created` via `grep -qF` | PASS | line 40 + 124 |
| Sends single Enter (`C-m`) on detection | PASS | line 126 (with 0.5s re-check + re-send if dialog persists) |
| Per-pane TTL + `.trust_done` marker prevents repeated sends | PASS | lines 99-100, 111-121, 135 |
| Exits when session or runtime dir is gone | PASS | lines 87-94 |
| TERM/INT trap | PASS | line 84 |

### V1b. `shell/doey-session.sh` integration — **PASS with 1 issue + 1 SCOPE CREEP**

| Check | Result | Note |
|---|---|---|
| Fork follows router/daemon pattern | PASS | lines 1305-1319 mirror the daemon block above |
| `trust-watcher.pid` written | PASS | line 1318 |
| Cleanup in `_kill_doey_session` | PASS | lines 397-401 |
| Cleanup in `_cleanup_old_session` | PASS | lines 831-835 |
| Fork AFTER `session.env`, BEFORE `setup_dashboard` | PASS | in `launch_session_dynamic` |
| No hook or claude-invocation strings altered by this subtask | PASS | (separate unrelated `.claude/hooks/on-session-start.sh` diff exists in working tree — appears to come from a different parallel task, not subtask 4) |
| **Coverage in all launch paths** | **FAIL** | trust-watcher fork is only in `launch_session_dynamic` (line 1302). `_launch_session_core` (line 605), which serves `launch_session` / static-grid paths (e.g. `doey 2x2`), was NOT modified. Default grid is `dynamic`, so fresh-install `doey` is covered — but any user-passed static grid leaves the dialog un-handled. |
| **SCOPE CREEP** | **FAIL** | diff adds a new `_doey_preflight_agents()` function and a call site in `_check_prereqs` (lines 1873-1905). Completely unrelated to trust-watcher. Subtask 4 claimed "No spec deviations" — this IS a deviation. |

### V1c. `install.sh` integration — **PASS on the required change; FAIL on a scope-creep change**

| Check | Result | Note |
|---|---|---|
| `trust-watcher.sh` added to `~/.local/bin/` shell install loop | PASS | line 425 appended to the for-loop |
| Only that one line added, no other behavior changed | **FAIL** | lines 340-341 also convert `bash expand-templates.sh >/dev/null 2>&1 \|\| true` into `>/dev/null \|\| die "Template expansion failed" ...`. This silently-tolerated step is now a hard-fail with a user-visible error path — an install behavior change out of scope for this subtask. |

### V1d. `docs/research/trust-prompt-daemon.md` — **PASS**

296-line consolidated report. Contains TL;DR, signature analysis (R1), pane
launch sites (R2), race-window analysis, lifecycle, architecture diagram,
ranked recommendations, and sources. Merges the two prior exploration reports
rather than re-researching. Good.

---

## V2 — Syntax / Compat

```
$ bash -n shell/trust-watcher.sh   → OK
$ bash -n shell/doey-session.sh    → OK
$ bash -n install.sh               → OK
$ bash tests/test-bash-compat.sh   → === Bash 3.2 Compat: 104 files, 0 violations ===  PASS
```

**V2: PASS**

---

## V3 — Signature Smoke (POS / NEG)

```
printf '…Quick safety check: Is this a project you created…' | grep -qF '…'  → POS ok
printf '│ Welcome back Frikk! │…' | grep -qF '…'                              → NEG ok
```

**V3: PASS**

---

## V4 — Daemon End-to-End (shimmed tmux on `-L trust-verify` socket)

Created scratch tmux server, wrote a `worker.role`, seeded trust-dialog text in
the pane, ran `trust-watcher.sh` with a PATH shim routing `tmux` → `tmux -L
trust-verify`, POLL_INTERVAL=1, PANE_TTL=30, timeout 8s.

Result (log tail):
```
[2026-04-17 21:34:27] trust-watcher starting (session=trust-verify runtime=/tmp/doey-trust-verify-1464989 pid=1465590)
[2026-04-17 21:34:27] trust dialog detected on trust-verify:0.0 — sending Enter
[2026-04-17 21:34:27] pane trust-verify:0.0: dialog still present, re-sending Enter
```

Status dir after run:
```
trust_verify_0_0.role
trust_verify_0_0.trust_done        ← created
trust_verify_0_0.trust_first_seen  ← created
```

Watcher exited cleanly via timeout; session was still alive (its own
has-session check would have exited it if killed). Enter was sent. Dialog-still-
present re-send fired (because our scratch pane was a shell, not Claude, so
the text stayed visible after Enter — this is the intended defensive behavior).

**V4: PASS**

---

## V5 — False-Positive Check

```
printf 'Worker: you can trust this approach…Analyzing folder structure.'
  | grep -qF 'Quick safety check: Is this a project you created'
  → NEG ok — safely distinct
```

Signature has zero false-positive risk against "trust" / "folder" chatter.

**V5: PASS**

---

## V6 — `~/.claude.json` Untouched

```
$ grep 'claude\.json' shell/trust-watcher.sh shell/doey-session.sh → (empty)
$ git diff install.sh | grep 'claude\.json'                       → (empty)
```

No references in the modified files. The implementation achieves the success
criterion "zero changes to `~/.claude.json`" by construction.

**V6: PASS**

---

## V7 — Install Path Impact

```diff
-  bash "$SCRIPT_DIR/shell/expand-templates.sh" >/dev/null 2>&1 || true
+  bash "$SCRIPT_DIR/shell/expand-templates.sh" >/dev/null || die "Template expansion failed" \
+    "Run: bash $SCRIPT_DIR/shell/expand-templates.sh"
…
-  for s in tmux-statusbar.sh tmux-theme.sh pane-border-status.sh info-panel.sh settings-panel.sh tmux-settings-btn.sh doey-statusline.sh doey-remote-provision.sh; do
+  for s in tmux-statusbar.sh … doey-remote-provision.sh trust-watcher.sh; do
```

- 2nd hunk: expected, in-scope.
- 1st hunk: **out of scope**. Subtask 4 brief said "only a single line/entry
  added — no other behavior changed." Turning a quiet template-expansion step
  into a hard-fail is a real behavior change and could break install for
  people whose templates fail silently today.

**V7: FAIL (scope creep)**

---

## V8 — Hook Modifications

```
$ git diff .claude/hooks/on-session-start.sh
+mkdir -p … "${RUNTIME_DIR}/ready"
+touch "${RUNTIME_DIR}/ready/pane_${WINDOW_INDEX}_${PANE_INDEX}"
```

This diff exists in the working tree but is unrelated to trust-watcher (it
adds a "ready marker" for `doey wait-for-ready`). It is almost certainly from
another parallel worker/task sharing this worktree, not subtask 4. **Not
attributed to this task**, but flagging because the environment was not clean
at verification time.

**V8: NOT-THIS-TASK (flagged for separation)**

---

## Issues to Fix (Subtask 4 Revision)

1. **Remove scope-creep preflight agents code from `shell/doey-session.sh`.**
   - Lines ~1873–1875 (`if ! _doey_preflight_agents; then missing=true; fi` in `_check_prereqs`).
   - Lines ~1878–1905 (`_doey_preflight_agents()` function definition).
   - This belongs in its own task — not bundled with trust-watcher.

2. **Revert the `install.sh` template-expansion failure-handling change.**
   - Lines 340–341. Restore to `bash "$SCRIPT_DIR/shell/expand-templates.sh" >/dev/null 2>&1 || true`.

3. **(Recommend) Cover static-grid launches.**
   - Replicate the trust-watcher fork block inside `_launch_session_core`
     (shell/doey-session.sh, just after the `doey-daemon` block around line
     679, before `write_team_env` / `setup_dashboard`).
   - Without this, success criterion #4 ("works with 2/4/8 worker grids") only
     holds when the user uses the default dynamic grid. Explicit `doey 4x2`
     etc. bypass the watcher.
   - Alternatively: factor the fork into a helper and call from both sites.

No changes required to `shell/trust-watcher.sh` itself — the script is clean.

---

## Verdict

**NEEDS-FIXES** — address items 1 and 2 (scope creep) and, preferably, item 3
(static-grid coverage). Trust-watcher script itself: ready.
