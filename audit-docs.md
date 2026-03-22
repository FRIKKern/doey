# Documentation Audit Report

**Date:** 2026-03-23
**Auditor:** Worker 4 (docs-audit_0323)
**Scope:** README.md, CLAUDE.md, docs/*.md — cross-referenced against shell/doey.sh, .claude/hooks/, agents/, .claude/skills/

---

## CLAUDE.md Findings

### [HIGH] CLAUDE.md:5 — "default 3 cols = 6 workers" is misleading
- **Evidence:** The default static grid is `3x2` (shell/doey.sh:2761), which means 3 columns × 2 rows = 6 workers. But the _default_ launch mode is `dynamic` (single column, auto-expands), not 3 cols. The claim "default 3 cols" only applies to the static grid default, not the overall default.
- **Suggested:** Clarify: "Static grid default 3x2 (6 workers). Dynamic grid (default mode) starts with 1 column, auto-expands."

### [HIGH] CLAUDE.md:60 — "shell/doey.sh (CLI launcher)" line count outdated
- **Evidence:** The R&D worker system prompt (outside this file) says "1455 lines" but actual line count is **3031 lines** — more than double.
- **Note:** CLAUDE.md itself doesn't state the line count, but the worker system prompt injected by doey does. This is a context/prompt issue, not a CLAUDE.md issue per se.

### [MEDIUM] CLAUDE.md:12 — Watchdog pane range "0.2-0.7" implies exactly 6 slots
- **Evidence:** `setup_dashboard()` (doey.sh:275-315) defaults to 6 slots (`num_slots="${4:-6}"`), but when launched with fewer teams (e.g., 1 team = 1 slot at 0.2), only 1 watchdog pane is created. The range "0.2-0.7" is the _maximum_, not the typical layout.
- **Suggested:** Change to "0.2+ (up to 0.7)" or "One per team, in Dashboard panes 0.2–0.7"

### [LOW] CLAUDE.md:43 — Missing `[[ =~` without capture groups
- Conventions say `[[ =~ capture groups` are forbidden but `[[ =~ ` itself (without captures) is allowed. This could be clearer — the phrasing "Forbidden: ... `[[ =~` capture groups" could be read as `[[ =~` is entirely forbidden.
- **Suggested:** Reword to: "`[[ =~ ]]` capture groups (named or \1-style)"

---

## context-reference.md Findings

### [HIGH] docs/context-reference.md:93 — `WDG_SLOT_1..WDG_SLOT_3` undercount
- **Evidence:** `setup_dashboard()` creates up to 6 watchdog slots (panes 0.2–0.7). The session.env can contain `WDG_SLOT_1` through `WDG_SLOT_6`. The docs say `WDG_SLOT_1..WDG_SLOT_3`.
- **Suggested:** Change to `WDG_SLOT_1`..`WDG_SLOT_6`

### [HIGH] docs/context-reference.md:93 — `ROWS` not in static grid session.env
- **Evidence:** The `ROWS` variable is only written in the dynamic session.env (doey.sh:2012), not in the static grid session.env (doey.sh:1259-1275). Similarly, `MAX_WORKERS` and `CURRENT_COLS` are dynamic-only. But context-reference.md lists them as generic session.env vars without noting this distinction.
- **Suggested:** Note which vars are dynamic-grid-only: `ROWS`, `MAX_WORKERS`, `CURRENT_COLS`

### [MEDIUM] docs/context-reference.md:93 — `TOTAL_PANES` missing from dynamic session.env
- **Evidence:** `TOTAL_PANES` is written in static session.env (doey.sh:1264) but NOT in dynamic session.env (doey.sh:2007-2024). The context-reference lists it as a session.env var without qualification.
- **Suggested:** Note `TOTAL_PANES` is static-grid-only.

### [MEDIUM] docs/context-reference.md:162 — Status values incomplete
- **Evidence:** `watchdog-scan.sh` detects states: IDLE, WORKING, CHANGED, UNCHANGED, CRASHED, STUCK, FINISHED, RESERVED, LOGGED_OUT, BOOTING, UNKNOWN (line 125). The docs only list "READY, BUSY, FINISHED, RESERVED" as status values. These are the _status file_ values vs the _watchdog-detected_ states — the distinction should be documented.
- **Suggested:** Add: "**Watchdog-detected states** (distinct from status file values): IDLE, WORKING, CHANGED, UNCHANGED, CRASHED, STUCK, FINISHED, RESERVED, LOGGED_OUT, BOOTING, UNKNOWN."

### [MEDIUM] docs/context-reference.md — Missing `/doey-rd-team` skill
- **Evidence:** `.claude/skills/doey-rd-team/` exists and is a valid skill. It's not listed under Manager or Session Manager skills in context-reference.md.
- **Suggested:** Add `/doey-rd-team` to the Manager or Session Manager skills list.

### [MEDIUM] docs/context-reference.md — Missing watchdog anomaly types
- **Evidence:** `watchdog-scan.sh` implements PROMPT_STUCK (line 262), WRONG_MODE (line 276), and QUEUED_INPUT (line 279) anomaly detection (added in commit 2abe471). These are not documented anywhere in context-reference.md.
- **Suggested:** Add an "Anomaly Detection" subsection under Watchdog behavior.

### [MEDIUM] docs/context-reference.md — Missing BOOTING watchdog state
- **Evidence:** `watchdog-scan.sh:68` detects BOOTING state, added in commit a07c78e. Not mentioned in context-reference.md.
- **Suggested:** Document BOOTING as a watchdog-detected state.

### [LOW] docs/context-reference.md:112 — Note about `_launch_team_manager()` passing `--model opus`
- **Evidence:** The note says "should pass `--model opus` explicitly" — the code already does this (doey.sh:2427). The note reads as a TODO but the implementation is correct. It should either be removed or reworded as a verification note.
- **Suggested:** Remove or reword to: "`_launch_team_manager()` passes `--model opus` explicitly to ensure the Manager always uses opus regardless of settings defaults."

---

## README.md Findings

### [MEDIUM] README.md:26 — "WATCHDOG monitors from Dashboard (window 0)" architecture diagram
- **Evidence:** The ASCII diagram shows "WATCHDOG monitors from Dashboard" at the bottom. This is correct but the diagram itself only shows a single team window layout. With the multi-team architecture, there's one Watchdog per team in the Dashboard — this nuance is lost.
- **Suggested:** Minor — consider noting "One Watchdog per team in Dashboard"

### [MEDIUM] README.md:62 — `doey dynamic` listed as CLI command
- **Evidence:** The command works (doey.sh:2903) but `doey dynamic` is the _default_ mode. The table doesn't indicate this. Meanwhile `doey 4x3` is listed for static grid but there's no indication that `doey` alone launches dynamic mode by default.
- **Suggested:** Add note: `doey` launches dynamic grid by default; `doey 4x3` overrides.

### [LOW] README.md:96 — Troubleshooting "Terminal too small" fix says `doey 3x2`
- **Evidence:** The fix suggests `doey 3x2` but the example in the CLI table is `doey 4x3`. Either works, but using a consistent example would be better.

---

## docs/linux-server.md Findings

### [LOW] docs/linux-server.md:44 — systemd `Environment=PATH` uses `.fnm/` not `.local/share/fnm/`
- **Evidence:** The PATH in the systemd unit uses `%h/.fnm/aliases/default/bin` but fnm installs to `~/.local/share/fnm/` (as shown in linode-setup.md:77-78 and the fnm installer default).
- **Suggested:** Change to `%h/.local/share/fnm/aliases/default/bin`

---

## docs/linode-setup.md Findings

### [LOW] docs/linode-setup.md — No issues found
- All commands reference correct paths and tools. The guide is comprehensive and internally consistent.

---

## docs/windows-wsl2.md Findings

### [LOW] docs/windows-wsl2.md — No issues found
- Brief and accurate. Links back to README correctly.

---

## docs/test-worktree.md Findings

### [LOW] docs/test-worktree.md — No issues found
- Test procedures reference correct runtime paths and commands. Internal consistency is good.

---

## Cross-Document Consistency

### [MEDIUM] CLAUDE.md vs context-reference.md — Hook table differences
- CLAUDE.md lists hooks with slightly different descriptions than context-reference.md. For example:
  - CLAUDE.md says `on-prompt-submit.sh`: "BUSY status, READY on /compact, column expansion"
  - context-reference.md says: "BUSY status; READY on `/compact`; column expansion"
  - Actual code (on-prompt-submit.sh:28-34): Expands _collapsed_ columns, doesn't add new columns. "Column expansion" is misleading — it's "collapsed column restore".
- **Suggested:** Both files should say "collapsed column restore" instead of "column expansion"

### [MEDIUM] Shell files not documented — pane-border-status.sh, tmux-statusbar.sh
- **Evidence:** `shell/` contains `pane-border-status.sh` and `tmux-statusbar.sh` which are not mentioned in CLAUDE.md's Important Files section or in context-reference.md.
- **Suggested:** Add to CLAUDE.md shell files list: `shell/pane-border-status.sh` (pane border formatting), `shell/tmux-statusbar.sh` (status bar rendering)

### [LOW] CLAUDE.md vs README.md — Skill lists
- README.md lists slash commands grouped by category. context-reference.md lists them grouped by role. Both are accurate and complete, with context-reference.md missing only `/doey-rd-team`.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 9 |
| LOW | 5 |
| **Total** | **17** |

### Top Priority Fixes
1. **`WDG_SLOT` range** — docs say 1..3, code supports 1..6
2. **Session.env vars** — `ROWS`, `MAX_WORKERS`, `CURRENT_COLS` are dynamic-only; `TOTAL_PANES` is static-only
3. **"Column expansion" mislabeled** — actually "collapsed column restore" in on-prompt-submit.sh
4. **Default grid mode** — clarify dynamic is default, not "3 cols = 6 workers"
5. **Watchdog states** — new anomaly detection (PROMPT_STUCK, WRONG_MODE, QUEUED_INPUT, BOOTING) undocumented
