# Skill Audit

Audited 22 skill directories (21 `doey-*` + orphan `SKILL.md`). Date: 2026-03-22.

---

## Structural Issues

### .claude/skills/SKILL.md (orphan file)
- [MEDIUM] Orphan `SKILL.md` at root of skills directory — duplicate of `doey-worktree/SKILL.md`. Not inside a skill directory, so Claude Code won't discover it as a skill. Should be deleted.

### .claude/skills/doey-rd-team/skill.md (wrong filename case)
- [HIGH] File is `skill.md` (lowercase) instead of `SKILL.md` (uppercase). Claude Code expects `SKILL.md`. This skill may not be discoverable.
  Current: `.claude/skills/doey-rd-team/skill.md`
  Suggested: Rename to `.claude/skills/doey-rd-team/SKILL.md`

---

## .claude/skills/doey-add-window/SKILL.md
- [MEDIUM] Line 25: `source "${RUNTIME_DIR}/session.env"` — sources a file from `/tmp` (world-writable). Other skills (doey-clear, doey-kill-window, doey-worktree) use safe grep-based reads instead. Inconsistent security posture.
  Suggested: Use `grep`/`cut` pattern like `_sv()` in doey-kill-window
- [LOW] Line 27: `GRID="${USER_GRID:-4x2}"` — comment says "Set USER_GRID from argument" but no code actually sets USER_GRID from `$@`. The grid argument parsing is left to the AI to implement.

## .claude/skills/doey-broadcast/SKILL.md
- [MEDIUM] Line 13: `source "$RD/session.env"` — sources from `/tmp` (world-writable). Security concern.
  Suggested: Use grep/cut pattern for reading individual vars
- [LOW] Line 18: `MESSAGE="YOUR_MESSAGE_HERE"` — placeholder never replaced in the script. Relies on AI to substitute before running. Works as designed but fragile.

## .claude/skills/doey-clear/SKILL.md
- [LOW] Line 42: `_tv()` function uses safe grep/cut pattern — good. Consistent with security guidance.
- No significant issues found. Well-structured.

## .claude/skills/doey-delegate/SKILL.md
- [LOW] Line 40: Checks for `❯` to detect idle but `doey-research` (line 22) checks for `>` prompt. Inconsistent idle detection character.
  Current: `echo "$OUTPUT" | grep -q '❯'` (doey-delegate) vs prompt `>` check (doey-research)
  Suggested: Standardize idle detection across all skills

## .claude/skills/doey-dispatch/SKILL.md
- [MEDIUM] Lines 32-33: `source "${RUNTIME_DIR}/session.env"` and `source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"` in auto-scale block — sources from `/tmp`. Security concern.
  Suggested: Use grep/cut pattern
- [LOW] Line 31: `doey add 2>/dev/null` — calls the `doey` CLI command. If running inside a worktree R&D team, this could affect the live session (violates R&D safety rule).

## .claude/skills/doey-kill-all-sessions/SKILL.md
- [LOW] Line 29: `rm -rf /tmp/doey/*/` — destructive operation. Confirmation prompt is present (line 8), which is correct.
- No bash 3.2 issues found.

## .claude/skills/doey-kill-session/SKILL.md
- [MEDIUM] Line 12: `source "${RD}/session.env"` — sources from `/tmp`.
  Suggested: Use grep/cut for individual vars
- No other issues.

## .claude/skills/doey-kill-window/SKILL.md
- [LOW] Line 27: `_sv()` uses safe grep/cut — good pattern.
- [LOW] Line 71: `[ "$_ahead" -gt 0 ] 2>/dev/null` — the `2>/dev/null` on `[` is unusual but harmless (catches non-numeric comparison error if `_ahead` is empty, though `|| echo "0"` should prevent that).
- No significant issues.

## .claude/skills/doey-list-windows/SKILL.md
- No embedded bash code blocks — purely context injection and AI instructions. Clean.

## .claude/skills/doey-monitor/SKILL.md
- [LOW] Line 23: Uses `${DOEY_RUNTIME}` env var directly (not `tmux show-environment`). This works only if the on-session-start hook set it, but it's a session env var, not a shell env var.
  Current: `cat "${DOEY_RUNTIME}/status/${PANE_SAFE}.status"`
  Suggested: Use `$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)` for consistency

## .claude/skills/doey-purge/SKILL.md
- [MEDIUM] Lines 25-27: `source "${RUNTIME_DIR}/session.env"` and `source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"` — sources from `/tmp`.
- No bash 3.2 issues.

## .claude/skills/doey-reinstall/SKILL.md
- [MEDIUM] Line 9: `cd "$REPO_DIR" && git pull; bash "$REPO_DIR/install.sh"` — `git pull` uses `;` separator so `install.sh` runs even if `git pull` fails. The skill description says "warn but continue" which matches, but the code itself doesn't warn.
  Suggested: Add explicit warning: `git pull || echo "WARNING: git pull failed, installing from current state"`
- [LOW] Minimal skill, no bash 3.2 issues.

## .claude/skills/doey-reload/SKILL.md
- [MEDIUM] Line 12: `source "${RUNTIME_DIR}/session.env"` — sources from `/tmp`.
- [LOW] Line 14: `doey reload` — calls live doey CLI. Same R&D worktree safety concern as doey-dispatch.

