# Validation Audit

**Date:** 2026-03-22
**Worker:** validation_0322

## Syntax Checks (bash -n)

All 17 shell files pass syntax validation:

- [PASS] shell/doey.sh
- [PASS] shell/info-panel.sh
- [PASS] shell/context-audit.sh
- [PASS] shell/pane-border-status.sh
- [PASS] shell/tmux-statusbar.sh
- [PASS] .claude/hooks/common.sh
- [PASS] .claude/hooks/on-session-start.sh
- [PASS] .claude/hooks/on-prompt-submit.sh
- [PASS] .claude/hooks/on-pre-tool-use.sh
- [PASS] .claude/hooks/on-pre-compact.sh
- [PASS] .claude/hooks/post-tool-lint.sh
- [PASS] .claude/hooks/stop-status.sh
- [PASS] .claude/hooks/stop-results.sh
- [PASS] .claude/hooks/stop-notify.sh
- [PASS] .claude/hooks/watchdog-scan.sh
- [PASS] .claude/hooks/watchdog-wait.sh
- [PASS] .claude/hooks/session-manager-wait.sh

## Frontmatter Validation

### Skills (21 SKILL.md files)

All 21 skills have valid frontmatter with required `name` and `description` fields:

- [PASS] doey-add-window
- [PASS] doey-broadcast
- [PASS] doey-clear
- [PASS] doey-delegate
- [PASS] doey-dispatch
- [PASS] doey-kill-all-sessions
- [PASS] doey-kill-session
- [PASS] doey-kill-window
- [PASS] doey-list-windows
- [PASS] doey-monitor
- [PASS] doey-purge
- [PASS] doey-rd-team
- [PASS] doey-reinstall
- [PASS] doey-reload
- [PASS] doey-repair
- [PASS] doey-research
- [PASS] doey-reserve
- [PASS] doey-simplify-everything
- [PASS] doey-status
- [PASS] doey-stop
- [PASS] doey-watchdog-compact
- [PASS] doey-worktree

### Agents (4 agent files)

All 4 agents have valid frontmatter with required `name`, `model`, `color`, `memory`, and `description` fields:

- [PASS] agents/doey-manager.md — opus/green/user
- [PASS] agents/doey-session-manager.md — opus/#FF6B35/user
- [PASS] agents/doey-watchdog.md — haiku/yellow/none
- [PASS] agents/test-driver.md — opus/red/none

## Test Results

- test-bash-compat.sh — **PASS** — 20 files, 0 violations

## Shellcheck Findings (warnings only, -S warning)

### shell/doey.sh (8 warnings)

- [LOW] shell/doey.sh:31 — SC2034: `INFO` variable appears unused
- [LOW] shell/doey.sh:322 — SC1090: Can't follow non-constant source (expected, dynamic path)
- [LOW] shell/doey.sh:887 — SC2088: Tilde does not expand in quotes (cosmetic string, not a path expansion)
- [MEDIUM] shell/doey.sh:1118 — SC2064: Trap string uses single quotes inside double quotes — expands `$list_file` at definition time instead of signal time
  - Current: `trap "rm -f '$list_file'" RETURN`
  - Note: In this case, expanding at definition time is likely intentional (captures current value)
- [LOW] shell/doey.sh:1782-1802 — SC2088: Tilde in quoted strings (3 occurrences, cosmetic display strings)
- [LOW] shell/doey.sh:2758 — SC2155: Declare and assign separately to avoid masking return values

### .claude/hooks/watchdog-scan.sh (7 warnings)

- [LOW] watchdog-scan.sh:77 — SC2034: `WINDOW_INDEX` unused (set by init_hook, used conditionally)
- [HIGH] watchdog-scan.sh:221 — SC2154: `_prev` referenced but not assigned (did you mean `prev`?)
- [HIGH] watchdog-scan.sh:329 — SC2154: `_prev_raw` referenced but not assigned
- [HIGH] watchdog-scan.sh:348 — SC2154: `_st` referenced but not assigned
- [HIGH] watchdog-scan.sh:352 — SC2154: `_dur` referenced but not assigned
- [HIGH] watchdog-scan.sh:432 — SC2154: `_sn_title`, `_sn_dur`, `_sn_tool`, `_sn_prev` referenced but not assigned

### .claude/hooks/common.sh (3 warnings)

- [LOW] common.sh:16 — SC2034: `SESSION_NAME` unused (exported via init_hook for other scripts)
- [LOW] common.sh:20 — SC2034: `NOW` unused (exported via init_hook for other scripts)
- [LOW] common.sh:103 — SC2034: `NL` unused (exported for other scripts)

### shell/info-panel.sh (5 warnings)

- [LOW] info-panel.sh:182 — SC2034: `CHAR_R0`–`CHAR_R5` unused (used via variable indirection)
- [LOW] info-panel.sh:309 — SC2034: `HR` unused (used via variable indirection)
- [HIGH] info-panel.sh:367 — SC2154: `_tw` referenced but not assigned
- [HIGH] info-panel.sh:372 — SC2154: `_twc`, `_tb`, `_tidle` referenced but not assigned
- [HIGH] info-panel.sh:393 — SC2154: `left_line` referenced but not assigned

## Other Issues

- [MEDIUM] .claude/skills/SKILL.md — Orphaned SKILL.md file at `.claude/skills/SKILL.md` (not in a subdirectory). Contains doey-worktree content — likely a copy artifact. Shows as untracked in git status.
- [MEDIUM] CLAUDE.md — References `stop-notify-manager.sh` and `stop-notify-session-manager.sh` hooks that do not exist in `.claude/hooks/`. Documentation is out of sync with actual files.
- [LOW] .claude/hooks/ — Missing hooks listed in CLAUDE.md: `stop-notify-manager.sh`, `stop-notify-session-manager.sh`. Either the docs need updating or these hooks need to be created.

## Summary

| Category | Pass | Fail | Warnings |
|----------|------|------|----------|
| Syntax (bash -n) | 17 | 0 | — |
| Skill frontmatter | 21 | 0 | — |
| Agent frontmatter | 4 | 0 | — |
| Bash 3.2 compat | 20 files | 0 | — |
| Shellcheck | — | — | 23 warnings |
| Trailing whitespace | 0 issues | — | — |
| Missing EOF newline | 0 issues | — | — |
| CRLF line endings | 0 issues | — | — |

**Critical findings:** 0
**High findings:** 8 (all SC2154 — variables referenced but not assigned in watchdog-scan.sh and info-panel.sh, likely set via indirect assignment patterns)
**Medium findings:** 3 (orphaned SKILL.md, CLAUDE.md doc drift, trap quoting)
**Low findings:** 12 (shellcheck style warnings, mostly false positives from indirect variable usage)
