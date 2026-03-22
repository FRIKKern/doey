# Audit: Agents & Skills

**Date:** 2026-03-23
**Auditor:** Worker 2 (R&D Team)
**Scope:** 4 agent definitions (`agents/`), 22 skill definitions (`.claude/skills/doey-*/`), 1 top-level SKILL.md, 1 unknown-task skill

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 5 |
| MEDIUM | 9 |
| LOW | 6 |

---

## CRITICAL

- [CRITICAL] file:.claude/skills/SKILL.md line:1 — **Top-level SKILL.md is an exact duplicate of doey-worktree/SKILL.md.** `diff` shows zero differences. This file sits at `.claude/skills/SKILL.md` (outside any skill subdirectory) and could confuse skill resolution — Claude Code may load it as the default skill or override individual skill matching. Should be deleted.

## HIGH

- [HIGH] file:agents/doey-manager.md line:17 — **Inconsistent `/tmp` security model: `source` vs safe `grep` reads.** All 3 agents (`doey-manager.md:17`, `doey-session-manager.md:18`, `doey-watchdog.md:16`) use `source "${RUNTIME_DIR}/session.env"` to load config from `/tmp` (world-writable). Meanwhile, skills `doey-kill-session` (line 15), `doey-kill-window` (line 23), `doey-worktree` (lines 42-53), and `doey-clear` (lines 41-42) explicitly warn _"Do NOT use `source` on runtime env files — /tmp is world-writable; use safe reads only"_ and use `grep`+`cut` instead. **11 of 22 skills also use `source`** on the same files, contradicting the 4 that warn against it. Either `source` is acceptable (and the warnings are noise) or it's dangerous (and the majority of skills + all agents are vulnerable). This needs a project-wide decision and alignment.

- [HIGH] file:agents/doey-manager.md line:19 — **Agent setup sources team env from /tmp without validation.** `source "$TEAM_ENV"` where `TEAM_ENV="${RUNTIME_DIR}/team_${DOEY_TEAM_WINDOW}.env"`. If an attacker writes a malicious team env file to `/tmp/doey/<project>/`, it executes arbitrary code in the Manager's shell context. Same applies to `doey-watchdog.md:16`.

- [HIGH] file:agents/test-driver.md line:45 — **`Read` tool flagged as Manager-coding anomaly.** The anomaly table lists `Read` alongside `Edit`/`Write` as evidence of "Manager coding directly." But `Read` is read-only — Managers legitimately read files for planning/research. Flagging `Read` causes false-positive HIGH anomalies that pollute test reports. Should only flag `Edit`/`Write` (and possibly `Agent` with code-writing prompts).

- [HIGH] file:.claude/skills/doey-worktree/SKILL.md line:78 — **Fragile `&&`/`||` chain in worktree creation.** The command `[ -d "$WT_DIR" ] && git ... worktree remove ... || true && mkdir -p ...` relies on bash's left-to-right evaluation of mixed `&&`/`||`. If `git worktree remove` fails with a real error (not "not found"), `|| true` silently swallows it. Use explicit `if/then/fi` or group with `{ }` for clarity and correctness.

- [HIGH] file:.claude/skills/doey-dispatch/SKILL.md line:34 — **Auto-scale block sources both session.env AND team env from /tmp.** Lines 34-35 use `source "${RUNTIME_DIR}/session.env"` and `source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"` inside the auto-scale block, contradicting the security warnings in other skills.

## MEDIUM

- [MEDIUM] file:agents/doey-session-manager.md line:1 — **Frontmatter field ordering inconsistent with other agents.** `doey-session-manager.md` orders fields as `name, model, color, memory, description` while `doey-manager.md` and `doey-watchdog.md` use `name, description, model, color, memory`. YAML doesn't require order, but consistency aids maintenance and automated parsing.

- [MEDIUM] file:agents/doey-watchdog.md line:96 — **PROMPT_STUCK auto-accept sends `1` instead of `y` or `Y`.** The anomaly table says PROMPT_STUCK is "Auto-accepted with `1` Enter (30s cooldown)." Sending `1` assumes a numbered menu. If the prompt is a yes/no confirmation (`Do you want to continue? (y/N)`), sending `1` would be incorrect input. The auto-accept strategy should match the prompt type or use a more universal response.

- [MEDIUM] file:.claude/skills/doey-reserve/SKILL.md line:24 — **ACTION variable hardcoded to `"reserve"` in bash block.** The instruction says "Set ACTION=reserve or ACTION=unreserve based on user argument" but the bash block always sets `ACTION="reserve"` at line 24. The Claude instance must manually edit this line, but if it copies the block verbatim, unreserve never works. Should use a placeholder like `ACTION="$USER_ACTION"` or split into two separate blocks.

- [MEDIUM] file:.claude/skills/doey-clear/SKILL.md line:96 — **Watchdog briefing constructs pane list with fragile sed.** `sed "s/[0-9][0-9]*/${W}.&/g"` on space-separated pane indices. Works for simple cases but could match unintended digit sequences if WORKER_PANES contains unexpected format. Minor risk but should use a loop for clarity.

- [MEDIUM] file:.claude/skills/doey-clear/SKILL.md line:97 — **Background subshell `( sleep 15 ... ) &` for Watchdog briefing.** The subshell runs asynchronously with no tracking. If the skill exits or the shell session ends before the subshell completes (~35s), the briefing is lost. No cleanup mechanism if the Watchdog fails to boot.

