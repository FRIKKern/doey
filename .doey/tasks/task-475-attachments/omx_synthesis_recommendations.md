# OMX Competitive Analysis — Synthesized Recommendations for Doey

**Task #475 | Synthesized by Subtaskmaster W2 | 2026-04-09**

Based on deep analysis of oh-my-codex (OMX) repo at ~/GitHub/oh-my-codex, covering 8 research areas across workflow/UX and architecture/coordination.

---

## Ranked Recommendations (by impact × feasibility)

### Tier 1: High Impact, Moderate Effort — Adopt Soon

#### 1. Vague-Prompt Interceptor (from ralplan)
**What OMX does:** Prompts with ≤15 words and no concrete anchors (file paths, function names, issue numbers) are redirected back to planning instead of execution.
**Why Doey needs it:** Our Taskmaster accepts whatever Boss sends. Vague tasks produce vague worker output. A simple gate at the Taskmaster layer — "does this task mention specific files, functions, or tests?" — would prevent wasted worker cycles.
**Implementation:** Add a check in Taskmaster's dispatch logic. If task description lacks concrete anchors, bounce back to Boss with a request for specifics. ~50 lines of shell logic.

#### 2. Auto-Nudge for Stalled Workers (from ralph)
**What OMX does:** Monitors for 30+ stall patterns ("would you like", "shall I", "ready to proceed") and auto-sends "yes, proceed" to the tmux pane. Semantic dedup prevents re-nudging the same stall.
**Why Doey needs it:** Workers regularly stall waiting for confirmation that never comes. We have no detection mechanism. The Subtaskmaster monitoring loop checks status but doesn't inspect pane content for stalls.
**Implementation:** Add stall-pattern detection to the Subtaskmaster monitoring loop or as a lightweight watchdog. Capture last few pane lines, match against known stall patterns, send "yes, proceed" via send-keys. ~100 lines.

#### 3. Durable Runtime State (from .omx/)
**What OMX does:** All coordination state lives in `.omx/` (project directory) with atomic writes and per-path write locks. Survives reboots and crashes.
**Why Doey needs it:** Our `/tmp/doey/` is cleared on reboot, losing all worker status, results, and coordination state. Long-running tasks that span restarts lose everything.
**Implementation:** Move critical state (worker status, results, dispatch queues) from `/tmp/doey/` to `.doey/runtime/`. Keep truly ephemeral data (pane PIDs, tmux capture) in `/tmp/`. Atomic writes via temp+rename pattern. Multi-phase migration.

#### 4. Session Resume for Workers (from ralph)
**What OMX does:** Ralph detects when Codex restarts in a new session and atomically transfers the prior session's state (task progress, iteration count, current phase) to the new instance.
**Why Doey needs it:** When a worker crashes or is manually restarted, all context is lost. The Subtaskmaster must re-brief from scratch.
**Implementation:** On worker stop, persist a "resume checkpoint" to durable state (task ID, subtask ID, files changed, current phase, last action). On worker restart, check for checkpoint and inject it into the system prompt. Depends on #3 (durable state).

### Tier 2: Medium Impact, Lower Effort — Good Quick Wins

#### 5. Structured Interview Mode for Boss (inspired by deep-interview)
**What OMX does:** Formal Socratic interview with mathematical ambiguity scoring, weighted dimension formulas, and readiness gates (non-goals explicit, decision boundaries explicit, at least one pressure pass).
**Why Doey should adapt (not copy):** OMX's mathematical scoring is overengineered for our use case. But the *concept* of structured clarification with explicit readiness checks is valuable. Boss currently takes intent at face value.
**Implementation:** Add a `/deep-interview` skill for Boss that asks structured questions (intent, scope, non-goals, success criteria) and won't relay to Taskmaster until key fields are filled. Lighter than OMX — checklist-based, not formula-based.

