# Validation Audit Report

**Date:** 2026-03-23
**Worker:** 5 (validation_0323)
**Branch:** doey/rd-0323-0050

---

## 1. Syntax Checks (`bash -n`)

All 17 scripts pass syntax validation with no errors.

| Category | Files | Result |
|----------|-------|--------|
| Shell scripts (`shell/*.sh`) | 5 | ALL PASS |
| Hook scripts (`.claude/hooks/*.sh`) | 12 | ALL PASS |

**Syntax check total: 17/17 PASS**

---

## 2. Agent Frontmatter Validation

All 4 agent files have valid frontmatter with required fields (name, model, description).

| Agent | name | model | description | Result |
|-------|------|-------|-------------|--------|
| `agents/doey-manager.md` | doey-manager | opus | present | PASS |
| `agents/doey-session-manager.md` | doey-session-manager | opus | present | PASS |
| `agents/doey-watchdog.md` | doey-watchdog | haiku | present | PASS |
| `agents/test-driver.md` | test-driver | opus | present | PASS |

**Agent frontmatter total: 4/4 PASS**

---

## 3. Skill Frontmatter Validation

All 23 skill directories have valid SKILL.md files with required fields (name, description).

| Skill | name | description | Result |
|-------|------|-------------|--------|
| `doey-add-window` | present | present | PASS |
| `doey-broadcast` | present | present | PASS |
| `doey-clear` | present | present | PASS |
| `doey-delegate` | present | present | PASS |
| `doey-dispatch` | present | present | PASS |
| `doey-kill-all-sessions` | present | present | PASS |
| `doey-kill-session` | present | present | PASS |
| `doey-kill-window` | present | present | PASS |
| `doey-list-windows` | present | present | PASS |
| `doey-monitor` | present | present | PASS |
| `doey-purge` | present | present | PASS |
| `doey-rd-team` | present | present | PASS |
| `doey-reinstall` | present | present | PASS |
| `doey-reload` | present | present | PASS |
| `doey-repair` | present | present | PASS |
| `doey-research` | present | present | PASS |
| `doey-reserve` | present | present | PASS |
| `doey-simplify-everything` | present | present | PASS |
| `doey-status` | present | present | PASS |
| `doey-stop` | present | present | PASS |
| `doey-watchdog-compact` | present | present | PASS |
| `doey-worktree` | present | present | PASS |
| `unknown-task` | present | present | PASS |

**Skill frontmatter total: 23/23 PASS**

[INFO] file:.claude/skills/SKILL.md — Stray untracked SKILL.md at skills root (duplicate of doey-worktree). Should be deleted or gitignored.

---

## 4. Test Results

| Test | Result | Notes |
|------|--------|-------|
| `tests/test-bash-compat.sh` | **PASS** | 20 files, 0 violations |
| `tests/pane-state-check.sh` | SKIP | No pane state files (expected in worktree) |
| `tests/watchdog-heartbeat-check.sh` | SKIP | No heartbeat files (expected in worktree) |

---

## 5. Shellcheck Analysis

Ran with `shellcheck -s bash -S warning`.

### shell/doey.sh (6 warnings)

[LOW] shell/doey.sh:31 — SC2034: `INFO` color variable appears unused. Used via string interpolation patterns. False positive.

[LOW] shell/doey.sh:323 — SC1090: Can't follow non-constant source. Expected — dynamic `session.env` path.

[LOW] shell/doey.sh:888 — SC2088: Tilde in quotes won't expand. Intentional display string, not path. Not a bug.

[LOW] shell/doey.sh:1119 — SC2064: Trap uses double quotes causing early expansion of `$list_file`. Variable is assigned before trap, so early expansion is actually correct. False positive.

[LOW] shell/doey.sh:1793-1813 — SC2088: Tilde in quotes (3 instances). Display strings only. Not bugs.

[LOW] shell/doey.sh:2783 — SC2155: Declare and assign separately. Minor — `date +%s` won't fail in practice.

### shell/info-panel.sh (4 warnings — all false positives)

[INFO] shell/info-panel.sh:182 — SC2034: CHAR_R0-R5 appear unused. Set in case branches, used in rendering loop.

[INFO] shell/info-panel.sh:309 — SC2034: HR appears unused. Set for later rendering use.

[INFO] shell/info-panel.sh:367-393 — SC2154: Variables `_tw`, `_twc`, `_tb`, `_tidle`, `left_line` referenced but not assigned. **All assigned via `eval`**. False positives.

### .claude/hooks/common.sh (3 warnings — all false positives)

[INFO] .claude/hooks/common.sh:16,20,109 — SC2034: `SESSION_NAME`, `NOW`, `NL` appear unused. These are sourced by other hooks. False positives.

### .claude/hooks/watchdog-scan.sh (8 warnings — all false positives)

[INFO] .claude/hooks/watchdog-scan.sh:200 — SC2034: `pane_output` reassigned in fallback. Used in subsequent code.

[INFO] .claude/hooks/watchdog-scan.sh:225,382-383 — SC2154: `_prev`, `_prev_raw` referenced but not assigned. **Assigned via `eval`**. False positives.

[INFO] .claude/hooks/watchdog-scan.sh:404,409 — SC2154: `_st`, `_dur` referenced but not assigned. **Assigned via `eval`**. False positives.

[INFO] .claude/hooks/watchdog-scan.sh:496 — SC2154: `_sn_title`, `_sn_dur`, `_sn_tool`, `_sn_prev` referenced but not assigned. **All assigned via `eval`**. False positives.

### Shebang Inconsistency

[LOW] shell/info-panel.sh — Uses `#!/bin/bash` while all 16 other scripts use `#!/usr/bin/env bash`. Functional but inconsistent.

---

## 6. Summary

| Category | Checks | Pass | Fail |
|----------|--------|------|------|
| Syntax (`bash -n`) | 17 | 17 | 0 |
| Agent frontmatter | 4 | 4 | 0 |
| Skill frontmatter | 23 | 23 | 0 |
| Bash 3.2 compat test | 1 | 1 | 0 |
| **Total** | **45** | **45** | **0** |

### Findings by Severity

| Severity | Count | Details |
|----------|-------|---------|
| CRITICAL | 0 | — |
| HIGH | 0 | — |
| MEDIUM | 0 | — |
| LOW | 7 | Shellcheck style warnings (all non-functional) + shebang inconsistency |
| INFO | 16 | Shellcheck false positives from eval-based dynamic variables + 1 stray file |

### Overall Assessment

**The codebase is clean.** No syntax errors, no missing frontmatter fields, bash 3.2 compatibility tests pass (0 violations across 20 files), and all shellcheck findings are either false positives (dynamic `eval` variables, sourced constants) or cosmetic style preferences. No functional issues found.

### Actionable Items (optional cleanup)

1. [LOW] Delete stray `.claude/skills/SKILL.md` (untracked, duplicate of doey-worktree)
2. [LOW] Consider standardizing `shell/info-panel.sh` shebang to `#!/usr/bin/env bash`
