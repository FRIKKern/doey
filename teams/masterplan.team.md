---
name: masterplan
description: "Masterplan window — planner + live plan viewer + 4 workers"
grid: masterplan
workers: 4
type: local
manager_model: opus

panes:
  0: { role: planner, agent: doey-subtaskmaster, name: "Planner" }
  viewer: { role: viewer, script: masterplan-viewer.sh, name: "Plan" }
  1: { role: worker, name: "W1" }
  2: { role: worker, name: "W2" }
  3: { role: worker, name: "W3" }
  4: { role: worker, name: "W4" }
---

## Masterplan Team

Three-zone layout for plan-driven execution:

1. **Planning zone** (pane 0) — The Planner (Subtaskmaster) owns the masterplan. It breaks down the user's goal into phases, writes the plan to a shared `.md` file, delegates subtasks to workers, and validates their output.

2. **Viewer zone** (viewer pane) — A live terminal renderer (`masterplan-viewer.sh`) that watches the plan file and re-renders on every change. Gives the user and the Planner real-time visibility into the current plan state without switching panes.

3. **Worker zone** (panes 1-4) — Four workers that receive subtasks from the Planner. Each worker operates independently on its assigned files, reporting results back to the Planner on completion.
