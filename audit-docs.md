# Documentation Accuracy Audit — 2026-03-23

Cross-reference of all doc claims vs actual code. Previous audit at `docs/audit-docs.md` reviewed for staleness.

---

## Previous Audit (docs/audit-docs.md) — Staleness Check

Several findings from the prior audit have been **fixed** and the audit file is now stale:

- **[FIXED]** context-reference.md:51 — on-session-start.sh hook row now includes SESSION_NAME, PROJECT_DIR, PROJECT_NAME.
- **[FIXED]** context-reference.md:97 — "Set by hooks" env var list now includes all 9 vars.
- **[FIXED]** context-reference.md:106 — Session Manager IS now in CLI Launch Flags table.
- **[FIXED]** context-reference.md:71 — Manager skills now includes /doey-rd-team and /unknown-task.
- **[FIXED]** context-reference.md:112 — The stale "Note" about `_launch_team_manager` has been removed.

The audit file at `docs/audit-docs.md` still claims these are open issues — it should be updated or removed.

---

## Still-Open Findings from Previous Audit

[HIGH] docs/audit-docs.md — Stale audit file claims 5+ issues that have been fixed
  Current: docs/audit-docs.md lists findings as open that are now resolved
  Suggested: Update or delete docs/audit-docs.md to reflect current state

[HIGH] context-reference.md:155 — `status/pane_map` documents a file that is never written
  Current: `status/pane_map` | Pane ID-to-index cache
  Code: Only referenced in a purge cleanup (doey.sh:852), never written anywhere
  Suggested: Remove entry or mark as deprecated

---

## New Findings

### README.md

[LOW] README.md:62 — `doey 4x3` listed as "Static grid layout" in CLI table
  Current: `doey 4x3` | Static grid layout
  Actual: Any NxM pattern works (doey.sh:3057 matches `[0-9]*x[0-9]*`). Not a distinct command — just sets the grid variable. "Static grid layout" is misleading for what is really "any grid size".
  Suggested: Change to `doey NxM` | Launch with specific grid (e.g., 4x3, 3x2)

[LOW] README.md:53 — `doey add` / `remove` described only as "Add/remove worker columns"
  Current: `doey add` / `remove` | Add/remove worker columns
  Actual: `doey remove` also unregisters projects when given a name (doey.sh:3008-3027). Dual purpose not documented.
  Suggested: Split into two rows or note dual purpose

[LOW] README.md:86-88 — Slash commands list missing `/unknown-task`
  Current: R&D section lists `/doey-rd-team` but `unknown-task` is absent from all categories
  Actual: 23 skill directories exist; README lists 22
  Suggested: Add `/unknown-task` to the Tasks or Lifecycle category

### CLAUDE.md

[LOW] CLAUDE.md:5 — "Static grid default: 3x2 (6 workers)"
  Current: Claims 3x2 = 6 workers
  Actual: 3x2 grid = 3 columns × 2 rows = 6 panes. But pane 0 is Manager, so actual workers = 5.
  Code: doey.sh `_launch_session_core()` places Manager in pane 0, workers fill the rest
  Suggested: Clarify "3x2 (5 workers + Manager)" or "6 panes"

### context-reference.md

[MEDIUM] context-reference.md:155 — `status/pane_map` still listed as runtime file
  (Carried forward from previous audit — still not fixed)
  Current: Listed in Runtime State table as "Pane ID-to-index cache"
  Actual: Never written by any code. Only referenced in purge cleanup (doey.sh:852).
  Suggested: Remove from table

[LOW] context-reference.md:76 — Worker skills list says "/doey-status, /doey-reserve, /doey-stop"
  Actual: Skills are project-level files — any Claude instance can invoke any skill. The "Worker skills" designation is a convention, not enforcement. No mechanism restricts Workers from using Manager skills.
  Suggested: Add a note that skill access is by convention, not enforced

### docs/linode-setup.md

[LOW] linode-setup.md:155 — References `./doey-linode-setup.sh` which doesn't exist as a file
  Current: "Usage: `ANTHROPIC_KEY="sk-ant-..." ./doey-linode-setup.sh`"
  Actual: The script is presented inline in the doc, not shipped as a file
  Suggested: Change to "Save the script below as `doey-linode-setup.sh`" or ship the file

### docs/test-worktree.md

[LOW] test-worktree.md:11 — Test 1 assumes window 4 is the worktree team
  Current: "5 windows" and "Window 4 has [wt]"
  Actual: Depends on INITIAL_TEAMS and INITIAL_WORKTREE_TEAMS constants in launch_session_dynamic()
  Suggested: Note the dependency on default constants, or derive window number dynamically

---

## Verified Accurate (spot-checked)

- CLAUDE.md role table matches code (on-pre-tool-use.sh confirms Manager=full, Watchdog=restricted, Worker=restricted)
- CLAUDE.md hook table matches actual files in .claude/hooks/ (12 files, all listed)
- CLAUDE.md key directories table matches actual directory structure
- CLAUDE.md conventions (bash 3.2, set -euo pipefail, session naming) match code
- context-reference.md agent model/color/memory table matches agent frontmatter
- context-reference.md CLI launch flags match actual launch commands in doey.sh
- context-reference.md startup timing (8s briefing, ~15s workers) confirmed in code
- context-reference.md bell-action/visual-bell settings confirmed (doey.sh:754-755)
- context-reference.md PANE_SAFE escaping pattern confirmed in hooks
- README.md install commands reference valid files (web-install.sh exists, install.sh exists)
- README.md CLI commands (doctor, test, update, uninstall, etc.) all have matching case entries
- Default grid is "dynamic" (doey.sh:2919) — matches CLAUDE.md claim
- Platform docs (linux-server.md, windows-wsl2.md, linode-setup.md) install instructions are accurate

---

## Summary

| Severity | Count | Location |
|----------|-------|----------|
| HIGH     | 2     | docs/audit-docs.md (stale), context-reference.md (pane_map) |
| MEDIUM   | 1     | context-reference.md (pane_map duplicate of HIGH) |
| LOW      | 7     | README.md (3), CLAUDE.md (1), context-reference.md (1), linode-setup.md (1), test-worktree.md (1) |

**Priority fixes:**
1. Update or remove stale `docs/audit-docs.md` — it reports 5+ issues as open that have been fixed, creating confusion for future audits.
2. Remove `status/pane_map` from context-reference.md Runtime State table — phantom entry, never written.
3. Fix CLAUDE.md "3x2 (6 workers)" — should be "3x2 (5 workers)" since pane 0 is Manager.
