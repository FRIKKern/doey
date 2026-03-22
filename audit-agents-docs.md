# Agent & Documentation Audit

Generated: 2026-03-22

## agents/doey-manager.md

- [OK] Frontmatter complete: name, model (`opus`), color (`green`), memory (`user`), description all present.
- [OK] Model choice `opus` is appropriate for coordination/planning role.
- [OK] Setup block correctly sources `session.env` and `team_<W>.env`.
- [LOW] Line 13 — "Watchdog is in window 0 — never manage it" is slightly misleading. The Watchdog pane is in window 0 (dashboard), but it monitors a specific team window. The instruction not to manage it is correct, but phrasing implies the Watchdog belongs to window 0's team.

## agents/doey-session-manager.md

- [OK] Frontmatter complete: name, model (`opus`), color (`#FF6B35`), memory (`user`), description all present.
- [OK] Model choice `opus` appropriate for top-level orchestration.
- [LOW] CLI launch at `doey.sh:312` does not pass `--model opus` — relies on agent frontmatter. This works, but is inconsistent with the Manager launch path which explicitly passes `--model opus` (at `doey.sh:1659`).

## agents/doey-watchdog.md

- [OK] Frontmatter complete: name, model (`haiku`), color (`yellow`), memory (`none`), description all present.
- [OK] Model choice `haiku` is appropriate and cost-efficient for lightweight monitoring.
- [OK] `memory: none` is correct — watchdog is stateless across cycles.
- [OK] Setup block and monitoring loop structure are sound.

## agents/test-driver.md

- [OK] Frontmatter complete: name, model (`opus`), color (`red`), memory (`none`), description all present.
- [MEDIUM] Line 46 — Anomaly detection table lists Manager using `Read` on project files as HIGH severity ("Manager coding directly"). However, the Manager legitimately uses `Read` for monitoring and research. Only `Edit`/`Write` should be HIGH; `Read` alone is not an anomaly of "coding directly."

## docs/context-reference.md

- [HIGH] Line 25 — Agent table lists Watchdog model as `opus`. Actual agent frontmatter is `model: haiku`, and CLI launches with `--model haiku` (`doey.sh:1678`, `doey.sh:2440`). Stale documentation.
  - Current: `| model | opus | opus | opus |`
  - Should be: `| model | opus | opus | haiku |`

- [HIGH] Line 109 — CLI launch flags table says Watchdog uses `--model opus`. Actual code uses `--model haiku`.
  - Current: `| Watchdog | claude --dangerously-skip-permissions --model opus ...`
  - Should be: `| Watchdog | claude --dangerously-skip-permissions --model haiku ...`

- [MEDIUM] Lines 59-60 — Lists `stop-notify-manager.sh` and `stop-notify-session-manager.sh` as separate hook files. These files do not exist on disk. Their functionality is merged into the unified `stop-notify.sh`, which handles Worker-to-Manager, Manager-to-Session-Manager, and Session-Manager-to-desktop notification in a single file. The two ghost entries should be removed and replaced with a note clarifying `stop-notify.sh` covers all three notification paths.

- [MEDIUM] Line 73 — Lists `/doey-team` as a Manager skill ("layout overview"). No directory `.claude/skills/doey-team/` exists. Either the skill was removed, never created, or renamed.

- [MEDIUM] Line 109 — CLI launch flags table omits Session Manager entirely. Session Manager is launched at `doey.sh:312` with `claude --dangerously-skip-permissions --agent doey-session-manager` (no `--model` flag). Should be documented.

- [MEDIUM] Skills list (line 73) does not include `/doey-rd-team` (recently added). Actual skill count on disk: 22 directories (21 with `SKILL.md` + 1 `doey-rd-team` with lowercase `skill.md`).

- [LOW] `_launch_team_manager()` at `doey.sh:2425` does not pass `--model opus`, while the initial launch path at `doey.sh:1659` does. This means dynamically added teams rely on agent frontmatter for model selection (which works, but is inconsistent). This is a code-level issue surfaced by the doc's CLI launch table.

## docs/linode-setup.md

- [OK] Well-structured and comprehensive. No stale code references found.
- [OK] Security guidance about API keys in `~/.bashrc` is appropriately flagged.

## docs/linux-server.md

- [OK] Concise and accurate. Cross-references linode-setup.md correctly.
- [OK] Troubleshooting table covers common issues.
- [LOW] Line 84 — mentions "macOS notifications: `osascript` calls silently skipped on Linux." This is correct behavior, but `common.sh:send_notification()` actually has a `notify-send` fallback for Linux and a `powershell.exe` fallback for WSL. The troubleshooting note could be more precise.

## docs/test-worktree.md

- [OK] Comprehensive worktree test plan. Commands reference correct runtime paths and variables.
- [OK] Edge case tests (busy team, already isolated, --back on normal) are well-defined.

## docs/windows-wsl2.md

- [OK] Short and accurate. Correctly notes WSL2 path performance difference.
- [OK] References `web-install.sh` for installation — file exists in repo root.

## CLAUDE.md (project root)

- [MEDIUM] Hooks table (lines 78-79) lists `stop-notify-manager.sh` and `stop-notify-session-manager.sh` as separate hook files. These do not exist on disk. Their functionality is in the unified `stop-notify.sh`. The table should remove these two ghost entries.

- [LOW] Hooks table describes `stop-notify.sh` as "Desktop notification when Session Manager stops." This is incomplete — the actual `stop-notify.sh` also handles Worker-to-Manager notifications (send-keys) and Manager-to-Session-Manager notifications (send-keys). The description should be "Unified stop notification: Worker notifies Manager, Manager notifies Session Manager, Session Manager triggers desktop notification."

- [OK] All other hook entries in the table match existing files and their descriptions are accurate.
- [OK] Architecture table, tool restrictions table, key directories table, conventions, and testing instructions are all accurate against current code.

## Summary

| Severity | Count |
|----------|-------|
| HIGH     | 2     |
| MEDIUM   | 6     |
| LOW      | 4     |

### Priority Fixes

1. **context-reference.md**: Change Watchdog model from `opus` to `haiku` in two locations (agent table line 25, CLI table line 109).
2. **CLAUDE.md + context-reference.md**: Remove ghost hooks `stop-notify-manager.sh` and `stop-notify-session-manager.sh` from hook tables. Update `stop-notify.sh` description to reflect its unified role.
3. **context-reference.md**: Remove nonexistent `/doey-team` skill; add `/doey-rd-team`.
4. **context-reference.md**: Add Session Manager to CLI launch flags table.
5. **test-driver.md**: Refine anomaly detection — `Read` by Manager is not "coding directly."
6. **doey.sh** (code bug): `_launch_team_manager()` missing `--model opus` flag, causing inconsistency between initial and dynamic team launches.
