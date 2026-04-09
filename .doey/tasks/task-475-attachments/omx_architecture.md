# OMX (oh-my-codex) Architecture & Multi-Agent Coordination Research

**Repo:** `~/GitHub/oh-my-codex`
**Date:** 2026-04-09
**Researcher:** Worker 2 (d-t2-w2)

---

## 1. `.omx/` Durable State

### Structure

OMX persists all runtime state under a `.omx/` directory at the project root. This is a **durable, in-repo** directory (not ephemeral/tmpfs). Key contents:

```
.omx/
  state/
    {mode}-state.json          # Root-scoped mode state (autopilot, team, ralph, etc.)
    session.json               # Current session ID
    sessions/{id}/             # Session-scoped mode state
      {mode}-state.json
    team/{team-name}/          # Per-team state (see Section 4)
      config.json
      manifest.v2.json
      worker-agents.md
      tasks/task-{id}.json
      workers/worker-{n}/
        identity.json
        inbox.md
        heartbeat.json
        status.json
      mailbox/
        leader-fixed.json
        worker-{n}.json
      dispatch/
        requests.json
  plans/
    prd-*.md                   # Product requirements (ralph planning gate)
    test-spec-*.md             # Test specifications
  context/
    {slug}-{timestamp}.md      # Pre-launch context snapshots
  notepad.md                   # Session scratch notes (priority/working/manual sections)
  project-memory.json          # Cross-session project memory
  logs/                        # Runtime logs
  worktrees/                   # Worktree paths for autoresearch
  team/{team}/worktrees/       # Worktree paths for team workers
```

**Source:** `src/mcp/state-paths.ts:140-156` defines the base state directory as `<cwd>/.omx/state`. Session-scoped state lives under `.omx/state/sessions/{id}/`.

### State Persistence Mechanism

- **Atomic writes:** State files are written atomically via a temp-file + rename pattern (`src/state/operations.ts:65-74`). A `writeAtomicFile()` function creates a uniquely named `.tmp` file, writes content, then renames over the target.
- **Write queues:** Per-path write locks (`stateWriteQueues` map in `src/state/operations.ts:43-63`) serialize concurrent writes to the same state file.
- **Session scoping:** State can be root-scoped or session-scoped. Session ID is read from `.omx/state/session.json` (`src/mcp/state-paths.ts:166-175`). Read operations check session-scoped paths first, falling back to root.
- **Mode state lifecycle:** Modes (ralph, team, autopilot, etc.) write state on start, update on phase change, mark `completed_at` on completion, and clear on cancel (`AGENTS.md:299-313`).

### Comparison to Doey

| Aspect | OMX | Doey |
|--------|-----|------|
| **Location** | `.omx/` in project root (durable, in-repo) | `/tmp/doey/<project>/` (ephemeral, cleared on reboot) |
| **Task storage** | `.omx/state/team/{team}/tasks/task-{id}.json` | `.doey/tasks/` (durable) + `/tmp/doey/` runtime |
| **Survives reboot** | Yes (filesystem persistence) | Tasks survive; runtime state does not |
| **Session scoping** | Built-in session ID system with precedence | Per-session tmux environment variables |
| **Write safety** | Atomic rename + per-path write locks | File-level conventions (one worker per file) |
| **Memory** | `project-memory.json` + `notepad.md` via MCP tools | Claude Code auto-memory in `~/.claude/projects/` |

**Key insight:** OMX's `.omx/` directory is the single source of truth for all coordination state. Doey splits this between durable task state (`.doey/tasks/`) and ephemeral runtime state (`/tmp/doey/`). OMX's approach makes state fully recoverable after crashes but risks cluttering the project directory with coordination artifacts.

---

## 2. AGENTS.md Project Guidance

### What It Contains

OMX uses `AGENTS.md` (at project root) as the top-level operating contract for the workspace. It is functionally equivalent to Doey's `CLAUDE.md` but significantly more structured. Contents (`AGENTS.md:1-320`):

