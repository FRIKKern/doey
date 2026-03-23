# Audit: Agent Definitions & Skill Definitions

**Date:** 2026-03-23
**Auditor:** Worker 2 (R&D Team)
**Scope:** 4 agent files (`agents/*.md`), 22 skill directories (`.claude/skills/doey-*/`), 1 root SKILL.md, 1 fallback skill (`unknown-task`)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 4 |
| MEDIUM | 9 |
| LOW | 6 |

---

## CRITICAL

[CRITICAL] .claude/skills/SKILL.md:1 — Top-level SKILL.md is an exact duplicate of doey-worktree/SKILL.md
  Current: Full 198-line copy of `doey-worktree/SKILL.md` at `.claude/skills/SKILL.md` (outside any skill subdirectory)
  This file is tracked as untracked by git (`?? .claude/skills/SKILL.md`). Claude Code may load it as a default skill or interfere with skill resolution.
  Suggested: Delete `.claude/skills/SKILL.md`

## HIGH

[HIGH] agents/doey-manager.md:17-19 + agents/doey-session-manager.md:17-18 + agents/doey-watchdog.md:15-16 — Inconsistent /tmp security model across project
  Current: All 3 agents use `source "${RUNTIME_DIR}/session.env"` and `source "$TEAM_ENV"`. 11 of 22 skills also use `source`. But 4 skills (doey-kill-session, doey-kill-window, doey-worktree, doey-clear) explicitly warn "Do NOT use source on runtime env files — /tmp is world-writable; use safe reads only" and use `grep`+`cut` instead.
  This contradiction means either the warnings are unnecessary noise (confusing developers) or the majority of the codebase has a security gap.
  Suggested: Project-wide decision — either standardize on `source` (and remove the warnings) or standardize on safe grep reads (and fix the 11 skills + 3 agents)

[HIGH] agents/test-driver.md:45 — Read tool flagged as "Manager coding directly" anomaly
  Current: Anomaly detection table lists `Read` alongside `Edit`/`Write` as evidence of "Manager coding directly" (HIGH severity)
  `Read` is read-only — Managers legitimately read files for planning and research. Flagging it causes false-positive HIGH anomalies in test reports.
  Suggested: Remove `Read` from the detection pattern, keep only `Edit`/`Write`

[HIGH] .claude/skills/doey-worktree/SKILL.md:78 — Fragile &&/|| chain in worktree creation
  Current: `[ -d "$WT_DIR" ] && git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || true && mkdir -p ...`
  Mixed `&&`/`||` relies on left-to-right evaluation. If `git worktree remove` fails with a real error (not "not found"), `|| true` silently swallows it and proceeds to create a new worktree over a corrupted state.
  Suggested: Use explicit `if/then/fi`: `if [ -d "$WT_DIR" ]; then git ... worktree remove ... --force 2>/dev/null || true; fi; mkdir -p ...`

[HIGH] .claude/skills/doey-delegate/SKILL.md:40 — Semicolon breaks &&-chain, skips reservation check
  Current: `...&& [ ! -f "..." ] && tmux copy-mode ... ; OUTPUT=$(tmux capture-pane ...) && echo ...`
  The `;` after `tmux copy-mode` means `OUTPUT=` always runs regardless of whether the reservation check passed. A reserved pane's output is captured and reported as "Idle — OK" even when the `.reserved` file exists.
  Suggested: Replace `;` with `&&` or restructure into separate commands

## MEDIUM

[MEDIUM] agents/doey-session-manager.md:1-7 — Frontmatter field ordering inconsistent
  Current: Fields ordered `name, model, color, memory, description` (description last)
  Other agents use `name, description, model, color, memory` (description second). Inconsistent ordering hinders automated parsing.
  Suggested: Reorder to match other agents: `name, description, model, color, memory`

[MEDIUM] agents/doey-watchdog.md:96 — PROMPT_STUCK auto-accept sends `1` instead of `y`/`Y`
  Current: "Auto-accepted with `1` Enter (30s cooldown)"
  Sending `1` assumes a numbered menu. For yes/no prompts (`Do you want to continue? (y/N)`), `1` is incorrect input. The auto-accept strategy should match the prompt type.
  Suggested: Use `y` as default auto-accept (more universal), or detect prompt type in watchdog-scan.sh

[MEDIUM] .claude/skills/doey-rd-team/SKILL.md:130-133 — Stale counts in embedded system prompt
  Current: `shell/doey.sh — Main script (1455 lines)`, `.claude/skills/ — 20 Doey skills`, `.claude/hooks/ — 13 hooks`
  CLAUDE.md says doey.sh is ~2600 lines. There are 22+ skill directories. Stale counts mislead R&D workers.
  Suggested: Update line count and skill/hook counts, or use approximate language ("20+ skills")

[MEDIUM] .claude/skills/doey-dispatch/SKILL.md:33 — Undocumented `doey add` CLI command
  Current: `doey add 2>/dev/null; sleep 10` in auto-scale block
  The `doey add` subcommand is not documented in CLAUDE.md. If it doesn't exist, auto-scale silently fails.
  Suggested: Verify `doey add` exists in doey.sh; document it or remove the auto-scale block

