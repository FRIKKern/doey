# Audit Report: Agent Definitions & Skill Definitions

**Date:** 2026-03-23
**Auditor:** Worker 2 (agent-skill-audit_0323)
**Scope:** 4 agent definitions (`agents/*.md`), 23 skill definitions (22 `doey-*` + `unknown-task`), 1 stale top-level `SKILL.md`

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 5 |
| MEDIUM | 9 |
| LOW | 6 |
| INFO | 18 |

---

## CRITICAL

[CRITICAL] .claude/skills/SKILL.md — Top-level SKILL.md is an exact duplicate of doey-worktree/SKILL.md
  `diff` confirms zero differences (exit code 0). This file sits at `.claude/skills/SKILL.md` (outside any skill subdirectory) and could confuse skill resolution — Claude Code may load it as the default skill or override individual skill matching.
  Suggested: Delete `.claude/skills/SKILL.md`

---

## HIGH

[HIGH] agents/doey-manager.md:17, doey-session-manager.md:18, doey-watchdog.md:16 — Inconsistent `/tmp` security model across codebase
  All 3 agents use `source "${RUNTIME_DIR}/session.env"` to load config from `/tmp` (world-writable). Meanwhile, 4 skills (doey-kill-session, doey-kill-window, doey-worktree, doey-clear) explicitly warn "Do NOT use `source` on runtime env files — /tmp is world-writable; use safe reads only" and use `grep`+`cut` instead. **11 of 22 skills also use `source`** on the same files, contradicting the 4 that warn against it. Needs project-wide alignment.

[HIGH] agents/doey-manager.md:19 — Agent setup sources team env from /tmp without validation
  `source "$TEAM_ENV"` where `TEAM_ENV="${RUNTIME_DIR}/team_${DOEY_TEAM_WINDOW}.env"`. If an attacker writes a malicious team env file to `/tmp/doey/<project>/`, it executes arbitrary code in the Manager's shell context. Same applies to doey-watchdog.md:16.
  Suggested: Use safe grep-based reads or validate file ownership/permissions before sourcing.

[HIGH] agents/test-driver.md:45 — `Read` tool flagged as Manager-coding anomaly
  The anomaly table lists `Read` alongside `Edit`/`Write` as evidence of "Manager coding directly." But `Read` is read-only — Managers legitimately read files for planning. Flagging `Read` causes false-positive HIGH anomalies in test reports.
  Suggested: Remove `Read` from the anomaly detection pattern. Only flag `Edit`/`Write`.

[HIGH] .claude/skills/doey-worktree/SKILL.md:78 — Fragile `&&`/`||` chain in worktree creation
  Current: `[ -d "$WT_DIR" ] && git ... worktree remove ... || true && mkdir -p ...`
  If `git worktree remove` fails with a real error, `|| true` silently swallows it and continues. Mixed `&&`/`||` chains have surprising precedence.
  Suggested: Use explicit `if/then/fi` or group with `{ }` for clarity.

[HIGH] .claude/skills/doey-dispatch/SKILL.md:34 — Auto-scale block sources both session.env AND team env from /tmp
  Lines 34-35 use `source "${RUNTIME_DIR}/session.env"` and `source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"`, contradicting security warnings in other skills.
  Suggested: Use safe grep-based reads.

---

## MEDIUM

[MEDIUM] agents/doey-session-manager.md:1 — Frontmatter field ordering inconsistent
  Fields ordered as `name, model, color, memory, description` while other agents use `name, description, model, color, memory`. YAML doesn't require order, but consistency aids maintenance.

[MEDIUM] agents/doey-watchdog.md:96 — PROMPT_STUCK auto-accept sends `1` instead of `y`/`Y`
  Sending `1` assumes a numbered menu. If the prompt is a yes/no confirmation, `1` is incorrect input.
  Suggested: Document when `1` vs `y` is appropriate, or detect prompt type.

[MEDIUM] .claude/skills/doey-reserve/SKILL.md:24 — ACTION variable hardcoded to "reserve"
  The instruction says "Set ACTION based on user argument" but the bash block always sets `ACTION="reserve"`. If copied verbatim, unreserve never works.
  Suggested: Split into two blocks (reserve/unreserve) or use a clear placeholder.

[MEDIUM] .claude/skills/doey-clear/SKILL.md:97 — Background subshell for Watchdog briefing has no tracking
  `( sleep 15 ... ) &` runs asynchronously. If the shell session ends before completion (~35s), the briefing is lost. No cleanup mechanism.

[MEDIUM] .claude/skills/doey-kill-all-sessions/SKILL.md:31 — Broad `rm -rf /tmp/doey/*/`
  Removes ALL Doey runtime dirs. If multiple users share `/tmp/doey/`, this deletes everything.
  Suggested: Iterate over discovered sessions and remove per-project dirs explicitly.

[MEDIUM] .claude/skills/doey-rd-team/SKILL.md:12 — Context injection uses wildcard `cat /tmp/doey/*/session.env`
  If multiple Doey sessions exist, this concatenates all their configs. Should target specific project via `DOEY_RUNTIME`.

[MEDIUM] .claude/skills/doey-rd-team/SKILL.md:130-133 — Stale skill/hook counts in R&D worker prompt
  Current: "20 Doey skills" and "13 hooks"
  Actual: 22 doey-* skill directories + 1 unknown-task = 23 skills total, and 12 hook .sh files
  Suggested: Update to correct counts.

