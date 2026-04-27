---
plan_id: 1003
title: "Demo: Revisions needed"
status: revisions_needed
skill: doey-masterplan
---

# Plan: Demo — Revisions needed

## Goal
Land the watcher loop and address the Critic's revision request before
re-submitting for consensus.

## Context
Architect has approved; Critic has asked for revisions citing missing
edge-case coverage in the atomic-rename rendezvous.

## Phases

### Phase 1: Architecture decisions
**Status:** done
- [x] Pin Bubbletea v2
- [x] Settle on bubblezone

### Phase 2: Live data plumbing
**Status:** in-progress
- [x] fsnotify watcher
- [ ] Atomic-rename rendezvous edge cases
- [ ] Self-write suppression test
