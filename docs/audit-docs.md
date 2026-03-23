# Documentation Audit — 2026-03-23

Cross-reference of claims in docs vs. actual code in shell/doey.sh, .claude/hooks/, .claude/skills/, agents/.

---

## docs/context-reference.md

### HIGH

**[HIGH] context-reference.md:51 — on-session-start.sh hook entry omits 3 exported env vars**
The Hooks table row for `on-session-start.sh` lists only:
> Sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX, DOEY_TEAM_WINDOW, DOEY_TEAM_DIR, DOEY_RUNTIME

But the hook also exports `SESSION_NAME`, `PROJECT_DIR`, and `PROJECT_NAME` (on-session-start.sh lines 99-101, via CLAUDE_ENV_FILE). These are critical vars used by workers.
Same gap appears in the "Set by hooks" env var list (context-reference.md:97).

**[HIGH] context-reference.md:154 — `status/pane_map` documents a file that is never written**
The Runtime State table lists:
> `status/pane_map` | Pane ID-to-index cache

This file appears only in a purge cleanup loop (doey.sh:852) but is never written by any hook, script, or shell function in the codebase. It's a phantom entry — the feature it describes either was removed or was planned but never built.

### MEDIUM

**[MEDIUM] context-reference.md:112 — Stale "Note" about _launch_team_manager already fixed**
The Note reads:
> `_launch_team_manager()` in `doey.sh` should pass `--model opus` explicitly…

The function at doey.sh:2482 already passes `--model opus`. The note was written as a recommendation/TODO before the fix; it now reads as if a bug exists that doesn't.

**[MEDIUM] context-reference.md:97 — "Set by hooks" env var list incomplete**
Lists: `DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX, DOEY_TEAM_WINDOW, DOEY_TEAM_DIR, DOEY_RUNTIME`
Missing: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME` — all three are written by on-session-start.sh into CLAUDE_ENV_FILE and exported to Claude instances.

### LOW

**[LOW] context-reference.md:103-110 — Session Manager launch command absent from CLI Launch Flags table**
The table shows Manager, Watchdog, and Worker launch commands but omits Session Manager.
Actual command (doey.sh:319):
```
claude --dangerously-skip-permissions --agent doey-session-manager
```
Note: unlike Manager and Watchdog, Session Manager does NOT receive `--model opus` — it relies on the agent frontmatter default (`model: opus` in doey-session-manager.md).

**[LOW] context-reference.md:71 — Manager skills list missing /doey-rd-team and /unknown-task**
The Manager skills list does not include `/doey-rd-team` or `/unknown-task`, both of which exist in `.claude/skills/` and are usable from the Manager pane.

---

## CLAUDE.md

### MEDIUM

**[MEDIUM] CLAUDE.md:51 — on-session-start.sh description incomplete**
The Hooks table row says:
> Sets DOEY_* env vars (ROLE, PANE_INDEX, WINDOW_INDEX, TEAM_WINDOW, TEAM_DIR, RUNTIME) plus SESSION_NAME, PROJECT_DIR, PROJECT_NAME

This is correct and more accurate than context-reference.md — but note the inconsistency between documents (CLAUDE.md is right, context-reference.md is wrong on this point).

### LOW

**[LOW] CLAUDE.md (via doey-rd-team skill:133) — Hook count incorrect**
The doey-rd-team skill system prompt says "13 hooks" but `ls .claude/hooks/` yields 12 files:
common.sh, on-pre-compact.sh, on-pre-tool-use.sh, on-prompt-submit.sh, on-session-start.sh, post-tool-lint.sh, session-manager-wait.sh, stop-notify.sh, stop-results.sh, stop-status.sh, watchdog-scan.sh, watchdog-wait.sh.
No 13th hook exists.

---

## README.md

### LOW

**[LOW] README.md:62 — CLI commands table mentions `doey 4x3` but no other grid examples**
The Troubleshooting table (README.md:96) recommends `doey 3x2` for small terminals, but the CLI Commands table lists only `doey 4x3`. Both are valid (any NxM pattern works via `[0-9]*x[0-9]*)` case in doey.sh). The inconsistency is minor but may confuse readers about which grid sizes are "supported."

**[LOW] README.md:83-88 — Slash commands section omits /doey-rd-team and /unknown-task**
The `<details>` block listing slash commands does not include `/doey-rd-team` (spawns R&D team) or `/unknown-task` (fallback). Both exist in `.claude/skills/` and are accessible.

**[LOW] README.md:55 — `doey remove` described as "Add/remove worker columns" only**
The `doey remove` command does double duty: `doey remove <N>` removes a worker column, but `doey remove <project-name>` unregisters a project (remove_project function). The README only documents the worker column removal meaning.

---

## docs/linode-setup.md

### LOW

**[LOW] linode-setup.md:153-209 — Automation script references non-existent file**
The "Full Automation Script (Steps 1–5)" section describes running `./doey-linode-setup.sh` but no such file exists in the repo. The script body is presented inline as documentation, not as a shipped file. This may confuse users expecting to find and run the script.

---

## docs/test-worktree.md

### LOW

**[LOW] test-worktree.md:11-24 — Test 1 assumes specific window numbering tied to INITIAL_TEAMS constant**
Test 1 states "5 windows" and "team 4 has [wt]". This is correct given `INITIAL_TEAMS=2` and `INITIAL_WORKTREE_TEAMS=2` (windows 1–2 normal, 3–4 worktree, plus dashboard = 5). However, these constants are hardcoded in `launch_session_dynamic()` and could change. The test guide doesn't note this dependency, which would break the tests if the defaults change.

---

## docs/linux-server.md, docs/windows-wsl2.md

No issues found. File paths, commands, and feature descriptions are accurate and consistent with the codebase.

---

## Summary

| Severity | Count | Location |
|----------|-------|----------|
| HIGH     | 2     | context-reference.md |
| MEDIUM   | 2     | context-reference.md |
| LOW      | 7     | context-reference.md (2), CLAUDE.md (1), README.md (3), linode-setup.md (1), test-worktree.md (1) |

**Most impactful fixes needed:**
1. Add `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME` to both the Hooks table row and "Set by hooks" env var list in context-reference.md.
2. Remove or update the stale `_launch_team_manager` Note — the fix is already in.
3. Remove or mark `status/pane_map` as deprecated/unused in the Runtime State table.
