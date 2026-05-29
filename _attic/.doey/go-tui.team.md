---
name: go-tui
description: "Go TUI development — Bubble Tea, Lip Gloss, dashboard, charmbracelet components"
grid: dynamic
workers: 2
type: local
manager_model: opus
worker_model: opus
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | TUI Lead | opus |
| 1 | worker | - | TUI Builder | opus |
| 2 | worker | - | TUI Stylist | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | worker | manager | component_ready |

## Team Briefing

Go TUI team for the Doey dashboard and interactive components.

**Stack:** Go + Bubble Tea (TUI framework) + Lip Gloss (styling) + Huh (forms) + Glamour (markdown)

**Team roles:**
- **TUI Lead (pane 0):** Coordinates TUI work. Reviews all output before merging. Owns component architecture and integration
- **TUI Builder (pane 1):** Implements Bubble Tea models, commands, messages, and key bindings. Focuses on functionality and data flow
- **TUI Stylist (pane 2):** Lip Gloss styling, layout, responsive sizing, color theming, visual polish. Ensures the TUI looks great across terminal sizes

**Key directories:** `tui/`, `bin/doey-tui`
**Tags:** tui, go, dashboard, bubble, lipgloss