- [MEDIUM] file:.claude/skills/doey-kill-all-sessions/SKILL.md line:31 — **`rm -rf /tmp/doey/*/` removes ALL Doey runtime dirs.** If multiple users or projects share `/tmp/doey/`, this deletes everything. The glob is correct but aggressive — consider per-session cleanup instead.

- [MEDIUM] file:.claude/skills/doey-rd-team/SKILL.md line:12 — **Context injection uses wildcard `cat /tmp/doey/*/session.env`.** Line 12 reads `!cat /tmp/doey/*/session.env 2>/dev/null | head -20`. If multiple Doey sessions exist, this concatenates all their configs, potentially confusing the skill. Should target the specific project's runtime dir via `DOEY_RUNTIME`.

- [MEDIUM] file:.claude/skills/doey-delegate/SKILL.md line:40 — **Step 3 uses semicolon `;` breaking `&&` chain.** The line `...&& [ ! -f "..." ] && tmux copy-mode ... ; OUTPUT=$(tmux capture-pane ...) && echo ...`. The `;` after `tmux copy-mode` means `OUTPUT=` always runs regardless of the reservation check, potentially capturing pane output from a reserved pane.

- [MEDIUM] file:.claude/skills/doey-reinstall/SKILL.md line:11 — **Uses `cd "$REPO_DIR"` which changes CWD.** Skills generally avoid `cd` since it can affect subsequent commands. Could use `git -C "$REPO_DIR" pull` and `bash "$REPO_DIR/install.sh"` instead.

## LOW

- [LOW] file:agents/doey-session-manager.md line:56 — **Message read loop uses `rm -f "$f"` inside a for loop over glob.** `for f in "$RUNTIME_DIR/messages"/${SM_SAFE}_*.msg; do [ -f "$f" ] && cat "$f" && echo "" && rm -f "$f"; done`. Deleting files while iterating a glob is safe in bash (glob is expanded before loop starts), but could race with concurrent writers. Consider `mv` to a processed dir instead.

- [LOW] file:agents/doey-watchdog.md line:108 — **"One bash call per cycle" rule is restrictive.** The agent says to do one bash call per cycle, but the monitoring loop has scan (Step 1) and wait (Step 4) as separate bash calls. The rule contradicts the actual workflow. Should say "minimize bash calls per cycle" or document the expected count.

- [LOW] file:agents/doey-manager.md line:36 — **send-keys example uses unquoted task text.** `tmux send-keys -t "$PANE" "Your task here" Enter` — if the task text contains special tmux characters or is too long, it will be mangled. The agent already recommends load-buffer for long tasks, but the "short" example could note character escaping.

- [LOW] file:.claude/skills/doey-broadcast/SKILL.md line:17 — **`TIMESTAMP="$(date +%s)$$"` collision potential.** Uses epoch seconds + PID for uniqueness. If two broadcasts happen in the same second from the same process (unlikely but possible with fast invocations), filenames collide. Consider adding `$RANDOM` or nanoseconds.

- [LOW] file:.claude/skills/doey-add-window/SKILL.md line:22 — **Step 1 is a single 450+ character bash one-liner.** Extremely hard to debug. While it works, breaking it into multiple commands with intermediate checks would improve maintainability.

- [LOW] file:.claude/skills/doey-worktree/SKILL.md line:190 — **Rules section mentions `[[ =~ ]]` captures but not `[[ =~ ]]` itself.** Bash 3.2 supports `[[ =~ ]]` but not capture groups into `BASH_REMATCH` reliably. The wording "no `[[ =~ ]]` captures" could be clearer: `[[ =~ ]]` is fine, just don't rely on `BASH_REMATCH`.

---

## Cross-Cutting Observations

### 1. `/tmp` Sourcing Inconsistency (affects entire project)

**Skills that `source` from /tmp (11):** doey-add-window, doey-broadcast, doey-delegate, doey-dispatch, doey-purge, doey-rd-team, doey-reload, doey-research, doey-simplify-everything, doey-stop, doey-watchdog-compact

**Skills that use safe `grep`+`cut` reads (4):** doey-kill-session, doey-kill-window, doey-worktree, doey-clear (partially — uses `_tv()` helper for team env but sources session.env elsewhere)

**All 3 agents** use `source`.

**Recommendation:** Pick one approach. If `/tmp` sourcing is acceptable (it probably is — Doey controls the runtime dir creation and the session is single-user), remove the warnings from the 4 skills. If it's truly dangerous, convert all 11 skills and 3 agents to safe reads.

### 2. Skill Structure Quality

All 22 skills have valid YAML frontmatter with `name` and `description`. No missing fields. Context injection blocks (`!` backtick syntax) are consistently used. Error handling with "If this fails with..." blocks is thorough and consistent across most skills.

### 3. Agent Quality

All 4 agents have valid frontmatter. Model choices are appropriate (opus for Manager/SM/test-driver, haiku for Watchdog). Memory settings are correct (user for Manager/SM to remember preferences, none for Watchdog/test-driver). Color choices are distinct (green, orange, yellow, red).

### 4. No Bash 3.2 Violations Found

No use of `declare -A`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, or `printf '%(%s)T'` in any agent or skill bash blocks.
