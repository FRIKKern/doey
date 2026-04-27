---
plan_id: 1002
title: "Demo: Under review plan"
status: under_review
skill: doey-masterplan
---

# Plan: Demo — Under review plan

## Goal
Send the first revision to Architect and Critic and wait on their reads.

## Context
Two reviewer files have been opened but no Verdict line is recorded yet —
the cards should render in the "file present, no verdict" state.

## Phases

### Phase 1: Skeleton
**Status:** done
- [x] Define data shape
- [x] Stub Source interface

### Phase 2: Watcher loop
**Status:** in-progress
- [x] Wire fsnotify
- [ ] Atomic-rename rendezvous
- [ ] Self-write suppression
