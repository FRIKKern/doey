# Audit Report: Agent Definitions & Skills

**Auditor:** Worker 2 (R&D Audit Team)
**Date:** 2026-03-23
**Scope:** 4 agent files (`agents/*.md`), 22 skill directories (`.claude/skills/doey-*/SKILL.md` + `unknown-task/`), 1 top-level SKILL.md

---

## Summary

| Category | Files | Issues |
|----------|-------|--------|
| Agents | 4 | 7 |
| Skills | 23 | 19 |
| **Total** | **27** | **26** |

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 7 |
| MEDIUM | 12 |
| LOW | 6 |

---

## Agent Findings

### agents/doey-manager.md

[MEDIUM] file:agents/doey-manager.md line:17 — Setup block uses `source "${RUNTIME_DIR}/session.env"` on a file in /tmp (world-writable). Other skills (doey-kill-session, doey-worktree, doey-clear) explicitly warn against sourcing /tmp files and use safe grep-based reads instead. Manager agent should follow the same safe-read pattern or at least document the risk.

[LOW] file:agents/doey-manager.md line:28 — References `${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved` but `TARGET_PANE_SAFE` is not defined in the setup block. The variable naming convention is clear from context, but this is the only place it appears without a derivation example.

[LOW] file:agents/doey-manager.md line:50 — `/doey-monitor` polling interval stated as "every 10-15 seconds" but the doey-monitor skill says "Min 15s poll". Minor inconsistency: agent says 10s minimum, skill says 15s.

### agents/doey-session-manager.md

[MEDIUM] file:agents/doey-session-manager.md line:17 — Same `source "${RUNTIME_DIR}/session.env"` pattern in /tmp. Inconsistent with the safe-read practices used in kill-session and other skills.

[LOW] file:agents/doey-session-manager.md line:6 — Color uses hex value `"#FF6B35"` while other agents use named colors (green, yellow, red). Not a bug, but inconsistent style.

### agents/doey-watchdog.md

[MEDIUM] file:agents/doey-watchdog.md line:15 — Setup block uses `source "${RUNTIME_DIR}/session.env"` in /tmp. Same concern as manager agents. Watchdog is the most frequent executor of this code (every scan cycle).

[HIGH] file:agents/doey-watchdog.md line:16 — `TEAM_WINDOW="${DOEY_TEAM_WINDOW}"` relies on the hook-injected `DOEY_TEAM_WINDOW` env var being set. If `on-session-start.sh` hook fails or is not loaded, this will be empty, silently breaking all watchdog operations. No fallback or error check.

### agents/test-driver.md

[MEDIUM] file:agents/test-driver.md line:9 — States "Only window 1 is tested" — hardcodes window 1 as the test target. This is fragile if the session layout changes or if window 1 is not the first team window. Should derive from session.env TEAM_WINDOWS.

[LOW] file:agents/test-driver.md line:4 — Agent has `memory: none` which is appropriate for ephemeral test runs, but `model: opus` may be expensive for a test driver that mostly does tmux capture-pane and simple verification. Consider `sonnet` for cost savings.

---

## Skill Findings

### .claude/skills/SKILL.md (top-level)

[CRITICAL] file:.claude/skills/SKILL.md line:1 — This top-level SKILL.md is a **complete duplicate** of `doey-worktree/SKILL.md` (identical content, 198 lines). It has `name: doey-worktree` in its frontmatter. This file appears to be an accidental copy. If Claude's skill resolution reads this file, it may shadow or conflict with the actual `doey-worktree` skill. Should be removed or replaced with an index/registry file.

### .claude/skills/doey-add-window/SKILL.md

[HIGH] file:.claude/skills/doey-add-window/SKILL.md line:22 — Step 1 parse block: `for _aw_arg in "$@"; do` — `$@` is not meaningful in a skill SKILL.md context since skills are invoked by Claude, not as shell scripts with positional args. The `--worktree` flag parsing relies on the agent interpreting and setting `WORKTREE_MODE` manually, but the bash block pretends to parse CLI args that don't exist.

[MEDIUM] file:.claude/skills/doey-add-window/SKILL.md line:53 — Step 4: Worker launch command uses `grep -rl "pane ${NEW_WIN}\.${i} "` to find worker system prompts. The pattern includes a trailing space after the pane number, which is fragile — if the prompt file format changes, this grep silently fails and workers launch without their system prompt.

### .claude/skills/doey-broadcast/SKILL.md

[MEDIUM] file:.claude/skills/doey-broadcast/SKILL.md line:17 — `TIMESTAMP="$(date +%s)$$"` concatenates epoch seconds with PID for uniqueness, but `$$` inside a skill bash block will be the shell's PID, which may collide if two broadcasts happen in the same second from panes sharing a shell parent. Consider adding `$RANDOM` or nanoseconds.

### .claude/skills/doey-clear/SKILL.md

