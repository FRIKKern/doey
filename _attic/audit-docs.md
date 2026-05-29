# Documentation Audit Report

**Date:** 2026-03-23
**Auditor:** Worker 4 (docs-audit_0323)
**Scope:** README.md, CLAUDE.md, docs/* — cross-referenced against shell/doey.sh, agents/, .claude/hooks/, .claude/skills/

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 2 |
| MEDIUM | 10 |
| LOW | 5 |
| **Total** | **17** |

---

## CLAUDE.md

**[MEDIUM] CLAUDE.md — doey.sh line count stale in R&D system prompt**
The R&D worker system prompt says "shell/doey.sh — Main script (1455 lines)" but actual count is **3081 lines**. CLAUDE.md itself doesn't state a line count, but the R&D agent definition does.
  Suggested: Update or remove line count from the agent prompt template.

**[MEDIUM] CLAUDE.md:60 — shell/pane-border-status.sh and shell/tmux-statusbar.sh listed but not explained**
The Important Files section lists these two shell scripts with brief labels "(pane borders)" and "(status bar)" but no further documentation exists for them in context-reference.md.
  Suggested: Add brief descriptions to context-reference.md under a "Shell Utilities" section.

**[LOW] CLAUDE.md:68 — on-prompt-submit.sh description says "collapsed column restore"**
Accurate but context-reference.md:52 also says the same. Both are now correct. No action needed — this was previously inaccurate but has been fixed.

---

## README.md

**[MEDIUM] README.md:62 — `doey 4x3` as example CLI command is misleading**
The CLI table shows `doey 4x3` as "Static grid layout" but the default static grid is `3x2` (doey.sh:2811). Using `4x3` as the example may confuse users about the default.
  Current: `doey 4x3    Static grid layout`
  Suggested: `doey NxM    Static grid layout (e.g., 3x2, 4x3)`

**[MEDIUM] README.md:63 — No indication that `dynamic` is the default**
`doey dynamic` is listed as a CLI command but there's no mention that dynamic grid is the default launch mode. A user running bare `doey` wouldn't know they're already in dynamic mode.
  Suggested: Add "(default)" annotation: `doey dynamic  Dynamic grid (default)`

**[LOW] README.md:83-89 — Slash commands list missing `/doey-rd-team` and `/unknown-task`**
The grouped slash commands section omits 2 existing skills: `/doey-rd-team` and `/unknown-task`.
  Suggested: Add `/doey-rd-team` under Infra.

**[LOW] README.md:96 — Troubleshooting suggests `doey 3x2` but CLI table shows `doey 4x3`**
Inconsistent grid examples — troubleshooting says "Terminal too small → Use `doey 3x2`" but the CLI table example is `4x3`.
  Suggested: Use consistent grid example throughout.

---

## docs/context-reference.md

**[HIGH] context-reference.md:10 — Skills row says "Manager (+ 2 for Workers)" but workers have 3 skills**
Line 10 says "Manager (+ 2 for Workers)" in the precedence table. Line 76 lists 3 worker skills: `/doey-status`, `/doey-reserve`, `/doey-stop`.
  Current: `Manager (+ 2 for Workers)`
  Suggested: `Manager (+ 3 for Workers)`

**[HIGH] context-reference.md:106-108 — Taskmaster missing from CLI Launch Flags table**
The table documents Manager, Watchdog, and Workers but omits the Taskmaster. The actual launch command (doey.sh:312) is:
```
claude --dangerously-skip-permissions --agent doey-taskmaster
```
Notably, it does NOT pass `--model opus` or `--name` — the model comes from agent frontmatter only.
  Suggested: Add a Taskmaster row:
  `| Taskmaster | claude --dangerously-skip-permissions --agent doey-taskmaster |`

**[MEDIUM] context-reference.md:71-76 — Two skills undocumented**
`/doey-rd-team` and `/unknown-task` exist as skill directories but are not listed under any role.
  Suggested: Add `/doey-rd-team` to Manager or Taskmaster skills. Document `/unknown-task` as a fallback skill.

**[MEDIUM] context-reference.md:112 — Note about `_launch_team_manager()` passing `--model opus` is outdated**
The note reads as a TODO: "_launch_team_manager() in doey.sh should pass --model opus explicitly". The code already does this (doey.sh:1671):
```
claude --dangerously-skip-permissions --model opus --name "T${tw} Subtaskmaster" --agent "$mgr_agent"
```
  Suggested: Remove the note or reword to confirm it was implemented.

**[MEDIUM] context-reference.md:132 — Startup timing likely stale**
Claims "Manager briefing 8s; workers ready ~15s". Commit `ed1f877` ("10x faster spawn — batch boot, parallel windows, reduced sleeps") likely invalidated these timings.
  Suggested: Re-measure and update, or remove specific numbers.

**[MEDIUM] context-reference.md:93 — session.env variable annotations incomplete**
`ROWS`, `MAX_WORKERS`, `CURRENT_COLS` are annotated as "(dynamic only)" and `TOTAL_PANES` as "(static only)" — this is correct. However, `WDG_SLOT_1..WDG_SLOT_6` and `TASKMASTER_PANE` are listed without noting that the number of WDG_SLOT entries varies (1 per team, up to 6).
  Suggested: Note `WDG_SLOT_1..WDG_SLOT_N` where N = number of team windows (max 6).

**[MEDIUM] context-reference.md:162 — Status values may be incomplete**
Lists: READY, BUSY, BOOTING, FINISHED, RESERVED. Watchdog-scan.sh detects additional states internally (IDLE, WORKING, CHANGED, UNCHANGED, CRASHED, STUCK, LOGGED_OUT, UNKNOWN). The doc distinguishes "Status values" (file-based) from "Watchdog anomaly types" but doesn't document all watchdog-detected states.
  Suggested: Add a note clarifying that watchdog internally tracks more granular states beyond the file-based status values.

**[MEDIUM] context-reference.md:164 — Watchdog anomaly types listed but not explained**
Lists "PROMPT_STUCK, WRONG_MODE, QUEUED_INPUT" without descriptions.
  Suggested: Add brief descriptions (e.g., PROMPT_STUCK = worker at prompt for too long, WRONG_MODE = wrong permission mode detected, QUEUED_INPUT = unsent input in pane).

---

## docs/linux-server.md

**[MEDIUM] linux-server.md:44 — systemd PATH uses wrong fnm directory**
The systemd unit has:
```
Environment=PATH=%h/.fnm/aliases/default/bin:...
```
But fnm installs to `~/.local/share/fnm/` (as shown in linode-setup.md:77 and the fnm installer default).
  Suggested: Change to `%h/.local/share/fnm/aliases/default/bin`

**[LOW] linux-server.md — No `doey doctor` as post-install verification**
The guide walks through manual setup but doesn't mention `doey doctor` as a verification step, even though README.md documents it and linode-setup.md uses it.
  Suggested: Add `doey doctor` after install.sh.

---

## docs/linode-setup.md

**[LOW] linode-setup.md:321-323 — Golden image cleanup is aggressive**
The cleanup script removes all directories with `.git` in home:
```bash
ls ~/ | grep -v doey | while read dir; do [ -d "$HOME/$dir/.git" ] && rm -rf "$HOME/$dir"; done
```
No warning about data loss.
  Suggested: Add a warning comment that this removes all git repos except doey.

No other issues found — the guide is comprehensive and internally consistent.

---

## docs/windows-wsl2.md

No issues found. Brief, accurate, links correctly to README.

---

## docs/test-worktree.md

No issues found. Test procedures reference correct paths and commands. Internally consistent.

---

## What's Accurate

- All documented file paths exist (agents/, .claude/hooks/, .claude/skills/, shell/, docs/)
- All 12 documented hook files exist and match their described purposes
- All 4 agent definitions match documented frontmatter (model, color, memory)
- All CLI commands in README.md correspond to implemented subcommands in doey.sh
- Architecture table (roles, panes) is accurate
- Tool restriction descriptions match on-pre-tool-use.sh logic
- Runtime state paths and file naming conventions are accurate
- Convention rules (bash 3.2 compat, naming, exit codes) are correct
- Testing Changes table is accurate
- Environment variable documentation is largely correct
- Key functions listed in CLAUDE.md all exist in doey.sh

---

## Top Priority Fixes

1. **Worker skill count** — docs say 2, actual is 3 (`/doey-status`, `/doey-reserve`, `/doey-stop`)
2. **Taskmaster CLI flags** — undocumented in launch flags table
3. **Outdated `_launch_team_manager` TODO note** — already resolved in code
4. **Startup timing** — likely invalidated by performance optimization commit
5. **fnm PATH in systemd** — wrong directory in linux-server.md
