---
name: shell
description: "Shell scripts, hooks, skills, and bash utilities"
grid: dynamic
workers: 2
type: local
manager_model: opus
worker_model: opus
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | Shell Lead | opus |
| 1 | worker | - | Script Worker | opus |
| 2 | worker | - | Hook Worker | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | worker | manager | script_ready |

## Team Briefing

Shell team for Doey's bash infrastructure — scripts, hooks, and skills.

**Team roles:**
- **Shell Lead (pane 0):** Coordinates shell work. Reviews for bash 3.2 compatibility, correctness, and adherence to Doey conventions
- **Script Worker (pane 1):** Shell scripts in `shell/` — doey.sh, info-panel.sh, pane-border-status.sh, tmux-statusbar.sh, and utility scripts
- **Hook Worker (pane 2):** Hook scripts in `.claude/hooks/` and skill definitions in `.claude/skills/`. Ensures hook exit codes, IPC, and event flow are correct

**Key directories:** `shell/`, `.claude/hooks/`, `.claude/skills/`
**Constraints:** All scripts must use `set -euo pipefail`, be bash 3.2 compatible, and pass `tests/test-bash-compat.sh`
**Tags:** shell, hooks, skills, bash, scripts