1. **Autonomy directive** (lines 1-6): Instructs agents to execute autonomously without asking permission.
2. **Operating principles** (lines 31-47): Core behavioral rules with runtime-injectable guidance markers (`<!-- OMX:GUIDANCE:OPERATING:START/END -->`).
3. **Working agreements** (lines 49-58): Code conventions (regression tests before cleanup, prefer deletion, keep diffs small).
4. **Delegation rules** (lines 61-76): Mode selection logic (deep-interview, ralplan, team, ralph, solo execute).
5. **Child agent protocol** (lines 78-98): Leader/worker responsibilities, max 6 concurrent children, model inheritance rules.
6. **Agent catalog** (lines 116-127): Key roles summary (explore, planner, architect, debugger, executor, verifier).
7. **Keyword detection** (lines 130-167): Skill trigger table mapping keywords to workflow activations.
8. **Team pipeline** (lines 185-195): Canonical staged pipeline: `team-plan -> team-prd -> team-exec -> team-verify -> team-fix`.
9. **Model resolution** (lines 196-209): Worker model precedence rules with runtime-injectable markers.
10. **Verification protocol** (lines 213-228): Evidence-based completion verification.
11. **Execution protocols** (lines 230-288): Mode selection, command routing, leader/worker rules, parallelization, anti-slop workflow.
12. **State management** (lines 298-313): `.omx/` state directory documentation.

### How Agents Consume It

- **AGENTS.md is auto-generated/templated:** Runtime hooks inject dynamic content between marker-bounded blocks (e.g., `<!-- OMX:RUNTIME:START -->...<!-- OMX:RUNTIME:END -->`, `<!-- OMX:TEAM:WORKER:START -->...<!-- OMX:TEAM:WORKER:END -->`). The `src/hooks/agents-overlay.ts` hook handles runtime overlay injection.
- **Worker-scoped variant:** Team workers get a composed version at `.omx/state/team/{team}/worker-agents.md` that includes the project AGENTS.md content plus worker-specific overlay, without mutating the project file (`skills/team/SKILL.md:139-141`).
- **Role prompts are subordinate:** The `prompts/*.md` files provide narrow role-specific instructions but must follow AGENTS.md, not override it (`AGENTS.md:12`).

### Comparison to Doey

| Aspect | OMX | Doey |
|--------|-----|------|
| **File** | `AGENTS.md` (project root) | `CLAUDE.md` (project root) |
| **Format** | Heavily structured with XML-like tags, marker-bounded runtime injection zones | Markdown tables and prose |
| **Runtime modification** | Yes - hooks inject dynamic overlays between markers | No runtime modification |
| **Worker variant** | Composed per-team `worker-agents.md` with overlays | Agent definitions in `agents/` dir with YAML frontmatter |
| **Scope** | All agents consume the same AGENTS.md (with per-role prompt supplements) | Each role has its own agent definition file |
| **Keyword routing** | Built into AGENTS.md with keyword-to-skill mapping table | Handled by hooks (`on-pre-tool-use.sh`) and intent fallback |

**Key insight:** OMX centralizes all agent behavior in one large AGENTS.md with runtime injection markers, while Doey distributes behavior across agent definition files, hooks, and CLAUDE.md. OMX's approach gives agents a unified worldview but creates a large, complex file. Doey's approach is more modular but requires agents to piece together instructions from multiple sources.

---

## 3. Specialist Roles

### Role Definitions

OMX defines **28 specialist agent roles** in `src/agents/definitions.ts:42-334`, each with structured metadata:

```typescript
interface AgentDefinition {
  name: string;
  description: string;
  reasoningEffort: 'low' | 'medium' | 'high';
  posture: 'frontier-orchestrator' | 'deep-worker' | 'fast-lane';
  modelClass: 'frontier' | 'standard' | 'fast';
  routingRole: 'leader' | 'specialist' | 'executor';
  tools: 'read-only' | 'analysis' | 'execution' | 'data';
  category: 'build' | 'review' | 'domain' | 'product' | 'coordination';
}
```

