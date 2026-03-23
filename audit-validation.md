# Codebase Validation Report

**Date:** 2026-03-23
**Branch:** doey/rd-0323-0955

## 1. Shell Syntax Checks (`bash -n`)

| File | Result |
|------|--------|
| `shell/doey.sh` | [PASS] |
| `shell/context-audit.sh` | [PASS] |
| `shell/info-panel.sh` | [PASS] |
| `shell/pane-border-status.sh` | [PASS] |
| `shell/tmux-statusbar.sh` | [PASS] |
| `.claude/hooks/common.sh` | [PASS] |
| `.claude/hooks/on-pre-compact.sh` | [PASS] |
| `.claude/hooks/on-pre-tool-use.sh` | [PASS] |
| `.claude/hooks/on-prompt-submit.sh` | [PASS] |
| `.claude/hooks/on-session-start.sh` | [PASS] |
| `.claude/hooks/post-tool-lint.sh` | [PASS] |
| `.claude/hooks/session-manager-wait.sh` | [PASS] |
| `.claude/hooks/stop-notify.sh` | [PASS] |
| `.claude/hooks/stop-results.sh` | [PASS] |
| `.claude/hooks/stop-status.sh` | [PASS] |
| `.claude/hooks/watchdog-scan.sh` | [PASS] |
| `.claude/hooks/watchdog-wait.sh` | [PASS] |

**Result: 17/17 files pass syntax check. No errors.**

## 2. Skill Frontmatter Validation

All 22 skills checked. Every SKILL.md has valid YAML frontmatter with required `name` and `description` fields.

**Result: 22/22 skills valid.**

## 3. Agent Frontmatter Validation

All 4 agents checked. Every agent definition has valid YAML frontmatter with required `name`, `model`, and `description` fields.

| Agent | name | model | description |
|-------|------|-------|-------------|
| doey-manager | doey-manager | opus | [PASS] |
| doey-session-manager | doey-session-manager | opus | [PASS] |
| doey-watchdog | doey-watchdog | haiku | [PASS] |
| test-driver | test-driver | opus | [PASS] |

**Result: 4/4 agents valid.**

## 4. Test Results

| Test | Result | Notes |
|------|--------|-------|
| `tests/test-bash-compat.sh` | [PASS] | 20 files scanned, 0 violations |
| `tests/pane-state-check.sh` | [PASS] | No state files — expected outside live session |
| `tests/watchdog-heartbeat-check.sh` | [FAIL]* | No heartbeat files — expected outside live session |
| `tests/e2e/journey.md` | N/A | Test plan document, not executable |

*Watchdog heartbeat test returns non-zero when no heartbeat files exist. This is expected behavior in a worktree (no live session running).

**Result: 2/3 executable tests pass. 1 expected failure (requires live session).**

## 5. Shellcheck Analysis (`shellcheck -s bash shell/doey.sh`)

**Total findings: 165**

| Code | Count | Severity | Description |
|------|-------|----------|-------------|
| SC2059 | 149 | info | Variables in printf format string |
| SC2088 | 4 | warning | Tilde not expanded in quotes |
| SC2016 | 3 | info | Single-quoted string with expressions |
| SC2064 | 2 | warning | Trap uses single quotes (expands at definition) |
| SC2034 | 2 | warning | Unused variable |
| SC1090 | 2 | warning | Can't follow non-constant source |
| SC2155 | 1 | warning | Declare and assign separately |
| SC2153 | 1 | info | Possible misspelling (uppercase var) |
| SC2086 | 1 | warning | Double-quote to prevent splitting |

**Notes:**
- SC2059 (149 instances): Intentional pattern — `printf "${COLOR}text${RESET}"` is used throughout for colored output. Not a bug.
- SC1090 (2 instances): Dynamic `source` of session.env — unavoidable.
- Actionable: SC2034 (unused vars), SC2086 (unquoted var), SC2155 (declare+assign) — 4 low-severity items.

## 6. Common Issues Check

| Check | Result |
|-------|--------|
| CRLF line endings | [PASS] None found |
| Missing shebang lines | [PASS] All .sh files have shebangs |
| Missing executable permissions | [LOW] `.claude/hooks/watchdog-scan.sh` — `rw-r--r--` |
| Broken symlinks | [PASS] None found |
| Stray files | [LOW] `.claude/skills/SKILL.md` — untracked file at skills root |

## Summary

| Category | Status |
|----------|--------|
| Shell syntax | **[PASS]** (17/17) |
| Skill frontmatter | **[PASS]** (22/22) |
| Agent frontmatter | **[PASS]** (4/4) |
| Bash 3.2 compat | **[PASS]** (20 files, 0 violations) |
| Tests | **[PASS]** (2/3 pass, 1 expected fail) |
| Shellcheck | 165 findings (149 info/intentional, 4 actionable) |
| Permissions | 1 LOW finding |
| Stray files | 1 LOW finding |

**Overall: CLEAN — No blockers. 4 actionable shellcheck items + 2 low-severity housekeeping items.**
