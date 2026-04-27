# Side-by-Side Planning Validation

Sign-off note for masterplan-20260426-203854 (Phase 9 close). The Plan
pane (`doey-masterplan-tui`) is meant to feel native next to the two
nearest comparators — Claude Code's built-in plan/Todo view and
Cursor's planning surface. This document captures the manual eyeball
test the masterplan owner runs before the close.

## Procedure

Run all three side-by-side on a 120-column terminal at truecolor:

1. **Doey Plan pane (fixture mode).**
   ```sh
   doey-masterplan-tui --demo consensus
   ```
   Use `--demo draft`, `--demo escalated`, `--demo reviewers`,
   `--demo revisions_needed`, `--demo stalled_reviewer`, and
   `--demo under_review` to step through every state. Each fixture is
   the static directory under
   `tui/internal/planview/testdata/fixtures/<scenario>` so the render
   is deterministic.

2. **Claude Code native planning.** Trigger a `/plan` flow inside
   Claude Code (or the in-line Todo list rendering) on a comparable
   multi-step task and let the agent draw its checklist.

3. **Cursor planning view.** Open Cursor on the same task and watch
   the agent's plan/decision panel render.

## What to compare

Walk through each pair and grade Doey on:

- **Information density.** Does the Plan pane show roughly as much
  per square inch as the comparators, without crowding? Phase + step
  hierarchy, consensus pill, reviewer cards, and the worker activity
  ticker all need to coexist on a single 120-col render.
- **Overall elegance.** Does the layered render look intentional,
  not like a debug dump? Borders, padding, and section headers should
  feel like a native TUI rather than a tail of a log.
- **Colour use.** Doey owns its palette — see the consensus pill
  states (CONSENSUS / UNDER_REVIEW / ESCALATED) and the reviewer card
  badges (READY / BUSY / FINISHED). Compare against Claude's and
  Cursor's accent strategies; we should be in the same league, not
  noisier.
- **Mouse passthrough.** Click on a phase header in Doey under tmux
  and confirm the bubblezone hit registers (Phase 8 wiring). The
  comparators may not expose this; the bar is "no regression vs.
  keyboard-only flows."
- **Determinism under width changes.** Resize to 80 / 120 / 200
  columns. The Plan pane has explicit width modes
  (`ClassifyWidth`); the comparators degrade ad hoc. Doey should
  remain readable across all three.

## Sign-off

Record one sentence per fixture in the masterplan close note. The
acceptance bar is "matches or beats the comparators on three of the
five dimensions, never strictly worse on any." If a fixture fails the
bar, file a follow-up task; do not regenerate goldens to mask a
visible regression.

## Related

- Render-golden harness: `tui/internal/planview/golden_test.go`
- CI gate: `make smoke-render-golden`
- Opt-in matrix: `make test-render-matrix`
- Refresh path: `make refresh-render-goldens`
- Contract: [`docs/plan-pane-contract.md`](plan-pane-contract.md)
