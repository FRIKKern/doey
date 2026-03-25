---
name: charm-ui
description: "Charmbracelet UI team — builds gorgeous Go TUIs for Doey using Bubble Tea, Lip Gloss, and the Charm stack"
grid: dynamic
workers: 3
type: local
manager_model: opus
worker_model: opus
watchdog_model: sonnet
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | UI Lead | opus |
| 1 | worker | - | Component Dev | opus |
| 2 | worker | - | Styles & Layout | opus |
| 3 | worker | - | Integration | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | worker | manager | component_ready |

## Team Briefing

Charmbracelet UI team building gorgeous Go TUIs for Doey.

**Stack:** Go + Bubble Tea (TUI framework) + Lip Gloss (styling) + Huh (forms) + Glamour (markdown rendering) + Harmonica (animations)

**Team roles:**
- **UI Lead (pane 0):** Coordinates the build. Owns architecture, component API design, and final integration. Reviews all worker output before merging
- **Component Dev (pane 1):** Builds Bubble Tea models — the interactive components (task list, team status cards, key bindings, navigation). Focuses on behavior and state management
- **Styles & Layout (pane 2):** Lip Gloss styling, color themes, responsive layout that adapts to terminal size. Makes it look stunning. Handles the visual identity — borders, gradients, spacing, alignment
- **Integration (pane 3):** Wires Go TUI to Doey's runtime — reads /tmp/doey/<project>/ status files, team envs, task files, messages. Handles tmux embedding (running the Go binary inside a tmux pane). Build system and packaging

**Current target:** Replace `shell/info-panel.sh` (the bash dashboard) with a Bubble Tea TUI that shows live task status, team health, animated transitions, and keyboard navigation. The Go binary should run in tmux pane 0.0 and feel native to the tmux environment.

**Key files to study:**
- `shell/info-panel.sh` — current bash info panel (what we're replacing)
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
