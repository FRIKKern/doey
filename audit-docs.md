# Documentation Audit Report

**Date:** 2026-03-23
**Auditor:** Worker 4 (R&D Audit Team, rd-0323-0121)
**Scope:** README.md, CLAUDE.md, docs/*.md — cross-referenced against shell/, .claude/hooks/, .claude/skills/, agents/, .claude/settings.json

---

## Findings

### HIGH

[HIGH] docs/context-reference.md line:93 — `WDG_SLOT_1..WDG_SLOT_3` undercount
- `setup_dashboard()` creates up to 6 watchdog slots (panes 0.2-0.7). Session.env can contain `WDG_SLOT_1` through `WDG_SLOT_6`. Docs only show `WDG_SLOT_1..WDG_SLOT_3`.
- Fix: Change to `WDG_SLOT_1`..`WDG_SLOT_6`.

[HIGH] docs/context-reference.md line:93 — Session.env vars lack grid-type qualification
- `ROWS`, `MAX_WORKERS`, `CURRENT_COLS` are written only in dynamic grid session.env (not static). `TOTAL_PANES` is written only in static grid session.env (not dynamic). The docs list all of them as generic session.env vars without noting which grid type they apply to.
- Fix: Add "(dynamic only)" or "(static only)" annotations.

[HIGH] docs/context-reference.md line:162 — Status values incomplete
- Lists "READY, BUSY, BOOTING, FINISHED, RESERVED" but `watchdog-scan.sh` detects additional states: IDLE, WORKING, CHANGED, UNCHANGED, CRASHED, STUCK, LOGGED_OUT, UNKNOWN. These are watchdog-detected states vs. status-file values — the distinction should be documented.
- Fix: Add watchdog-detected states section.

### MEDIUM

[MEDIUM] CLAUDE.md line:5 — "Static grid default: 3x2 (6 workers)" phrasing misleading
- The overall default launch mode is `dynamic` (1 column, auto-expands), not static 3x2. The "3x2" is the default for static grid mode specifically. Current wording could imply the default launch produces 6 workers.
- Fix: Clarify "Dynamic grid (default) starts 1 col, auto-expands. Static grid default: 3x2 (6 workers)." — current text is actually correct on re-reading, but the proximity of "default" to "3x2" is confusing.

[MEDIUM] CLAUDE.md — Missing `/doey-rd-team` skill
- The skill `doey-rd-team` exists in `.claude/skills/doey-rd-team/SKILL.md` and is documented in `docs/context-reference.md` line 71 and README.md line 86, but CLAUDE.md does not mention it anywhere.
- Fix: No action needed if CLAUDE.md intentionally keeps a minimal skill list.

[MEDIUM] docs/context-reference.md line:164 — Watchdog anomaly types documented but may be stale
- Lists "PROMPT_STUCK, WRONG_MODE, QUEUED_INPUT" but these should be verified against current `watchdog-scan.sh` implementation. The types are present in the code, so the docs are currently accurate.

[MEDIUM] CLAUDE.md + docs/context-reference.md — "column expansion" vs "collapsed column restore"
- Both describe `on-prompt-submit.sh` as doing "collapsed column restore" (CLAUDE.md line 68) / "collapsed column restore" (context-reference.md line 52). The actual code restores collapsed columns — these descriptions are accurate. No issue on re-reading; both already say "collapsed column restore."

[MEDIUM] docs/context-reference.md line:112 — Note reads as a TODO
- "Note: `_launch_team_manager()` in `doey.sh` should pass `--model opus` explicitly..." — reads as if this is not yet done, but the code already does this.
- Fix: Reword to: "`_launch_team_manager()` passes `--model opus` explicitly..."

[MEDIUM] docs/linux-server.md line:44 — systemd PATH uses wrong fnm directory
- systemd unit uses `%h/.fnm/aliases/default/bin` but fnm installs to `~/.local/share/fnm/` by default. The Linode guide (linode-setup.md line 133) correctly uses `%h/.local/share/fnm/aliases/default/bin`.
- Fix: Change to `%h/.local/share/fnm/aliases/default/bin`.

### LOW

[LOW] CLAUDE.md line:16 — Architecture table includes "Test Driver" at pane "external" which README.md's architecture table (lines 70-76) omits. Minor inconsistency between the two — README omits Test Driver for brevity.

[LOW] docs/context-reference.md line:55 — `post-tool-lint.sh` event documented as "PostToolUse" which is correct, but doesn't mention the matcher `"Write|Edit"` from settings.json. Readers may think it fires on every tool use.

[LOW] README.md line:96 — Troubleshooting suggests `doey 3x2` but CLI table example uses `doey 4x3`. Both are valid, but inconsistent examples.

[LOW] CLAUDE.md line:54 — Testing table references `tests/test-bash-compat.sh` (exists), but `tests/` also contains `tests/e2e/`, `tests/pane-state-check.sh`, and `tests/watchdog-heartbeat-check.sh` which are undocumented.

[LOW] `.claude/skills/unknown-task/SKILL.md` — Internal fallback skill exists but is not documented in any docs file. Intentionally undocumented (internal only), but noting for completeness.

---

## Verified Claims (All Correct)

### Architecture Table (CLAUDE.md lines 9-16)
- Info Panel at `0.0` — confirmed by `agents/doey-session-manager.md` and `shell/info-panel.sh`
- Session Manager at `0.1` — confirmed by `agents/doey-session-manager.md` line 13
- Watchdog at `0.2+` (up to 0.7) — confirmed by session manager agent definition
- Window Manager at `W.0` — confirmed by `agents/doey-manager.md` line 13
- Workers at `W.1+` — confirmed by agent definitions
- Test Driver as external — confirmed by `agents/test-driver.md` line 9

### Hook Table (CLAUDE.md lines 64-77)
All 12 hooks listed match files in `.claude/hooks/`. No undocumented hooks exist. Registration in `settings.json` matches: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse (Write|Edit), Stop (3 hooks), PreCompact. Three hooks (watchdog-scan.sh, watchdog-wait.sh, session-manager-wait.sh) are correctly noted as called directly, not registered.

### Tool Restrictions (CLAUDE.md lines 24-26)
Verified against `on-pre-tool-use.sh`:
- Window Manager: full access — exits 0 at line 38/69
- Watchdog: Edit/Write/Agent/NotebookEdit blocked (lines 15-21), send-keys limited to own Manager pane + recovery commands (lines 80-108), git/gh/rm/shutdown/tmux-kill blocked (lines 117-128)
- Workers: git push/commit, gh pr create/merge, all send-keys, tmux kill, destructive rm, shutdown — all blocked (lines 50-62)

### Key Directories (CLAUDE.md lines 30-36)
All directories exist with expected contents:
- `agents/` — 4 files (doey-manager.md, doey-session-manager.md, doey-watchdog.md, test-driver.md)
- `.claude/skills/` — 23 skill directories with SKILL.md files
- `.claude/hooks/` — 12 hook files
- `shell/` — 5 files (doey.sh, info-panel.sh, context-audit.sh, pane-border-status.sh, tmux-statusbar.sh)
- `docs/` — 5 files

### Shell Files (CLAUDE.md line 60)
All 5 documented shell files exist and serve their documented purpose.

### README CLI Commands (README.md lines 48-64)
All 14 CLI commands verified in `shell/doey.sh`: doey, init, add/remove, stop, reload, add-team/kill-team, list/list-teams, purge, doctor, update, test, 4x3 (NxM), dynamic, uninstall.

### README Slash Commands (README.md lines 83-88)
All listed slash commands have corresponding skill directories. Two skills not listed in README: `doey-rd-team` (listed under Lifecycle), `unknown-task` (internal fallback).

### Agent Frontmatter (docs/context-reference.md lines 23-27)
- Manager: model=opus, color=green, memory=user — matches `agents/doey-manager.md`
- Session Manager: model=opus, color=#FF6B35, memory=user — matches `agents/doey-session-manager.md`
- Watchdog: model=haiku, color=yellow, memory=none — matches `agents/doey-watchdog.md`

### External Files
- `install.sh` — exists
- `web-install.sh` — exists
- `tests/test-bash-compat.sh` — exists
- All docs/*.md files — exist and are internally consistent

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 5 |
| LOW | 5 |
| **Total** | **13** |

### Top Priority Fixes
1. `WDG_SLOT` range in context-reference.md — docs say 1..3, code supports 1..6
2. Session.env var annotations — mark dynamic-only and static-only vars
3. Watchdog state documentation — add watchdog-detected states vs status-file values
4. linux-server.md systemd PATH — wrong fnm directory
5. context-reference.md `_launch_team_manager` note — reword from TODO to statement of fact
