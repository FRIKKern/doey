# Scientific Task Architecture & Visualization Plan for Doey

## Purpose

Implement a scientific, intent-first task architecture in Doey so that tasks are not passed around as vague prose, but as structured objects with explicit intent, bridge problems, representation layers, hypotheses, constraints, success criteria, and evidence plans. The end state is a system where:

- **Boss / Project Manager** compiles user intent into structured tasks.
- **Taskmaster** routes and synthesizes from structured tasks instead of reconstructing intent from scratch.
- **Subtaskmasters** execute scoped hypothesis-driven briefs.
- **Workers** return evidence, confidence updates, and implementation results.
- **Info Panel** renders advanced terminal-safe visualizations without left/right borders.

This plan is written to be directly actionable in the Doey repository.

---

## Product Principles

### 1. Structured task package is the source of truth
The system must not rely on agent prose alone. Every serious task must exist as machine-readable state.

### 2. No left/right border rendering
Terminal output must avoid enclosing box borders because width drift, pane wrapping, and variable font/rendering make them unstable in tmux.

### 3. Visible output is delta-based and scientific
The system should surface:
- what changed
- what it means
- what evidence supports it
- what should happen next

Not repeated polling narration.

### 4. Backward compatibility is mandatory
Legacy tasks must continue working while structured tasks are introduced incrementally.

---

## Canonical Role Model

- **Info Panel**: dashboard rendering only
- **Boss / Project Manager**: user-facing intent compilation and task creation
- **Taskmaster**: cross-team routing, synthesis, observatory rendering
- **Subtaskmaster**: team-local planning and delegation
- **Workers**: investigation, implementation, validation, reporting
- **Freelancers**: research, validation, specialized synthesis, overflow

Watchdogs are deprecated and must not appear in the target architecture.

### Canonical Dashboard Layout

- `0.0` Info Panel
- `0.1` Boss / Project Manager
- `0.2` Taskmaster

---

## Phase 0 — Baseline Audit and Role Map Correction

### Objective
Remove architectural ambiguity before building new task infrastructure.

### Watchdog deprecation requirement
Identify every prompt, script, status label, dashboard element, and documentation reference that still assumes Watchdogs are active runtime roles. Classify each as: remove entirely, migrate to SM, migrate to team-local handling, or keep as legacy with deprecation note.

### Files to inspect and update
- README.md, docs/context-reference.md, agents/doey-boss.md, agents/doey-taskmaster.md, shell/info-panel.sh, any tmux/dashboard label scripts

### Required actions
1. Find all places that describe dashboard pane mapping
2. Normalize to canonical layout
3. Update terminology: Boss = Project Manager
4. Confirm no file presents SM as 0.1

### Acceptance criteria
- One consistent pane map in docs and prompts
- Boss and Project Manager clearly unified
- No contradictory role descriptions remain

---

## Phase 1 — Structured Task Schema

### Objective
Introduce a durable source of truth for serious tasks.

### Design
Two files per task:
- `tasks/<id>.task` → compact key-value summary for shell compatibility
- `tasks/<id>.json` → full scientific task package

### .task format
```
TASK_ID=42
TASK_TITLE=Stabilize session handling
TASK_STATUS=active
TASK_TYPE=debugging
TASK_OWNER=Boss
TASK_CREATED=1712345678
TASK_PRIORITY=high
TASK_SUMMARY=Resolve mismatch between frontend session state and backend validation
TASK_SCHEMA_VERSION=2
```

### .json format
```json
{
  "schema_version": 2,
  "task_id": 42,
  "title": "Stabilize session handling",
  "task_type": "debugging",
  "intent": "Users are intermittently logged out...",
  "concepts": [{"id": "A", "name": "Frontend session state"}, {"id": "B", "name": "Backend validation logic"}],
  "bridge_problem": "The relationship between frontend state and backend validation becomes inconsistent under refresh and transition conditions.",
  "representation_layer": ["session sync layer", "validation protocol", "token lifecycle", "state transition boundaries"],
  "hypotheses": [
    {"id": "H1", "text": "Frontend sends stale session state", "confidence": 0.50},
    {"id": "H2", "text": "Backend intermittently rejects valid tokens", "confidence": 0.60},
    {"id": "H3", "text": "A race condition exists in the sync layer", "confidence": 0.30}
  ],
  "constraints": ["Do not break existing login flow", "Maintain API compatibility", "Avoid adding global state"],
  "success_criteria": ["Users remain logged in across refresh", "Frontend and backend session state remain aligned", "No auth-related session anomalies"],
  "evidence_plan": ["Trace session lifecycle across refresh", "Compare expected vs actual backend validation", "Test token timing and transition edges"],
  "deliverables": ["Root cause explanation", "Files changed", "Why the fix works", "Residual risks"],
  "dispatch_plan": {"primary_team_type": "managed", "needs_validation_wave": true, "needs_freelancer_research": false},
  "phase": "exploration"
}
```

### Required shell support
- Task creation helper for .task
- JSON write path for structured tasks
- Graceful fallback when .json is absent

### Acceptance criteria
- Structured tasks can be created without breaking legacy task listing
- .task remains parseable by shell scripts
- .json is optional for legacy tasks and required for structured tasks

---

## Phases 2–11 (deferred until Phase 0+1 are stable)

2. Boss becomes Project Manager Compiler
3. Task Compiler Skill (`/doey-create-task`)
4. Structured Dispatch Protocol (`dispatch_task` subject)
5. Subtaskmaster Brief Format
6. Worker Result Schema Upgrade (hypothesis_updates, evidence, confidence)
7. Scientific Visualization Grammar (symbols, confidence bars, flow diagrams)
8. Central Rendering Script (`shell/doey-render-task.sh`)
9. Info Panel Upgrade (scientific task rendering)
10. Taskmaster Observatory Upgrade (delta-based output)
11. Backward Compatibility and Migration

---

## Testing Plan

A. Prompt-contract tests (Boss generates valid structured tasks, SM routes from metadata)
B. Rendering snapshot tests (width 80/100/140, unicode, ASCII fallback)
C. End-to-end runtime tests (create → dispatch → simulate results → verify rendering)
D. Backward-compatibility tests (legacy .task files still work)

---

## Definition of Done

- Serious user goals become structured task packages automatically
- Packages define intent, bridge problem, representation layer, hypotheses, constraints, success criteria, evidence plan, deliverables
- SM routes from structured packages, not reconstructed prose
- WMs receive scoped hypothesis-driven briefs
- Workers return evidence and confidence updates
- Info Panel renders terminal-safe scientific visualizations without left/right borders
- SM surfaces delta-based observatory summaries
- Legacy task flows still work
