# Audit: Agent Definitions & Skill Definitions
Date: 2026-03-23 | Auditor: Worker 2 (agent-audit_0323)

---

## AGENTS

### HIGH

*(none — agent definitions are structurally sound)*

### MEDIUM

**[MEDIUM] agents/doey-watchdog.md:119 — Issue log category taxonomy differs from Manager**
- Watchdog uses: `<crash|stuck|unexpected|performance>`
- Manager uses: `<dispatch|crash|permission|stuck|unexpected|performance>`
- `dispatch` and `permission` categories are absent from the Watchdog taxonomy. Issues in those categories would be miscategorized or omitted.

### LOW

**[LOW] agents/doey-session-manager.md:4 — Inconsistent color format**
- Current: `color: "#FF6B35"` (hex string)
- Other agents: `color: green`, `color: yellow`, `color: red` (named colors)
- Minor cosmetic inconsistency; may not affect functionality depending on how Claude Code renders agent colors.

**[LOW] agents/test-driver.md:15 — Contradictory dispatch mechanism**
- Current: "Send to `$SESSION:1.0` only via `/doey-dispatch`"
- test-driver explicitly runs "OUTSIDE the tmux session via tmux commands only" — the `/doey-dispatch` skill requires `DOEY_RUNTIME` env var which won't be set outside the session.
- The actual dispatch mechanism (load-buffer/paste-buffer) is described further in the file but the top-level Dispatch section misleads.

**[LOW] agents/test-driver.md — Hardcoded window 1 assumption not documented**
- `PANE_SAFE=$(echo "${SESSION}_1_0" | tr ':.' '_')` hardcodes window 1
- This is correct by design (test-driver only tests window 1), but there's no explanation for future maintainers that `_1_0` is intentional, not an oversight.

---

## SKILLS

### HIGH

**[HIGH] .claude/skills/doey-rd-team/SKILL.md:130 — Hardcoded stale line count**
- Current: `shell/doey.sh (1455 lines)` in the embedded R&D worker system prompt
- This count was correct at the time of writing but is now stale and will mislead R&D workers about file size. Workers may stop reading early or make wrong assumptions.
- Suggested: Remove the line count, or use a dynamic count via `wc -l` at spawn time.

**[HIGH] .claude/skills/doey-rd-team/SKILL.md:131-132 — Hardcoded stale counts in embedded worker prompt**
- Current: `".claude/skills/ — 20 Doey skills"` and `".claude/hooks/ — 13 hooks"`
- These counts drift as skills/hooks are added or removed. Workers relying on these counts may not read all files.
- Suggested: Remove counts, or generate dynamically.

**[HIGH] .claude/skills/doey-clear/SKILL.md:96 — Malformed sed pattern**
- Current: `sed "s/[0-9][0-9]*//${W}.&/g"`
- The `//` creates a 4-delimiter `s` command: `s/PATTERN//REPLACEMENT/FLAGS` which is invalid — BSD sed on macOS will error or produce wrong output. The second `/` becomes an empty replacement while `${W}.&/g` becomes garbage flags.
- Suggested: `sed "s/[0-9][0-9]*/${W}.&/g"` (remove the extra `/`)
- Impact: `WP_LIST` for Watchdog briefing is broken; Watchdog receives no pane list and may not monitor the correct panes after a clear.

### MEDIUM

**[MEDIUM] .claude/skills/doey-repair/SKILL.md:Step 2 — `$SESSION_NAME` used but not set**
- Step 2's bash block references `$SESSION_NAME` in `tmux display-message -t "$SESSION_NAME:0.${IDX}"`, but SESSION_NAME is not set within Step 2.
- Step 1 only sets `RUNTIME_DIR` and `TEAM_FOR_0X` variables; these don't persist to Step 2's separate bash invocation.
- Suggested: Add `SESSION_NAME=$(grep '^SESSION_NAME=' "${RUNTIME_DIR}/session.env" | head -1 | cut -d= -f2- | tr -d '"')` at the start of Step 2.

**[MEDIUM] .claude/skills/doey-repair/SKILL.md:Step 3 — Session Manager launched without `--model opus`**
- Current: `"claude --dangerously-skip-permissions --agent doey-session-manager"`
- Every other SM launch (doey-add-window, doey-rd-team, doey.sh) specifies `--model opus`. Without it, SM falls back to the default model (not necessarily Opus).
- Suggested: Add `--model opus` to the Session Manager relaunch command.

**[MEDIUM] .claude/skills/doey-kill-session/SKILL.md:Step 5 — Cross-step variable leak**
- Step 5: `rm -rf "$RD"` uses `$RD` which is only set in Step 1's bash block.
- Each `bash:` step is a separate invocation; `$RD` won't be available in Step 5.
- In practice Claude infers it, but the documented pattern will fail if executed literally.
- Suggested: Re-read `RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)` in Step 5.

**[MEDIUM] .claude/skills/doey-stop/SKILL.md:Step 1 — Uses `source` on /tmp files**
- Current: `source "$RD/session.env"` and `[ -f "$RD/team_${W}.env" ] && source "$RD/team_${W}.env"`
- doey-kill-session and doey-clear explicitly warn: "Do NOT use `source` on runtime env files — `/tmp` is world-writable". doey-stop contradicts this security principle.
- Suggested: Use the `_sv()` / `_tv()` safe-read helper pattern used in doey-clear.

