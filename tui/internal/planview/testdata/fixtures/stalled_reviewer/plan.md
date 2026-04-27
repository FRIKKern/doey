---
plan_id: 1006
title: "Demo: Stalled reviewer"
status: under_review
skill: doey-masterplan
---

# Plan: Demo — Stalled reviewer

## Goal
Surface that the Critic pane is stalled so the user can decide whether
to nudge or kill the worker.

## Context
Architect has issued a verdict; Critic has not — and the heartbeat
sentinel for that pane is several minutes old. Phase 6 banners surface
this stall scenario.

## Phases

### Phase 1: Wait on Critic
**Status:** in-progress
- [ ] Receive Critic verdict
- [ ] Tally consensus
