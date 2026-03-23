# Validation Audit Report
Date: 2026-03-23
Branch: doey/rd-0323-0932

## Summary

| Category | Checks | Pass | Fail | Warn |
|----------|--------|------|------|------|
| Shell syntax (shell/) | 5 | 5 | 0 | 0 |
| Shell syntax (hooks/) | 12 | 12 | 0 | 0 |
| Agent frontmatter | 4 | 4 | 0 | 0 |
| Skill frontmatter | 23 | 23 | 0 | 0 |
| Bash 3.2 compat test | 1 | 1 | 0 | 0 |
| tests/pane-state-check.sh | 1 | 1 | 0 | 0 |
| tests/watchdog-heartbeat-check.sh | 1 | 0 | 1 | 0 |
| Stray file (.claude/skills/SKILL.md) | 1 | — | — | 1 |

---

## Shell Syntax

### shell/*.sh

[PASS] syntax:shell/context-audit.sh — no errors
[PASS] syntax:shell/doey.sh — no errors
[PASS] syntax:shell/info-panel.sh — no errors
[PASS] syntax:shell/pane-border-status.sh — no errors
[PASS] syntax:shell/tmux-statusbar.sh — no errors

### .claude/hooks/*.sh

[PASS] syntax:hooks/common.sh — no errors
[PASS] syntax:hooks/on-pre-compact.sh — no errors
[PASS] syntax:hooks/on-pre-tool-use.sh — no errors
[PASS] syntax:hooks/on-prompt-submit.sh — no errors
[PASS] syntax:hooks/on-session-start.sh — no errors
[PASS] syntax:hooks/post-tool-lint.sh — no errors
[PASS] syntax:hooks/session-manager-wait.sh — no errors
[PASS] syntax:hooks/stop-notify.sh — no errors
[PASS] syntax:hooks/stop-results.sh — no errors
[PASS] syntax:hooks/stop-status.sh — no errors
[PASS] syntax:hooks/watchdog-scan.sh — no errors
[PASS] syntax:hooks/watchdog-wait.sh — no errors

---

## Agent Frontmatter (agents/*.md)

Required fields: `name`, `model`, `description`

[PASS] frontmatter:agents/doey-manager.md — name=doey-manager, model=opus, description=present
[PASS] frontmatter:agents/doey-session-manager.md — name=doey-session-manager, model=opus, description=present
[PASS] frontmatter:agents/doey-watchdog.md — name=doey-watchdog, model=haiku, description=present
[PASS] frontmatter:agents/test-driver.md — name=test-driver, model=opus, description=present

All agent model values are valid (opus/sonnet/haiku).

---

## Skill Frontmatter (.claude/skills/*/SKILL.md)

Required fields: `name`, `description`

[PASS] frontmatter:doey-add-window/SKILL.md
[PASS] frontmatter:doey-broadcast/SKILL.md
[PASS] frontmatter:doey-clear/SKILL.md
[PASS] frontmatter:doey-delegate/SKILL.md
[PASS] frontmatter:doey-dispatch/SKILL.md
[PASS] frontmatter:doey-kill-all-sessions/SKILL.md
[PASS] frontmatter:doey-kill-session/SKILL.md
[PASS] frontmatter:doey-kill-window/SKILL.md
[PASS] frontmatter:doey-list-windows/SKILL.md
[PASS] frontmatter:doey-monitor/SKILL.md
[PASS] frontmatter:doey-purge/SKILL.md
[PASS] frontmatter:doey-rd-team/SKILL.md
[PASS] frontmatter:doey-reinstall/SKILL.md
[PASS] frontmatter:doey-reload/SKILL.md
[PASS] frontmatter:doey-repair/SKILL.md
[PASS] frontmatter:doey-research/SKILL.md
[PASS] frontmatter:doey-reserve/SKILL.md
[PASS] frontmatter:doey-simplify-everything/SKILL.md
[PASS] frontmatter:doey-status/SKILL.md
[PASS] frontmatter:doey-stop/SKILL.md
[PASS] frontmatter:doey-watchdog-compact/SKILL.md
[PASS] frontmatter:doey-worktree/SKILL.md
[PASS] frontmatter:unknown-task/SKILL.md

---

## Tests

### tests/test-bash-compat.sh

[PASS] bash-compat — 20 files scanned, 0 violations found

Output:
```
=== Bash 3.2 Compat: 20 files, 0 violations ===
PASS
```

### tests/pane-state-check.sh

[PASS] pane-state-check — no runtime state files (expected in non-live environment), exits 0

Output:
```
No pane state files found in /tmp/doey/claude-code-tmux-team/status
```

### tests/watchdog-heartbeat-check.sh

[FAIL] watchdog-heartbeat-check — exits 1 when no heartbeat files present

Output:
```
WARNING: No heartbeat files in /tmp/doey/claude-code-tmux-team/status
EXIT: 1
```

Note: This failure is **environmental** (no live Doey session running), not a code defect. The script checks `/tmp/doey/claude-code-tmux-team/status` for watchdog heartbeat files, which only exist when a Doey session is active. The script intentionally exits 1 when none are found (`exit 1` on line 29). The script itself has valid syntax.

This is a design issue: `watchdog-heartbeat-check.sh` cannot distinguish between "no session running" and "watchdog crashed". In CI/offline contexts, it will always fail. Consider: exit 0 with a WARNING if no heartbeat dir exists, only exit 1 if stale heartbeats are detected.

---

## Stray File

[WARN] stray:.claude/skills/SKILL.md — untracked file at skills root (not inside a skill subdirectory)

This file is an exact duplicate of `.claude/skills/doey-worktree/SKILL.md`. It is untracked in git (shown in `git status` as `?? .claude/skills/SKILL.md`). It has valid frontmatter (`name: doey-worktree`, `description: Isolate a team window in a git worktree, or return it.`) but is misplaced.

Recommendation: Delete `.claude/skills/SKILL.md` — the canonical copy is at `.claude/skills/doey-worktree/SKILL.md`.

---

## Overall Result

**All mandatory checks PASS.** One test failure is environmental (requires live session), one stray file is an untracked duplicate.