**[MEDIUM] Inconsistent `source` usage across skills — security principle not uniformly applied**
- Several skills use `source "${RUNTIME_DIR}/session.env"` or `source "${RUNTIME_DIR}/team_*.env"` despite the documented security concern that `/tmp` is world-writable:
  - `.claude/skills/doey-dispatch/SKILL.md` (auto-scale block)
  - `.claude/skills/doey-purge/SKILL.md` (inventory block)
  - `.claude/skills/doey-reload/SKILL.md` (Step 1)
  - `.claude/skills/doey-simplify-everything/SKILL.md` (inventory block)
  - `.claude/skills/doey-research/SKILL.md` (Steps 2, 4, 6)
- doey-clear and doey-kill-session correctly use safe reads (`grep`/`cut`). The inconsistency is widespread and creates uneven security posture.
- Suggested: Standardize on the `_sv()` helper pattern across all skills.

**[MEDIUM] .claude/skills/doey-clear/SKILL.md:Step 5 — `$CLAUDE_PROJECT_DIR` in watchdog briefing**
- The briefing sent via send-keys uses `$CLAUDE_PROJECT_DIR` (Claude Code's built-in env var).
- All other skills use `$PROJECT_DIR` sourced from session.env. These should resolve to the same value in normal sessions, but in worktrees `$CLAUDE_PROJECT_DIR` would reflect the worktree dir while `$PROJECT_DIR` may differ depending on context.
- Suggested: Use `${PROJECT_DIR}` consistently.

### LOW

**[LOW] .claude/skills/SKILL.md — Stray duplicate file in wrong location**
- `/.claude/skills/SKILL.md` is an untracked duplicate of `.claude/skills/doey-worktree/SKILL.md`.
- `name: doey-worktree` — this skill file is placed in the skills root rather than its proper subdirectory.
- Impact: May be picked up by skill loaders incorrectly, or cause confusion about which file is canonical.
- Suggested: Delete `.claude/skills/SKILL.md`; the canonical copy is `.claude/skills/doey-worktree/SKILL.md`.

**[LOW] .claude/skills/doey-status/SKILL.md — RESERVED state inconsistency**
- Setting mode allows `STATUS: RESERVED` written to the `.status` file.
- Dispatch prevention depends on the existence of a `.reserved` file (separate file), not the STATUS field content.
- Setting STATUS to RESERVED without also creating the `.reserved` file won't actually prevent dispatch.
- Suggested: Document that `/doey-status set RESERVED` does not prevent dispatch; use `/doey-reserve` for that.

**[LOW] .claude/skills/doey-reinstall/SKILL.md — No validation of repo-path contents**
- Current: `REPO_DIR=$(cat ~/.claude/doey/repo-path 2>/dev/null)` — only checks if file is non-empty, not if path is valid.
- If `~/.claude/doey/repo-path` contains a stale or wrong path, the error message "Run ./install.sh from repo first" is misleading.
- Suggested: Add `[ -d "$REPO_DIR/.git" ] || { echo "ERROR: repo-path points to invalid location: $REPO_DIR"; exit 1; }`.

**[LOW] .claude/skills/doey-reload/SKILL.md — Grammatical error in Total line**
- Current: `"Total: 1 commands, 0 errors expected."`
- Suggested: `"Total: 1 command, 0 errors expected."`

**[LOW] .claude/skills/doey-add-window/SKILL.md:Step 1 — $@ and $USER_GRID ambiguity**
- Step 1 references `"${USER_GRID:-4x2}"` and `"$@"` as if the skill receives shell positional arguments.
- Skills do not receive args via `$@`; Claude must parse the user's message. The variable `USER_GRID` is never defined in the step.
- Actual behavior relies on Claude correctly extracting the grid arg from the user's message before running the bash block.
- Suggested: Add a note that `USER_GRID` must be set by Claude from the user-provided args before running Step 1.

**[LOW] .claude/skills/doey-monitor/SKILL.md — Direct `$DOEY_RUNTIME` reference in deep inspect**
- Current: `cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status"`
- All other skill blocks derive RUNTIME_DIR from `tmux show-environment DOEY_RUNTIME`. Using `$DOEY_RUNTIME` directly requires the env var to be set in the shell (by on-session-start hook). If the hook didn't run (e.g., manual invocation), this silently fails.
- Suggested: `DOEY_RUNTIME=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)` at start of deep inspect block.

---

## Summary

| Severity | Agents | Skills | Total |
|----------|--------|--------|-------|
| HIGH     | 0      | 3      | 3     |
| MEDIUM   | 1      | 5      | 6     |
| LOW      | 3      | 5      | 8     |
| **Total**| **4**  | **13** | **17**|

### Priority Fixes

1. **doey-clear sed bug** — will silently produce broken WP_LIST on macOS, breaking watchdog briefing pane list
2. **doey-rd-team stale counts** — misleads R&D workers about codebase size/scope
3. **doey-repair missing SESSION_NAME + missing --model opus** — two distinct bugs in the same skill
4. **source on /tmp files** — widespread, should be standardized to safe-read pattern
5. **stray .claude/skills/SKILL.md** — should be deleted to avoid confusion