[MEDIUM] file:.claude/skills/doey-clear/SKILL.md line:96 — Step 5 Watchdog briefing uses a background subshell `( sleep 15; ... ) &` with hardcoded 15s and 20s sleeps. If the Watchdog boot takes longer (e.g., slow auth), the briefing send-keys may arrive before Claude is ready, causing the message to be swallowed or appear as raw text in the shell.

[LOW] file:.claude/skills/doey-clear/SKILL.md line:103 — The `/loop` command sent to Watchdog has a complex quoted string that includes nested quotes. If tmux's send-keys escaping doesn't handle this perfectly, the command may be malformed. This is a known fragile pattern.

### .claude/skills/doey-delegate/SKILL.md

[MEDIUM] file:.claude/skills/doey-delegate/SKILL.md line:40 — Step 3 validation: `source "${RUNTIME_DIR}/session.env"` in /tmp — inconsistent with the safe-read pattern used in doey-kill-session and doey-worktree. Should use grep-based reads for consistency and security.

### .claude/skills/doey-dispatch/SKILL.md

[HIGH] file:.claude/skills/doey-dispatch/SKILL.md line:33 — Auto-scale block calls `doey add 2>/dev/null` which is an external CLI command. If `doey` is not on PATH (e.g., in a worktree or non-standard install), this silently fails. No error handling or fallback. Should use the full path or check availability first.

[HIGH] file:.claude/skills/doey-dispatch/SKILL.md line:34 — After `doey add`, does `source "${RUNTIME_DIR}/session.env"` and `source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"` — sourcing /tmp files, same security concern as agents. Also, after auto-scale, the `WINDOW_INDEX` may not match the new window since `doey add` creates a new window, not a new pane in the current one.

### .claude/skills/doey-kill-all-sessions/SKILL.md

[HIGH] file:.claude/skills/doey-kill-all-sessions/SKILL.md line:31 — `rm -rf /tmp/doey/*/` removes ALL doey project runtimes. If multiple projects are using Doey simultaneously, this destroys all of them, not just the current session. The skill description says "kill ALL" but the blast radius may not be obvious to users. Should at minimum list what will be deleted before confirming.

### .claude/skills/doey-kill-session/SKILL.md

No issues found. Good use of safe reads (no `source`), proper SIGTERM-then-SIGKILL pattern, confirmation before destructive action.

### .claude/skills/doey-kill-window/SKILL.md

[MEDIUM] file:.claude/skills/doey-kill-window/SKILL.md line:23 — Step 1 uses `_sv()` helper for safe reads from session.env but does not quote `$1` parameter: `grep "^$1="` — if $1 contains regex metacharacters, this could match unintended lines. Low practical risk since the keys are hardcoded strings.

### .claude/skills/doey-list-windows/SKILL.md

No issues found. Read-only skill with good context injection.

### .claude/skills/doey-monitor/SKILL.md

No issues found. Well-structured read-heavy skill with appropriate context injection.

### .claude/skills/doey-purge/SKILL.md

[MEDIUM] file:.claude/skills/doey-purge/SKILL.md line:27 — Uses `source "${RUNTIME_DIR}/session.env"` — /tmp sourcing concern. Also sources `team_${WINDOW_INDEX}.env` on line 29.

### .claude/skills/doey-rd-team/SKILL.md

[HIGH] file:.claude/skills/doey-rd-team/SKILL.md line:29 — Hardcodes Doey repo path as `$HOME/Documents/github/doey`. This is user-specific and will fail for any other user or any installation outside this exact path. Should use `~/.claude/doey/repo-path` (which doey-reinstall already uses) or derive from the running session.

[MEDIUM] file:.claude/skills/doey-rd-team/SKILL.md line:12 — Context injection uses `cat /tmp/doey/*/session.env 2>/dev/null | head -20` which globs ALL project session.env files. If multiple Doey projects are running, this returns data from an arbitrary one. Should use `DOEY_RUNTIME` env var instead.

### .claude/skills/doey-reinstall/SKILL.md

[MEDIUM] file:.claude/skills/doey-reinstall/SKILL.md line:9 — Uses `cat ~/.claude/doey/repo-path` for repo location while doey-rd-team hardcodes `$HOME/Documents/github/doey`. These two skills have inconsistent mechanisms for finding the Doey source repo.

### .claude/skills/doey-reload/SKILL.md

No issues found. Simple, focused skill.

### .claude/skills/doey-repair/SKILL.md

[MEDIUM] file:.claude/skills/doey-repair/SKILL.md line:23 — `SLOT=$(echo "$WD_VAL" | tr -d '.')` converts e.g. `0.3` to `03` for case matching. This works for single-digit slots but would break for `0.10` (becomes `010`, not matched by case). Practically limited to 0.2-0.7 so not a real bug, but fragile.

### .claude/skills/doey-research/SKILL.md

No issues found. Good pattern with task markers and report-path enforcement.