[MEDIUM] .claude/skills/doey-clear/SKILL.md:97-104 — Background subshell with no tracking
  Current: `( sleep 15; tmux send-keys ... ; sleep 20; tmux send-keys ... ) &`
  The subshell runs asynchronously for ~35s with no PID tracking. If the skill exits or the shell session ends before completion, the Watchdog briefing is lost with no indication.
  Suggested: Write PID to a file or use a more robust deferred-action mechanism

[MEDIUM] .claude/skills/doey-kill-all-sessions/SKILL.md:31 — Aggressive runtime directory removal
  Current: `rm -rf /tmp/doey/*/`
  Removes ALL Doey runtime directories for all projects. If multiple projects share `/tmp/doey/`, this is overly destructive.
  Suggested: Only remove runtime dirs for sessions that were actually killed

[MEDIUM] .claude/skills/doey-rd-team/SKILL.md:12 — Context injection uses wildcard glob for session.env
  Current: `!cat /tmp/doey/*/session.env 2>/dev/null | head -20`
  If multiple Doey sessions exist, this concatenates all their configs, potentially confusing the skill.
  Suggested: Use `tmux show-environment DOEY_RUNTIME` like other skills

[MEDIUM] .claude/skills/doey-reserve/SKILL.md:24 — ACTION variable always hardcoded to "reserve"
  Current: `ACTION="${1:-reserve}"` — but this is inside a skill prompt's bash block where `$1` is not the user's argument
  The Claude instance executing the skill must manually edit this line. If it copies the block verbatim, unreserve never works.
  Suggested: Split into two separate bash blocks (one for reserve, one for unreserve) or add a clear instruction to replace `$1`

[MEDIUM] .claude/skills/doey-reinstall/SKILL.md:11 — Uses `cd` instead of `-C` flag
  Current: `cd "$REPO_DIR" && git pull`
  Other skills avoid `cd` to prevent CWD side effects. Use `git -C "$REPO_DIR" pull` instead.
  Suggested: `git -C "$REPO_DIR" pull && bash "$REPO_DIR/install.sh"`

## LOW

[LOW] agents/doey-session-manager.md:56 — File deletion during glob iteration
  Current: `for f in ..._*.msg; do ... && rm -f "$f"; done`
  Deleting files while iterating a glob is safe in bash (glob expanded before loop), but could race with concurrent message writers. Minor data-loss risk.
  Suggested: Move processed files to an archive dir instead of deleting

[LOW] agents/doey-watchdog.md:128 — "One bash call per cycle" contradicts actual workflow
  Current: Rule says "One bash call per cycle" but the monitoring loop has scan (Step 1) and wait (Step 4) as separate bash calls
  Suggested: Update to "minimize bash calls per cycle" or document the expected 2-call pattern

[LOW] .claude/skills/doey-broadcast/SKILL.md:17 — Timestamp collision potential
  Current: `TIMESTAMP="$(date +%s)$$"` — epoch seconds + PID
  If two broadcasts happen in the same second from the same process, filenames collide.
  Suggested: Add `$RANDOM` for additional uniqueness

[LOW] .claude/skills/doey-add-window/SKILL.md:22 — Step 1 is a 450+ character one-liner
  Current: Single bash command with 10+ chained operations
  Extremely hard to debug if any step fails. Works correctly but poor maintainability.
  Suggested: Split into 2-3 smaller commands with intermediate validation

[LOW] .claude/skills/doey-clear/SKILL.md:96 — Fragile sed for pane list construction
  Current: `WP_LIST=$(echo "$WORKER_PANES" | tr ',' ' ' | sed "s/[0-9][0-9]*/${W}.&/g" | tr ' ' ',')`
  The `sed` with `&` backreference works but is harder to read than a simple loop.
  Suggested: Construct list in a loop for clarity

[LOW] .claude/skills/doey-worktree/SKILL.md:190 — Ambiguous wording about `[[ =~ ]]`
  Current: "no `[[ =~ ]]` captures"
  Bash 3.2 supports `[[ =~ ]]` but `BASH_REMATCH` capture groups are unreliable. The wording could be clearer.
  Suggested: Rephrase to "`[[ =~ ]]` is allowed for matching, but do not use `BASH_REMATCH` capture groups"

---

## Cross-Cutting Observations

### 1. /tmp Sourcing Inconsistency (project-wide)

**Skills using `source` (11):** doey-add-window, doey-broadcast, doey-delegate, doey-dispatch, doey-purge, doey-rd-team, doey-reload, doey-research, doey-simplify-everything, doey-stop, doey-watchdog-compact

**Skills using safe `grep`+`cut` (4):** doey-kill-session, doey-kill-window, doey-worktree, doey-clear

**All 3 agents** use `source`.

**Recommendation:** Since Doey controls runtime dir creation, the session is single-user, and the agents themselves use `source`, the safer approach is to standardize on `source` and remove the misleading warnings from the 4 skills.

### 2. Frontmatter Verification — All Pass

All 4 agents have required fields: `name`, `description`, `model`, `color`, `memory`. All 23 skills have required fields: `name`, `description`. No invalid YAML detected.

### 3. Bash 3.2 Compliance — All Pass

No use of `declare -A`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, or `printf '%(%s)T'` found in any agent or skill.

### 4. Model Choices — Appropriate

Haiku for Watchdog (cost-effective monitoring), Opus for Manager/SM/test-driver (complex coordination). Workers default to Opus.