**Categories and roles:**

| Category | Roles | Count |
|----------|-------|-------|
| **Build** | explore, analyst, planner, architect, debugger, executor, team-executor, verifier | 8 |
| **Review** | style-reviewer, quality-reviewer, api-reviewer, security-reviewer, performance-reviewer, code-reviewer | 6 |
| **Domain** | dependency-expert, test-engineer, quality-strategist, build-fixer, designer, writer, qa-tester, git-master, code-simplifier, researcher | 10 |
| **Product** | product-manager, ux-researcher, information-architect, product-analyst | 4 |
| **Coordination** | critic, vision | 2 |

### Role Selection Mechanism

Roles are selected through a **heuristic role router** (`src/team/role-router.ts:133-264`):

1. **Intent inference** (lines 105-115): Task description is matched against regex patterns to determine lane intent (implementation, verification, review, debug, design, docs, build-fix, cleanup).
2. **High-confidence matches**: Build-fix, debug, docs, design, cleanup, and review intents map directly to specific roles (build-fixer, debugger, writer, designer, code-simplifier, quality/security-reviewer).
3. **Keyword scoring** (lines 83-92, 209-227): For ambiguous tasks, keywords from ROLE_KEYWORDS are scored. 2+ matches from same category = high confidence; 1 match = medium.
4. **Phase context** (lines 122-127, 247-257): Team phase provides fallback hints (team-verify -> verifier, team-fix -> build-fixer).
5. **Fallback**: If no keywords match, the default `agentType` (usually `executor`) is used.

Each role has a corresponding **prompt file** in `prompts/` (e.g., `prompts/executor.md`, `prompts/debugger.md`). These provide behavioral instructions, constraints, and output contracts. For example, the executor prompt (`prompts/executor.md:1-178`) includes identity, scope guard, execution loop, verification loop, failure recovery, and output contract sections.

### Comparison to Doey

| Aspect | OMX | Doey |
|--------|-----|------|
| **Number of roles** | 28 specialist roles | ~15 roles (Boss, Taskmaster, Subtaskmaster, Workers, Freelancers, Critic, Deployment, etc.) |
| **Role granularity** | Fine-grained specialists (security-reviewer, api-reviewer, performance-reviewer) | General-purpose Workers with role context from Subtaskmaster |
| **Role metadata** | TypeScript interface with reasoning effort, model class, tool access, posture | YAML frontmatter (name, model, color, memory, description) |
| **Role selection** | Automated heuristic router based on task keywords + phase | Manual by Subtaskmaster during task delegation |
| **Worker specialization** | Workers are launched with specific role prompts matching task type | Workers are general-purpose; Subtaskmaster provides task-specific context |
| **Tool restrictions** | By role posture (read-only, analysis, execution) in definitions | By role in `on-pre-tool-use.sh` hook |

**Key insight:** OMX invests heavily in role specialization — 28 distinct roles with automated routing. Workers get task-specific behavioral prompts that shape their entire approach. Doey keeps Workers general-purpose and relies on the Subtaskmaster to provide task-specific context at delegation time. OMX's approach provides more structured behavior but adds complexity; Doey's approach is more flexible but relies more on the Subtaskmaster's judgment.

---

## 4. Team N:Executor Parallel Coordination

### Team Architecture

OMX teams use a **tmux-based split-pane architecture** similar to Doey, but with significant differences in coordination machinery.

**Invocation:** `omx team [N:agent-type] "<task description>"` (e.g., `omx team 3:executor "fix bugs"`)

**Launch sequence** (`skills/team/SKILL.md:130-152`):

1. Parse args (N workers, agent-type, task description)
2. Sanitize team name from task text
3. Initialize team state under `.omx/state/team/<team>/`
4. Compose worker instructions file (`worker-agents.md`)
5. Split current tmux window into worker panes
6. Launch workers with environment variables:
   - `OMX_TEAM_WORKER=<team>/worker-<n>`
   - `OMX_TEAM_STATE_ROOT=<leader-cwd>/.omx/state`
   - `OMX_TEAM_LEADER_CWD=<leader-cwd>`