[MEDIUM] .claude/skills/doey-delegate/SKILL.md:40 — Semicolon breaks `&&` chain allowing reserved pane capture
  `...&& tmux copy-mode ... ; OUTPUT=$(tmux capture-pane ...)` — the `;` means `OUTPUT=` always runs regardless of the reservation check.
  Suggested: Use `&&` consistently or restructure with `if/then`.

[MEDIUM] .claude/skills/doey-reinstall/SKILL.md:11 — Uses `cd "$REPO_DIR"` changing CWD
  Skills generally avoid `cd`. Could use `git -C "$REPO_DIR" pull` and `bash "$REPO_DIR/install.sh"` instead.

---

## LOW

[LOW] agents/doey-session-manager.md:4 — Inconsistent color format
  Current: `color: "#FF6B35"` (hex string). Other agents use named colors (green, yellow, red).
  Suggested: Use a named color (e.g., `orange`) for consistency.

[LOW] agents/doey-session-manager.md:56 — Message read loop deletes files during iteration
  `rm -f "$f"` inside glob loop. Safe in bash (glob expanded before loop) but could race with concurrent writers.

[LOW] agents/doey-watchdog.md:108 — "One bash call per cycle" rule contradicts actual workflow
  The monitoring loop has scan (Step 1) and wait (Step 4) as separate bash calls.
  Suggested: "Minimize bash calls per cycle" or document expected count.

[LOW] .claude/skills/doey-broadcast/SKILL.md:17 — Timestamp collision potential
  `TIMESTAMP="$(date +%s)$$"` could collide if two broadcasts happen in same second from same PID.
  Suggested: Add `$RANDOM` for uniqueness.

[LOW] .claude/skills/doey-clear/SKILL.md:103 — `$CLAUDE_PROJECT_DIR` inconsistent with codebase convention
  Other skills use `$PROJECT_DIR`. `$CLAUDE_PROJECT_DIR` is a Claude Code built-in that works but is inconsistent.

[LOW] .claude/skills/doey-add-window/SKILL.md:22 — Step 1 is a single 450+ character bash one-liner
  Extremely hard to debug. Breaking into multiple commands would improve maintainability.

---

## INFO (no action needed)

[INFO] agents/doey-manager.md — Complete frontmatter (name, description, model:opus, color:green, memory:user). Setup block correct. Good task template and budget system.

[INFO] agents/doey-watchdog.md — Complete frontmatter (model:haiku, memory:none). Cost-efficient model choice. Anomaly detection table is comprehensive.

[INFO] agents/test-driver.md — Complete frontmatter (model:opus, memory:none). Good state machine design for E2E testing.

[INFO] doey-add-window — Comprehensive with proper error handling. Uses atomic writes correctly.

[INFO] doey-broadcast — Clean. Proper `tr ':.' '_'` for safe filenames.

[INFO] doey-kill-session — Good security with safe reads.

[INFO] doey-kill-window — Good worktree cleanup with auto-save.

[INFO] doey-list-windows — Read-only, zero bash commands.

[INFO] doey-monitor — Well-structured with deep inspect fallback.

[INFO] doey-purge — Good two-wave structure with user confirmation.

[INFO] doey-reinstall — Simple and correct (aside from `cd`).

[INFO] doey-reload — Appropriate self-kill warning.

[INFO] doey-repair — Good bash 3.2 workaround using case instead of `declare -A`.

[INFO] doey-simplify-everything — Good domain assignment strategy.

[INFO] doey-status — Clean view/set modes.

[INFO] doey-stop — Proper SIGTERM→SIGKILL escalation.

[INFO] doey-watchdog-compact — Simple with retry logic.

[INFO] unknown-task — Good conservative fallback with tool-call budget.

---

## Cross-Cutting Observations

### 1. `/tmp` Sourcing Inconsistency (project-wide)

**Skills that `source` from /tmp (11):** doey-add-window, doey-broadcast, doey-delegate, doey-dispatch, doey-purge, doey-rd-team, doey-reload, doey-research, doey-simplify-everything, doey-stop, doey-watchdog-compact

**Skills that use safe `grep`+`cut` reads (4):** doey-kill-session, doey-kill-window, doey-worktree, doey-clear (partially)

**All 3 runtime agents** use `source`.

**Recommendation:** Pick one approach. If `/tmp` sourcing is acceptable (Doey controls runtime dir creation, sessions are single-user), remove warnings from the 4 skills. If dangerous, convert all 11 skills + 3 agents to safe reads.

### 2. No Bash 3.2 Violations Found

Zero instances of: `declare -A/-n/-l/-u`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `printf '%(%s)T'` in any agent or skill.

### 3. Skill Structure Quality

All 22 doey-* skills + unknown-task have valid YAML frontmatter (name, description). Context injection (`!` backtick syntax) used consistently. Error handling ("If this fails with...") thorough across most skills. Atomic writes (tmpfile + mv) used consistently for env file updates.

### 4. Agent Model/Memory Choices

All appropriate: opus for complex reasoning (Manager, SM, test-driver), haiku for stateless scanning (Watchdog). Memory `user` for roles that benefit from preference recall, `none` for ephemeral roles.
