---
plan_id: 1004
title: "Demo: Consensus reached"
status: consensus
skill: doey-masterplan
---

# Plan: Demo — Consensus reached

## Goal
Ship the live plan view with watcher plumbing, layered renderer, and
fixture-backed demo mode.

## Context
Architect and Critic have both approved this plan. The Send-to-Tasks
gate is open and the user can dispatch the phases into the task system.

## Deliverables
- `tui/internal/planview/` package
- Six fixture scenarios
- `docs/plan-pane-contract.md`
- `shell/check-plan-pane-contract.sh`

## Risks
- Fsnotify watch-budget exhaustion under heavy sessions
- Editor rename-on-save breaking the watcher

## Success Criteria
- Live latency under 200 ms end to end
- Idle CPU under 1% over a 60-second quiescent run
- All six fixture scenarios render at 80/120/200-col widths

## Phases

### Phase 1: Architecture decisions
**Status:** done
- [x] Pin Bubbletea v2
- [x] Settle on bubblezone
- [x] Decide Source interface shape

### Phase 2: Live data plumbing
**Status:** done
- [x] fsnotify watcher
- [x] Atomic-rename rendezvous
- [x] Self-write suppression
- [x] Idle-CPU acceptance test

### Phase 3: Path and verdict unification
**Status:** done
- [x] Honour --runtime-dir / --team-window / --goal
- [x] Standalone fallback UI
- [x] Verdict reader at planview/verdict.go

### Phase 4: Demo mode and fixtures
**Status:** in-progress
- [x] Source/Demo skeleton
- [x] Six fixture scenarios
- [ ] plan-pane-contract.md
- [ ] check-plan-pane-contract.sh