### .claude/skills/doey-reserve/SKILL.md

No issues found. Simple, correct.

### .claude/skills/doey-simplify-everything/SKILL.md

[HIGH] file:.claude/skills/doey-simplify-everything/SKILL.md line:46 — Inventory `wc -l` command includes `.claude/settings.local.json` which is a gitignored, potentially sensitive file. If the simplification workers read and modify it, the changes would be user-specific and not committable.

### .claude/skills/doey-status/SKILL.md

No issues found.

### .claude/skills/doey-stop/SKILL.md

[MEDIUM] file:.claude/skills/doey-stop/SKILL.md line:17 — Uses `source "$RD/session.env"` and `source "$RD/team_${W}.env"` — /tmp sourcing pattern again.

### .claude/skills/doey-watchdog-compact/SKILL.md

No issues found. Simple, focused skill.

### .claude/skills/doey-worktree/SKILL.md

No issues found. Well-structured with good error handling, atomic writes, safe reads. One of the best-written skills.

### .claude/skills/unknown-task/SKILL.md

No issues found. Good conservative fallback with budget limits.

---

## Cross-Cutting Issues

### 1. Inconsistent /tmp sourcing security pattern

**Affected:** doey-manager agent, doey-session-manager agent, doey-watchdog agent, doey-delegate skill, doey-dispatch skill, doey-purge skill, doey-stop skill, doey-rd-team skill

Several files use `source "${RUNTIME_DIR}/session.env"` where RUNTIME_DIR is under /tmp (world-writable). Other skills (doey-kill-session, doey-kill-window, doey-worktree, doey-clear) explicitly warn "Do NOT use source on runtime env files — /tmp is world-writable" and use `grep`-based safe reads. This inconsistency creates a confusing security posture. Either all should source (accepting the risk in a local-only CLI) or all should use safe reads.

### 2. Doey repo path inconsistency

**Affected:** doey-rd-team (hardcodes `$HOME/Documents/github/doey`), doey-reinstall (uses `~/.claude/doey/repo-path`)

Two different mechanisms exist for locating the Doey source repo. The `repo-path` file approach is more portable.

### 3. Worker system prompt grep pattern fragility

**Affected:** doey-add-window, doey-dispatch, doey-clear, doey-worktree

All use `grep -rl "pane ${W}\.${i} "` (or similar) with a trailing space to find worker-specific system prompt files. This pattern is fragile and will silently fail if the prompt file format changes.

### 4. Top-level SKILL.md is a duplicate

The file `.claude/skills/SKILL.md` is an exact copy of `.claude/skills/doey-worktree/SKILL.md`. This should be removed to avoid skill resolution confusion.

---

## Findings by Severity

### CRITICAL (1)
1. `.claude/skills/SKILL.md` — Duplicate of doey-worktree skill at top level, may cause skill resolution conflicts

### HIGH (7)
1. `doey-watchdog.md:16` — No fallback if DOEY_TEAM_WINDOW env var is unset
2. `doey-add-window:22` — `$@` parsing in skill bash block is meaningless
3. `doey-dispatch:33` — `doey add` called without path check or error handling
4. `doey-dispatch:34` — Sources /tmp files after auto-scale, WINDOW_INDEX may be stale
5. `doey-kill-all-sessions:31` — `rm -rf /tmp/doey/*/` destroys ALL projects' runtimes
6. `doey-rd-team:29` — Hardcoded user-specific Doey repo path
7. `doey-simplify-everything:46` — Includes gitignored settings.local.json in inventory

### MEDIUM (12)
1. `doey-manager.md:17` — Sources /tmp session.env (inconsistent with safe-read pattern)
2. `doey-session-manager.md:17` — Sources /tmp session.env
3. `doey-watchdog.md:15` — Sources /tmp session.env
4. `test-driver.md:9` — Hardcodes window 1 as test target
5. `doey-add-window:53` — Fragile grep pattern for worker system prompts
6. `doey-broadcast:17` — Timestamp+PID collision potential
7. `doey-clear:96` — Background briefing timing fragility
8. `doey-delegate:40` — Sources /tmp session.env
9. `doey-purge:27` — Sources /tmp session.env
10. `doey-rd-team:12` — Context injection globs all project session.env files
11. `doey-reinstall:9` — Repo path mechanism inconsistent with doey-rd-team
12. `doey-stop:17` — Sources /tmp session.env

### LOW (6)
1. `doey-manager.md:28` — TARGET_PANE_SAFE used without derivation example
2. `doey-manager.md:50` — Monitor interval inconsistency (10-15s vs skill's 15s min)
3. `doey-session-manager.md:6` — Hex color vs named colors in other agents
4. `test-driver.md:4` — Opus model may be expensive for test driver role
5. `doey-clear:103` — Fragile nested quoting in /loop send-keys
6. `doey-repair:23` — Slot string conversion fragile for multi-digit indices
