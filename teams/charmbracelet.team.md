---
name: charmbracelet
description: "Charmbracelet team — builds perfect Bubble Tea TUIs for Doey with specialist Go, Charm, deploy, and UX roles"
grid: dynamic
workers: 4
type: local
manager_model: opus
worker_model: opus
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | Charm Lead | opus |
| 1 | worker | - | Go/Doey Expert | opus |
| 2 | worker | - | Charmbracelet Expert | opus |
| 3 | worker | - | Deployment Expert | opus |
| 4 | worker | - | TUI UX Designer | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | worker | manager | component_ready |

## Team Briefing

Charmbracelet team building perfect Go TUIs for the Doey system.

**Stack:** Go + Bubble Tea (TUI framework) + Lip Gloss (styling) + Huh (forms) + Glamour (markdown rendering) + Harmonica (animations)

**Team roles:**
- **Charm Lead (pane 0):** Coordinates the build. Owns architecture, component API design, and final integration. Reviews all worker output before merging
- **Go/Doey Expert (pane 1):** Writes idiomatic Go, deeply understands Doey's runtime architecture, hook system, IPC, task files, and session lifecycle. Ensures .go code integrates cleanly with Doey's shell infrastructure
- **Charmbracelet Expert (pane 2):** Knows Bubble Tea, Lip Gloss, Huh, Glamour, and the full Charm ecosystem. Familiar with best practices, example repos, component patterns, and library selection. The team's reference for "how to build this in Charm"
- **Deployment Expert (pane 3):** Owns the build/install/update pipeline. Ensures Go binaries compile for macOS (arm64/amd64), that install.sh handles binary updates, that the app is battle-tested (error handling, edge cases, graceful degradation). Makes sure updating Doey updates the Go dashboard for all users
- **TUI UX Designer (pane 4):** Terminal layout, responsive sizing across terminal dimensions, keyboard navigation, color theming, accessibility, visual hierarchy. Ensures the TUI feels polished and professional, not just functional

**Key files to study:**
- `tui/` — Go TUI source code (Bubble Tea app)
- `bin/doey-tui` — compiled TUI binary
- `shell/info-panel.sh` — bash info panel (what the TUI replaces)
- `shell/doey.sh` — launcher, runtime structure, how pane 0.0 is started
- `/tmp/doey/<project>/` — runtime dir with status files, team envs, tasks, messages
- `shell/pane-border-status.sh` — pane border styling (coordinate visual language)
- `shell/tmux-statusbar.sh` — status bar (coordinate color palette)

**Design principles:**
- Terminal-native beauty — no web pretensions, embrace the medium
- Responsive to terminal size (80col minimum, scales up beautifully)
- Fast startup (<200ms), low memory, no flicker
- Keyboard-first with discoverable shortcuts
- Live-updating from runtime files (watch/poll, not push)
- Graceful degradation — if a runtime file is missing, show placeholder, don't crash
- Binary must work on fresh install after `./install.sh`
