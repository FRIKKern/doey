# OMX Workflow & UX Patterns Research

Research conducted on the [oh-my-codex](https://github.com/Yeachan-Heo/oh-my-codex) (OMX) repository at `~/GitHub/oh-my-codex`.

OMX is a workflow layer for OpenAI Codex CLI. It keeps Codex as the execution engine and layers on structured workflows: clarification, planning, execution, and verification. The four key systems are `deep-interview`, `ralplan`, `ralph`, and mode flags like `--madmax`/`--high`.

---

## Deep Interview (Clarification Before Work)

### What It Does

Deep Interview is a **Socratic clarification loop** that turns vague ideas into execution-ready specifications before any planning or implementation begins. It uses **quantitative ambiguity scoring** to gate progression.

**Key files:**
- `skills/deep-interview/SKILL.md` (full skill definition, 359 lines)
- `src/hooks/keyword-registry.ts:25-29` (trigger keywords)
- `src/hooks/__tests__/deep-interview-contract.test.ts` (contract tests)
- `src/scripts/notify-hook/auto-nudge.ts:27-28` (deep-interview input lock)

### How It Gathers Requirements

**5-phase workflow:**

1. **Phase 0 — Preflight Context Intake:** Before asking anything, scans the codebase to classify brownfield vs greenfield, creates a context snapshot at `.omx/context/{slug}-{timestamp}.md` with task statement, desired outcome, constraints, unknowns, and likely touchpoints.

2. **Phase 1 — Initialize:** Parses depth profile, detects project context, initializes state with `state_write(mode="deep-interview")` storing interview_id, profile, type, initial idea, ambiguity score (starts at 1.0), and threshold.

3. **Phase 2 — Socratic Interview Loop:** Asks **ONE question per round** (never batches). Questions target the weakest clarity dimension, with a stage-priority order:
   - **Stage 1 (Intent-first):** Intent, Outcome, Scope, Non-goals, Decision Boundaries
   - **Stage 2 (Feasibility):** Constraints, Success Criteria
   - **Stage 3 (Brownfield grounding):** Context Clarity

4. **Phase 3 — Challenge Modes:** Three "assumption stress test" modes activated at specific thresholds:
   - **Contrarian** (round 2+): Challenge core assumptions
   - **Simplifier** (round 4+): Probe minimal viable scope
   - **Ontologist** (round 5+, ambiguity > 0.25): Reframe toward essence/root cause

5. **Phase 4 — Crystallize:** Writes interview transcript to `.omx/interviews/` and execution-ready spec to `.omx/specs/deep-interview-{slug}.md`

### How It Decides When Clarification Is Sufficient

**Mathematical ambiguity gating** with weighted dimension scores:

- **Greenfield formula:** `ambiguity = 1 - (intent * 0.30 + outcome * 0.25 + scope * 0.20 + constraints * 0.15 + success * 0.10)`
- **Brownfield formula:** `ambiguity = 1 - (intent * 0.25 + outcome * 0.20 + scope * 0.20 + constraints * 0.15 + success * 0.10 + context * 0.10)`

**Three depth profiles with different thresholds:**

| Profile | Threshold | Max Rounds |
|---------|-----------|------------|
| Quick   | <= 0.30   | 5          |
| Standard (default) | <= 0.20 | 12 |
| Deep    | <= 0.15   | 20         |

**Mandatory readiness gates** (must pass even if ambiguity threshold is met):
- Non-goals must be explicit
- Decision Boundaries must be explicit
- At least one pressure pass (revisiting an earlier answer with a deeper follow-up) must be complete

### Comparison to Doey's Boss

| Aspect | OMX Deep Interview | Doey Boss |
|--------|-------------------|-----------|
| Trigger | Keyword detection ("deep interview", "interview me", "ouroboros", "don't assume") or explicit `$deep-interview` | User types intent naturally to Boss pane |
| Structure | Formal 5-phase workflow with quantitative scoring | Informal intent gathering, relays to Taskmaster |
| Gating | Mathematical ambiguity threshold with readiness gates | No formal gate — Boss decides when to relay |
| Depth control | 3 profiles (quick/standard/deep) with configurable rounds | No depth profiles |
| Artifact output | Structured spec at `.omx/specs/`, transcript at `.omx/interviews/` | Task description passed via send-keys |
| Pressure testing | Challenge modes (Contrarian, Simplifier, Ontologist) | None — Boss takes intent at face value |
| Resume | State persisted via `state_write`/`state_read` | No interview resume |
| Auto-approval lock | Blocks auto-nudge shortcuts during interview (`auto-nudge.ts:27-28`) | No equivalent |

**Key takeaway:** OMX treats clarification as a **first-class gated pipeline stage** with formal math. Doey treats it as an informal conversation between Boss and user.

---

## Ralplan (Plan Approval Flow)

### What It Does

Ralplan is **consensus planning** — a multi-agent loop where Planner, Architect, and Critic iterate until the plan reaches consensus approval.

**Key files:**
- `skills/ralplan/SKILL.md` (skill definition, 166 lines)
- `src/ralplan/runtime.ts` (consensus loop implementation, 297 lines)
- `src/pipeline/stages/ralplan.ts` (pipeline stage adapter, 102 lines)
- `src/planning/artifacts.ts` (planning artifact management)

### How Tradeoffs Are Presented

The workflow produces a **RALPLAN-DR (Decision Record)** with structured sections:

1. **Principles** (3-5)
2. **Decision Drivers** (top 3)
3. **Viable Options** (>= 2) with bounded pros/cons
4. If only one viable option remains: explicit invalidation rationale for alternatives
5. **Deliberate mode only:** Pre-mortem (3 failure scenarios) + expanded test plan (unit/integration/e2e/observability)

Final approved plan includes an **ADR (Architecture Decision Record):** Decision, Drivers, Alternatives considered, Why chosen, Consequences, Follow-ups.

### Plan Approval Mechanics

**Two modes:**
- **Automated (default):** Planner -> Architect -> Critic loop runs autonomously. No user interaction.
- **Interactive (`--interactive`):** User is prompted at two gates:
  1. After Planner draft: "Proceed to review / Request changes / Skip review"
  2. After Critic approval: "Approve and execute via ralph / Approve and implement via team / Request changes / Reject"

**Consensus loop** (`src/ralplan/runtime.ts:110-292`):
1. Planner creates draft plan
2. Architect reviews (must provide steelman antithesis + real tradeoff tension + synthesis) — **sequential, not parallel**
3. Critic evaluates (enforces principle-option consistency, fair alternatives, risk mitigation, testable acceptance criteria)
4. If Critic verdict is not `APPROVE` → re-review loop (max 5 iterations):
   - Collect feedback → Revise with Planner → Architect review → Critic evaluation → repeat
5. If 5 iterations reached without approval → present best version to user
6. If Critic approves → planning complete

**State tracking** via mode lifecycle (`src/ralplan/runtime.ts`):
- Phases: `draft` -> `architect-review` -> `critic-review` -> `complete`
- Terminal phases: `complete`, `cancelled`, `failed`
- Each iteration persists draft summaries, architect/critic verdicts, and full review history

### Pre-Execution Gate (Vague Prompt Interceptor)

Ralplan includes a **pre-execution gate** that intercepts underspecified execution requests (`src/hooks/keyword-registry.ts`, `skills/ralplan/SKILL.md:86-157`):

- Prompts with <= 15 effective words and no concrete anchors (file paths, function names, issue numbers, test runners, numbered steps) → **redirected to ralplan**
- Prompts with any concrete signal → **pass through to execution**
- User can bypass with `force:` or `!` prefix

### Comparison to Doey's Subtaskmaster Wave Planning

| Aspect | OMX Ralplan | Doey Subtaskmaster |
|--------|------------|-------------------|
| Agents involved | Planner, Architect, Critic (3 distinct roles) | Subtaskmaster alone (reads task, delegates) |
| Consensus | Formal multi-agent loop with verdicts (approve/iterate/reject) | No consensus — Subtaskmaster decides unilaterally |
| User approval | Optional (`--interactive` flag) at 2 gates | No formal approval gate |
| Iteration | Up to 5 re-review loops on non-approval | No iteration — plan is set once |
| Artifact output | PRD at `.omx/plans/`, test specs, ADR | Task delegation via send-keys |
| Vague prompt gate | Mathematical intercept with concrete-signal detection | No gate — Subtaskmaster receives whatever Taskmaster sends |
| Risk modes | Short mode (default) vs Deliberate mode (high-risk: pre-mortem + expanded test plan) | No risk differentiation |
| Handoff | Explicit contract: what artifacts to pass, what stages are skipped | Implicit via task description |

**Key takeaway:** OMX treats planning as a **debate between specialist agents** with formal approval gates. Doey's Subtaskmaster is a single-agent planner with no review loop.

---

## Ralph (Persistent Completion Loop)

### What It Does

Ralph is a **persistence loop that keeps working until a task is fully complete and architect-verified**. It wraps execution with session persistence, automatic retry on failure, and mandatory verification before completion.

**Key files:**
- `skills/ralph/SKILL.md` (skill definition, 265 lines)
- `src/cli/ralph.ts` (CLI entry point, 226 lines)
- `src/ralph/contract.ts` (phase validation, 129 lines)
- `src/ralph/persistence.ts` (artifact management, 329 lines)
- `src/scripts/notify-hook/ralph-session-resume.ts` (session resume, 347 lines)
- `src/pipeline/stages/ralph-verify.ts` (pipeline verification stage)
- `src/modes/base.ts` (mode lifecycle management)

### How It Ensures Completion

**9-step execution loop:**

0. **Pre-context intake:** Load or create context snapshot at `.omx/context/`
1. **Review progress:** Check TODO list and prior iteration state
2. **Continue from where left off:** Pick up incomplete tasks
3. **Delegate in parallel:** Route to specialist agents at appropriate tiers (LOW/STANDARD/THOROUGH per `docs/shared/agent-tiers.md`)
4. **Run long operations in background:** Builds, installs, test suites use `run_in_background: true`
5. **Visual task gate (optional):** If screenshots exist, run `$visual-verdict` before every edit
6. **Verify completion with fresh evidence:**
   - Identify what command proves the task is complete
   - Run verification (test, build, lint)
   - Read the output — confirm it actually passed
   - Check: zero pending/in_progress TODO items
7. **Architect verification** (tiered):
   - < 5 files, < 100 lines with tests: STANDARD tier minimum
   - Standard changes: STANDARD tier
   - > 20 files or security/architectural: THOROUGH tier
   - Ralph floor: always at least STANDARD
7.5. **Mandatory Deslop Pass:** Run `ai-slop-cleaner` on all changed files (opt out with `--no-deslop`)
7.6. **Regression Re-verification:** Re-run all tests after deslop. If regression fails, roll back and retry.
8. **On approval:** Run `/cancel` to clean up state
9. **On rejection:** Fix issues, re-verify at same tier

### Retry/Recovery Mechanisms

**Phase state machine** (`src/ralph/contract.ts:1-9`):
```
starting -> executing -> verifying -> fixing -> complete
                                   -> failed
                                   -> cancelled
```

**Session resume** (`src/scripts/notify-hook/ralph-session-resume.ts`):
- Uses a filesystem lock (`withRalphResumeLock`) with stale lock recovery (10s stale threshold)
- Scans for matching ralph candidates across OMX sessions by `owner_codex_session_id` or `owner_codex_thread_id`
- When Codex restarts in a new session, Ralph state from the prior session is **atomically transferred** (old state marked cancelled with `ownership_transferred`, new state written)
- Binds to current tmux pane for auto-nudge targeting

**Auto-nudge stall detection** (`src/scripts/notify-hook/auto-nudge.ts:220-254`):
- 30+ stall patterns detected (e.g., "would you like", "shall i", "next steps", "ready to proceed")
- When stall detected: automatically sends "yes, proceed" to the tmux pane
- Configurable delay (3s default), stall window (5s), and TTL (30s)
- Semantic signature deduplication prevents re-nudging the same stall
- **Deep interview lock overrides:** Auto-nudge is suppressed during deep-interview sessions

**Iteration control:**
- Default max 50 iterations (configurable)
- Mode state persisted via `state_write`/`state_read` with active/iteration/phase tracking
- Exclusive mode enforcement: Cannot start ralph while autopilot/autoresearch/ultrawork is active
- "The boulder never stops" hook message signals continuation

### Failure Handling

- If architect rejects verification: fix issues and re-verify (don't stop)
- If same issue recurs across 3+ iterations: report as fundamental problem
- Stop only for: missing credentials, unclear requirements, external service down, user says stop
- On stop: run `/cancel` for clean state cleanup

### Comparison to Doey's Stop Hooks and Worker Monitoring

| Aspect | OMX Ralph | Doey Workers |
|--------|----------|--------------|
| Persistence model | Mode state in `.omx/state/` with phases, session resume across restarts | In-memory only; stop hooks capture output but don't resume |
| Completion gate | Fresh test/build evidence + architect verification + deslop pass + regression recheck | Worker stop hooks capture output; Subtaskmaster validates |
| Stall recovery | Auto-nudge with 30+ stall patterns, semantic dedup, configurable TTL | No auto-nudge; workers run until complete or error |
| Session resume | Atomic state transfer when Codex restarts (`ralph-session-resume.ts`) | No resume — worker must restart from scratch |
| Iteration tracking | Explicit counter with max (default 50), persisted across sessions | No iteration tracking |
| Verification tiers | Tiered architect review (LOW/STANDARD/THOROUGH) based on change scope | Single-tier: Subtaskmaster reviews all output equally |
| Deslop/cleanup | Mandatory ai-slop-cleaner pass on changed files, then regression recheck | No post-completion cleanup pass |
| Proof of completion | Must show fresh test output, build output, lsp_diagnostics, architect approval | Workers emit PROOF_TYPE/PROOF before stopping |

**Key takeaway:** Ralph is a **durable, self-healing execution loop** with formal verification gates and session resume. Doey's workers are ephemeral executors with stop-hook capture but no persistence, resume, or auto-nudge.

---

## Madmax / High Mode Settings

### What They Configure

These are **CLI launch flags** that control Codex's security posture and reasoning depth.

**Key files:**
- `src/cli/constants.ts:1-9` (flag definitions)
- `src/cli/index.ts:178-187` (help text), `1059-1115` (normalizeCodexLaunchArgs)
- `src/config/models.ts` (model configuration, 236 lines)
- `src/team/model-contract.ts` (team worker model resolution, 204 lines)

### Flag Definitions

| Flag | What It Does | Codex Equivalent |
|------|-------------|-----------------|
| `--madmax` | **Bypasses Codex approvals and sandbox** (dangerous) | `--dangerously-bypass-approvals-and-sandbox` |
| `--high` | Sets reasoning effort to high | `-c model_reasoning_effort="high"` |
| `--xhigh` | Sets reasoning effort to extra-high | `-c model_reasoning_effort="xhigh"` |
| `--spark` | Routes team workers to a faster/cheaper model | Workers get `gpt-5.3-codex-spark`; leader unchanged |
| `--madmax-spark` | Combines bypass + spark workers | `--spark --madmax` |
| `--yolo` | Yolo mode (Codex native) | `--yolo` |

### Reasoning Effort Levels

Four levels (`src/team/model-contract.ts:23`): `low`, `medium`, `high`, `xhigh`

The `omx reasoning` command can persistently set reasoning effort in `config.toml`:
```
omx reasoning high    # persists to config.toml
omx reasoning         # shows current setting
```

CLI flags override config: `--high` or `--xhigh` on the command line takes precedence.

### Model Configuration Hierarchy

**Default models** (`src/config/models.ts:85-87`):
- Frontier (main): `gpt-5.4`
- Standard (subagents): `gpt-5.4-mini`
- Spark (low-complexity/fast): `gpt-5.3-codex-spark`

**Resolution order** (`src/config/models.ts:202-211`):
1. Mode-specific override in `.omx-config.json` (e.g., `"models": { "team": "gpt-4.1" }`)
2. `"default"` key in `.omx-config.json`
3. Environment variable `OMX_DEFAULT_FRONTIER_MODEL`
4. Hardcoded `DEFAULT_FRONTIER_MODEL`

**Agent model classes** (`src/team/model-contract.ts:181-191`):
- `fast` → spark/low-complexity model
- `frontier` → main default model
- `standard` → standard default model

### How Users Switch Modes

**At launch time:**
```bash
omx --madmax --high           # bypass + high reasoning (recommended default)
omx --xhigh                   # extra-high reasoning, no bypass
omx --madmax-spark             # bypass + spark workers
omx --spark                    # spark workers only
```

**Persistently:**
```bash
omx reasoning high             # writes to config.toml
omx reasoning low              # change back
```

**Per-mode in config:**
```json
{
  "models": {
    "default": "o4-mini",
    "team": "gpt-4.1"
  }
}
```

**Team worker inheritance** (`src/team/model-contract.ts:122-130`):
When `--madmax`, `--high`/`--xhigh`, or `--model` are passed to the leader, they are **inherited by team workers** via `OMX_TEAM_WORKER_LAUNCH_ARGS` and `OMX_TEAM_INHERIT_LEADER_FLAGS`.

### Comparison to Doey's Agent Model Settings

| Aspect | OMX | Doey |
|--------|-----|------|
| Security bypass | `--madmax` flag, user-initiated | No equivalent — tool restrictions enforced by `on-pre-tool-use.sh` |
| Reasoning effort | 4 levels (low/medium/high/xhigh), configurable per-session or persistent | Per-agent model selection in YAML frontmatter (model field) |
| Model tiers | 3 classes (frontier/standard/spark) with env/config overrides | Per-agent: agent definitions specify model directly |
| Mode-specific models | `.omx-config.json` allows per-mode model overrides | No per-mode overrides — each agent type has one model |
| Worker model inheritance | Leader flags automatically propagated to team workers | No inheritance — each worker agent definition is independent |
| Fast mode | `--spark` routes workers to cheaper model, leader unchanged | No "fast worker" mode |
| Persistent config | `omx reasoning high` writes to config.toml | Models defined in agent YAML, not user-configurable |

**Key takeaway:** OMX provides fine-grained, user-configurable model and reasoning controls at multiple levels (CLI flags, config file, environment variables). Doey's model settings are baked into agent definitions with no runtime user control.

---

## Key Takeaways

### 1. OMX treats workflow stages as formal pipeline stages with mathematical gates
Deep Interview uses quantitative ambiguity scoring (weighted dimension formulas) to decide when clarification is sufficient. Ralplan uses multi-agent consensus with formal verdicts. Doey's equivalent stages (Boss intent gathering, Subtaskmaster planning) are informal and judgment-based.

### 2. The deep-interview -> ralplan -> ralph pipeline is tightly integrated
Each stage produces structured artifacts (`.omx/specs/`, `.omx/plans/`, `.omx/state/`) that downstream stages consume via explicit handoff contracts. The spec from deep-interview is the requirements source of truth for ralplan, which produces the PRD and test specs that ralph executes against. Doey's stages communicate via send-keys text, losing structure.

### 3. Ralph's session resume and auto-nudge are significant reliability features
Ralph can survive Codex restarts by atomically transferring state between sessions (`ralph-session-resume.ts`). The auto-nudge system detects 30+ stall patterns and automatically pushes Codex forward. Doey has no equivalent — if a worker stops, it's gone.

### 4. The pre-execution gate prevents wasted work
Ralplan's vague-prompt interceptor redirects underspecified execution requests back to planning. This is a simple but powerful pattern: detect missing concrete anchors (file paths, function names, issue numbers) and redirect. Doey could benefit from a similar gate in the Taskmaster.

### 5. Model configuration is highly flexible in OMX
Three model tiers, per-mode overrides, environment variable fallbacks, leader-to-worker flag inheritance, and persistent reasoning settings. Doey's per-agent model settings in YAML are simpler but less flexible for user customization.

### 6. Deep Interview's input lock is a clever UX guard
During deep-interview, auto-approval shortcuts ("yes", "proceed", "continue") are blocked to prevent the agent from bypassing the interview. This prevents the common failure mode where an auto-nudge mechanism accidentally skips clarification steps.

### 7. The RALPLAN-DR structured deliberation format is reusable
The Principles / Decision Drivers / Viable Options / ADR structure for plan review is a well-defined template that could be adapted for Doey's Subtaskmaster planning output.
