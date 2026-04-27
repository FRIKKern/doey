---
plan_id: 7044
title: "Demo: Reviewer cards"
status: under_review
skill: doey-masterplan
---

# Plan: Demo — Reviewer cards

## Goal
Showcase the four-state reviewer card matrix landed in Phase 7 of the
plan-pane masterplan. The Architect card renders an APPROVE state and
the Critic card renders a REVISE state — together they exercise two of
the four states. Goldens pin the remaining two states (no_file,
no_verdict) for both reviewers.

## Context
Use this fixture with `./tui/doey-masterplan-tui --demo reviewers` to
visually verify the card layout, the state-driven border colours, the
focus ring, and the glamour-rendered preview body when a card is
focused (press `tab` to move focus into the card row, then `enter` to
open the full-screen overlay).

## Deliverables
- Architect card showing APPROVE
- Critic card showing REVISE
- Working `tab` / `shift+tab` focus rotation
- Working `enter` overlay open / `esc` close

## Risks
- Glamour rendering behaviour drifts on a dependency bump — covered by
  the reviewer-card golden harness.

## Success Criteria
- Both cards render at 80/120/200-col widths
- `enter` on a focused card opens an overlay; `esc` closes it
- Goldens for all four states stay byte-identical across runs

## Phases

### Phase 1: Prep fixtures
**Status:** done
- [x] Stage verdict files
- [x] Stage status files
- [x] Stage team.env

### Phase 2: Render reviewer row
**Status:** in_progress
- [x] Wire DiscoverReviewers
- [x] Render Architect card
- [ ] Render Critic card
- [ ] Add focus + overlay