## .claude/skills/doey-repair/SKILL.md
- [LOW] Line 52: Watchdog launch uses `--model opus` but CLAUDE.md says watchdogs should use `--model haiku`. Inconsistency.
  Current: `claude --dangerously-skip-permissions --model opus --name \"T${TEAM_W} Watchdog\"`
  Suggested: `--model haiku` (matching doey-clear, doey-add-window, doey-rd-team)

## .claude/skills/doey-research/SKILL.md
- [MEDIUM] Lines 24, 42, 82: `source "${RUNTIME_DIR}/session.env"` — sources from `/tmp` (3 times in one skill).
- [LOW] Line 22: Idle detection uses `>` prompt character, while other skills use `❯`. Inconsistent.
  Current: `check for > prompt`
  Suggested: Use `❯` like doey-dispatch and doey-delegate

## .claude/skills/doey-reserve/SKILL.md
- [LOW] Line 22: `ACTION="reserve"` is hardcoded to "reserve". The comment says parse args for `off`/`unreserve`, but the actual code always sets `ACTION="reserve"`. The AI must modify this before running.
  Suggested: Add actual arg parsing or make the template clearer

## .claude/skills/doey-simplify-everything/SKILL.md
- [MEDIUM] Lines 20, 93: `source "${RUNTIME_DIR}/session.env"` — sources from `/tmp`.
- No bash 3.2 issues.

## .claude/skills/doey-status/SKILL.md
- No embedded bash code blocks — purely context injection and AI instructions. Clean.

## .claude/skills/doey-stop/SKILL.md
- [MEDIUM] Lines 13, 15: `source "$RD/session.env"` and `source "$RD/team_${W}.env"` — sources from `/tmp`.
- No bash 3.2 issues.

## .claude/skills/doey-watchdog-compact/SKILL.md
- [MEDIUM] Lines 15, 17: `source "$RD/session.env"` and `source "$RD/team_${W}.env"` — sources from `/tmp`.
- No bash 3.2 issues.

## .claude/skills/doey-worktree/SKILL.md
- [LOW] Line 44: `_tv()` uses safe grep/cut — good pattern. This is the secure approach that other skills should follow.
- No bash 3.2 issues. Well-structured.

## .claude/skills/doey-rd-team/skill.md
- [HIGH] Filename is lowercase `skill.md` — may not be discoverable (see structural issues above).
- [MEDIUM] Line 25: `source "${RUNTIME_DIR}/session.env"` — sources from `/tmp`.
- [LOW] Line 128: R&D worker prompt says "20 Doey skills" — should be 21 (now includes doey-rd-team itself).
- [LOW] Line 131: R&D worker prompt says "13 hooks" — should be verified against actual hook count.

---

## Cross-Cutting Issues

### 1. Inconsistent `source` vs safe-read pattern [MEDIUM — 12 skills affected]
**Skills that `source` from `/tmp`:** doey-add-window, doey-broadcast, doey-dispatch, doey-kill-session, doey-purge, doey-rd-team, doey-reinstall, doey-reload, doey-research, doey-simplify-everything, doey-stop, doey-watchdog-compact.

**Skills using safe grep/cut:** doey-clear (`_tv()`), doey-kill-window (`_sv()`), doey-worktree (`_tv()`).

Since `/tmp` is world-writable, `source`-ing files from there is a security risk (arbitrary code execution). The safe pattern exists in 3 skills but isn't applied consistently.

### 2. Inconsistent idle detection character [LOW — 3 skills]
- `❯` (Unicode): doey-dispatch, doey-delegate, doey-clear
- `>` (ASCII): doey-research
- Both should use `❯` for consistency.

### 3. Skills that call `doey` CLI [LOW — 2 skills]
- doey-dispatch (line 31): `doey add`
- doey-reload (line 14): `doey reload`
These are unsafe if run from an R&D worktree team.

### 4. Watchdog model inconsistency [LOW — 1 skill]
- doey-repair uses `--model opus` for watchdog relaunch; all others use `--model haiku`.

### 5. Duplicate/overlapping functionality
- **doey-delegate vs doey-dispatch**: doey-delegate is a simplified version of doey-dispatch (skip readiness check, no kill/restart). doey-delegate explicitly references doey-dispatch's dispatch sequence. Not a bug — intentional layering.
- **doey-kill-session vs doey-kill-all-sessions**: Complementary (single vs all). No overlap issue.
- **doey-purge vs doey-simplify-everything**: Both audit+fix workflows but different scope (single team vs all teams). doey-purge focuses on "context rot", simplify on "cognitive load reduction". Some overlap but different enough.

---

## Summary

| Severity | Count | Description |
|----------|-------|-------------|
| HIGH | 2 | Orphan lowercase `skill.md` in doey-rd-team; orphan `SKILL.md` at skills root |
| MEDIUM | 13 | `source` from `/tmp` (12 instances across skills), doey-reinstall silent fail |
| LOW | 10 | Idle char inconsistency, placeholder code, model mismatch, stale counts |

### Priority Fixes
1. **Rename** `doey-rd-team/skill.md` → `SKILL.md`
2. **Delete** orphan `.claude/skills/SKILL.md`
3. **Standardize** `source` → safe grep/cut across all skills (security)
4. **Fix** doey-repair watchdog model: `opus` → `haiku`
5. **Standardize** idle detection to `❯` in doey-research
