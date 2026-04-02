---
name: infra
description: "Infrastructure — install scripts, CI/CD, config, and deployment"
grid: dynamic
workers: 2
type: local
manager_model: opus
worker_model: opus
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | Infra Lead | opus |
| 1 | worker | - | Install Worker | opus |
| 2 | worker | - | Config Worker | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | worker | manager | infra_ready |

## Team Briefing

Infrastructure team for Doey's install, config, and deployment pipeline.

**Team roles:**
- **Infra Lead (pane 0):** Coordinates infrastructure work. Ensures fresh-install invariant holds — every change must work after `curl | bash`
- **Install Worker (pane 1):** Owns `install.sh`, `web-install.sh`, and the install path. Ensures binaries, agents, hooks, and scripts are correctly installed to `~/.local/bin/`, `~/.claude/agents/`, etc.
- **Config Worker (pane 2):** Config hierarchy, CI/CD, deployment scripts, and project setup. Manages default configs, environment detection, and `doey doctor` checks

**Key files:** `install.sh`, `web-install.sh`, `tests/`, `.doey/config.sh`
**Constraint:** Must pass the end-user test — works after deleting all local state and running `./install.sh` fresh
**Tags:** infrastructure, install, config, ci, deploy