#### 6. Worker Model Flexibility (from madmax/high modes)
**What OMX does:** CLI flags (`--high`, `--xhigh`, `--spark`) control reasoning effort and model tier. Leader flags automatically propagate to workers. Persistent reasoning config via `omx reasoning high`.
**Why Doey needs it:** Our per-agent model settings are baked into YAML definitions. Users can't say "run this task with faster workers" or "use higher reasoning for this complex task" without editing agent files.
**Implementation:** Add `--model` and `--reasoning` flags to `doey` CLI. Store in session.env. Worker launch commands read from session config, falling back to agent YAML defaults.

#### 7. Plan Review Loop (inspired by ralplan)
**What OMX does:** Planner→Architect→Critic consensus loop with up to 5 re-review iterations.
**Why Doey should adapt:** Full 3-agent consensus is overkill for our model. But a single review pass — Subtaskmaster creates plan, Critic reviews before dispatch — would catch bad plans early.
**Implementation:** Before dispatching Wave 1, Subtaskmaster sends plan summary to Critic pane. Critic returns approve/revise verdict. On revise, Subtaskmaster adjusts. Single iteration, not a loop.

### Tier 3: Valuable but Higher Effort — Future Roadmap

#### 8. Git Worktrees for Worker Isolation (from team coordination)
**What OMX does:** Each worker gets its own git worktree branch. Eliminates file-level conflicts entirely.
**Why it's valuable:** Our "one worker per file" convention relies on Subtaskmaster discipline. Worktrees enforce isolation mechanically.
**Why it's Tier 3:** Requires significant infrastructure — worktree creation/cleanup, branch management, merge coordination. Our shell-based approach would need substantial new plumbing.
**Recommendation:** Evaluate as a future feature. For now, strict one-worker-per-file is sufficient.

#### 9. Specialist Role Routing (from OMX's 28 roles)
**What OMX does:** 28 specialist roles with keyword-based automated routing. Workers get task-specific behavioral prompts.
**Why we shouldn't copy directly:** OMX's 28 roles are granular to the point of diminishing returns. Most tasks only use 5-6 roles regularly.
**What to adopt:** Instead of general-purpose Workers, create 5-8 "task type" prompt overlays (debug, test, implement, review, refactor, research) that Subtaskmaster selects at dispatch time. Lighter than full role definitions but gives workers task-appropriate guidance.

#### 10. Durable Dispatch Queue (from team coordination)
**What OMX does:** Dispatch requests are persisted as JSON with status lifecycle (pending→notified→delivered). Survives leader restart.
**Why it matters:** Our send-keys dispatch is fire-and-forget. If the Subtaskmaster crashes between dispatching and the worker receiving, the task is lost.
**Implementation:** Write dispatch intent to durable state before send-keys. Mark delivered on confirmation. On Subtaskmaster restart, check for undelivered dispatches. Depends on #3.

---

## What NOT to Adopt

| OMX Feature | Why Skip |
|-------------|----------|
| Mathematical ambiguity scoring | Over-engineered for our use case. Simple checklist-based readiness is sufficient |
| 28 specialist roles | Too granular. 5-8 task-type overlays achieve 80% of the benefit |
| AGENTS.md runtime injection markers | Our distributed CLAUDE.md + agent files is more maintainable |
| Claim-based task pool | Our direct assignment model is simpler and keeps Subtaskmaster in control |
| TypeScript coordination codebase | Our shell-based approach is simpler to debug and maintain. Don't trade shell simplicity for TypeScript sophistication |

---

## Key Strategic Insight

OMX's core advantage isn't any single feature — it's the **integrated pipeline** where each stage produces structured artifacts consumed by the next (specs → plans → state → verification). Doey's communication via send-keys text loses structure at every handoff.

**The highest-leverage change for Doey** isn't copying OMX features individually — it's establishing structured artifact handoff between stages. When Boss produces a task, it should be a structured document (not free text). When Subtaskmaster creates a plan, it should be a queryable artifact (not inline text). When Workers finish, their output should flow into a structured result (which we already partially do with result JSON).

This is effectively what recommendations #1, #3, and #5 address from different angles.