7. Wait for worker readiness (capture-pane polling)
8. Write per-worker `inbox.md` and trigger via `tmux send-keys`
9. Return control to leader

### Task Distribution

Tasks are distributed through a **claim-based system** with durable state files:

1. **Task creation:** Leader creates tasks as JSON files at `.omx/state/team/<team>/tasks/task-{id}.json`
2. **Task claiming:** Workers claim tasks via `omx team api claim-task --json` with a claim token (`src/team/contracts.ts:5-15`). Status transitions: `pending -> in_progress -> completed|failed`.
3. **Inbox-driven assignment:** Workers read their inbox at `.omx/state/team/<team>/workers/worker-{n}/inbox.md` for initial assignments.
4. **Dispatch queue:** Durable dispatch requests at `.omx/state/team/<team>/dispatch/requests.json` with status lifecycle: `pending -> notified -> delivered|failed` (`src/team/state/dispatch.ts:1-50`).

### Conflict Prevention

OMX uses multiple strategies to prevent concurrent edit conflicts:

1. **Git worktrees** (`src/team/worktree.ts:1-496`): Workers can operate in separate git worktrees (`omx team --worktree[=<name>]`). Worktrees are created under `.omx/team/<team>/worktrees/<worker>` or `<repo>.omx-worktrees/` (lines 202-224). Each worker gets its own branch (`<branch>/<worker-name>`).
2. **File-based locks:** Scaling operations use file-based locks (`withScalingLock`, `withDispatchLock`, `withTaskClaimLock`, `withMailboxLock` in `src/team/state/locks.ts`).
3. **Atomic state writes:** All state mutations use atomic rename pattern (`src/state/operations.ts:65-74`).
4. **Task claim tokens:** Claim-safe lifecycle prevents two workers from working on the same task.
5. **Worker integration status tracking:** Tracks `idle|integrated|integration_failed|cherry_pick_conflict|rebase_conflict` (`src/team/contracts.ts:48-59`).

### Result Collection

Results flow back to the leader through multiple channels:

1. **Mailbox system:** Workers send messages to `mailbox/leader-fixed.json` via `omx team api send-message --json`. The leader's mailbox aggregates ACKs and results.
2. **Task status transitions:** Workers transition tasks to `completed` or `failed` via `omx team api transition-task-status --json`.
3. **Heartbeat monitoring:** Workers write heartbeat JSON at `workers/worker-{n}/heartbeat.json`. Leader monitors for stale heartbeats.
4. **Event system:** 30+ event types (`src/team/contracts.ts:61-93`) including `task_completed`, `task_failed`, `worker_idle`, `all_workers_idle`, `worker_merge_conflict`, etc.
5. **Leader nudging:** Automatic leader nudge via `team-leader-nudge.json` when workers complete or stall (`skills/team/SKILL.md:218-226`).
6. **Delivery log:** Append-only delivery log tracks all dispatch attempts and outcomes (`src/team/delivery-log.ts`).

### Staged Pipeline

Team execution follows a canonical phase pipeline (`src/team/orchestrator.ts:8-9, 28-34`):

```
team-plan -> team-prd -> team-exec -> team-verify -> team-fix (loop)
```

Each phase has recommended agent roles (`src/team/orchestrator.ts:124-141`):
- **team-plan:** analyst, planner
- **team-prd:** product-manager, analyst
- **team-exec:** executor, designer, test-engineer
- **team-verify:** verifier, quality-reviewer, security-reviewer
- **team-fix:** executor, build-fixer, debugger

Fix loop limit prevents infinite cycling (default max 3 attempts).

### Dynamic Scaling

Workers can be added or removed mid-session (`src/team/scaling.ts`):
- **Scale up:** `scaleUp()` adds new tmux panes, creates worktrees if needed, bootstraps workers with inbox instructions.
- **Scale down:** `scaleDown()` sets workers to `draining` status, waits for drain timeout, then kills panes and cleans up.
- Max 20 workers per team (configurable).
- Monotonic worker index counter ensures unique names across scale operations.

### Comparison to Doey

| Aspect | OMX | Doey |
|--------|-----|------|
| **Pane layout** | Split panes in current tmux window | Dedicated windows per team (W.0 = Subtaskmaster, W.1+ = Workers) |
| **Coordination** | File-based state + CLI API (`omx team api`) | tmux send-keys + file-based status |
| **Task assignment** | Claim-based with tokens; workers claim from shared task pool | Subtaskmaster assigns directly to specific workers |
| **Conflict prevention** | Git worktrees per worker + file locks + claim tokens | One worker per file convention + tool restrictions |
| **Result collection** | Mailbox JSON + event system + heartbeats | Stop hooks -> result JSON -> notification chain |
| **Dynamic scaling** | Built-in scale up/down with rollback | Fixed team size at launch |
| **Phase pipeline** | Explicit 5-phase pipeline with role recommendations | No formal phase pipeline; Subtaskmaster manages flow |
| **Max workers** | 20 per team | Limited by tmux pane capacity |
| **Worker model** | Configurable per-worker CLI (Codex/Claude), model, reasoning effort | All workers use same Claude Code SDK |
| **Dispatch** | Durable dispatch queue with hook-preferred + fallback transport | Direct tmux send-keys |

**Key insight:** OMX's coordination is significantly more sophisticated than Doey's, with claim-based task ownership, durable dispatch queues, git worktrees for isolation, dynamic scaling, and a formal phase pipeline. However, this comes at the cost of substantial complexity in the codebase (~150+ source files vs. Doey's shell-based approach). Doey's tmux-native approach with Subtaskmaster human-in-the-loop delegation is simpler but less automated.

---

## Key Takeaways

1. **Durable vs. ephemeral state:** OMX's `.omx/` in the project directory provides full crash recovery and cross-session continuity. Doey's `/tmp/doey/` ephemeral approach is simpler but loses runtime state on reboot. Doey's `.doey/tasks/` provides some durability for task tracking. Consider whether Doey should move more coordination state to `.doey/` for resilience.

2. **Centralized vs. distributed guidance:** OMX's single `AGENTS.md` with runtime injection markers creates one source of truth but becomes a large, complex document (~320 lines). Doey's distributed approach (CLAUDE.md + per-role agent files + hooks) is more modular. Both approaches work; the tradeoff is discoverability vs. modularity.

3. **Specialist roles vs. general-purpose workers:** OMX's 28 specialist roles with automated keyword routing enable task-appropriate behavior without human coordination. Doey's general-purpose Workers with Subtaskmaster delegation rely on human-like judgment at the coordination layer. OMX trades flexibility for consistency; Doey trades consistency for adaptability.

4. **Claim-based vs. assignment-based coordination:** OMX workers claim tasks from a shared pool with tokens, enabling self-organization. Doey's Subtaskmaster directly assigns tasks to specific workers, maintaining tighter control. OMX's approach scales better but risks coordination overhead; Doey's approach is simpler but requires the Subtaskmaster to remain actively involved.

5. **Git worktrees for isolation:** OMX's built-in worktree support eliminates file-level conflict entirely by giving each worker its own copy of the repo. This is a significant architectural advantage over Doey's "one worker per file" convention, which relies on discipline rather than enforcement.

6. **Dynamic scaling:** OMX can add/remove workers mid-session with automatic rollback on failure. Doey teams are fixed at launch. This is a valuable capability for long-running tasks where initial sizing may be wrong.

7. **Complexity cost:** OMX's TypeScript codebase for coordination is ~150+ source files with sophisticated state machines, lock hierarchies, and dispatch protocols. Doey achieves similar goals with shell scripts and tmux primitives. OMX's approach is more robust but harder to debug and maintain.
