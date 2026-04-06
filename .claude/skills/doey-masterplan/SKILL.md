---
name: doey-masterplan
description: Strategic planning with ultrathink research — multi-agent deep analysis, vertical phase design, and verified execution. Usage: /doey-masterplan <goal>
---

- Current tasks: !`doey task list 2>/dev/null || echo "No tasks"`
- Plans dir: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); echo "${PD:-.}/.doey/plans"'`
- Existing plans: !`bash -c 'PD=$(grep "^PROJECT_DIR=" "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env" 2>/dev/null | cut -d= -f2- | tr -d "\""); ls "${PD:-.}/.doey/plans/"*.md 2>/dev/null | head -10 || echo "None"'`

Create a strategic masterplan from a high-level goal or vision. Goal from ARGUMENTS (if empty, use AskUserQuestion to ask, then stop).

This is NOT a quick task planner — it's a deep, multi-phase strategic planning process that uses ultrathink research agents to challenge assumptions, explore the problem space exhaustively, and design vertical execution phases with verification gates between each.

Use `/doey-planned-task` instead if the goal is a single feature or straightforward change.

### Setup

Generate plan ID and create working directory:
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
PROJECT=$(tmux show-environment DOEY_PROJECT 2>/dev/null | cut -d= -f2-)
PROJECT_DIR=$(grep '^PROJECT_DIR=' "${RD}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
PROJECT_DIR="${PROJECT_DIR:-.}"
PLANS_DIR="${PROJECT_DIR}/.doey/plans"
PLAN_ID="masterplan-$(date +%Y%m%d-%H%M%S)"
MP_DIR="/tmp/doey/${PROJECT}/${PLAN_ID}"
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null)
mkdir -p "${MP_DIR}/research" "${PLANS_DIR}"
echo "Masterplan ID: ${PLAN_ID}"
echo "Working directory: ${MP_DIR}"
```

### Phase 0: Intent Interrogation

**Purpose:** Before any HOW, exhaustively explore WHY. Every decision in the masterplan traces back to clear intent. This phase challenges assumptions and establishes the north star for all subsequent phases.

**Instructions:**

1. Use ultrathink (extended thinking) to deeply analyze the stated goal. Do NOT jump to solutions. Instead, challenge the premise itself.

2. Work through these five interrogation questions, spending significant thought on each:

   **Q1 — True Intent:** What is the user *really* trying to achieve? Strip away the surface-level request. What outcome would make them say "yes, that's exactly what I needed" — even if the implementation looks nothing like what they described?

   **Q2 — Failure Modes:** What would make this a failure even if "completed"? Identify ways the goal could be technically delivered but practically useless. What does success look like from the perspective of someone who has never seen this project before?

   **Q3 — Unstated Assumptions:** What are the assumptions baked into the goal that nobody has questioned? What constraints are assumed that might not actually exist? What constraints exist that the goal ignores?

   **Q4 — Fresh User Test:** What would a fresh user — someone running `curl | bash` for the first time — expect from this? Does the goal serve their needs, or only the needs of someone already deep in the project?

   **Q5 — Simplification Challenge:** What is the absolute minimum version of this that delivers real value? What can we NOT do and still succeed? If we had to ship something useful in one day, what would it be?

3. For each question, write:
   - Your analysis (be thorough, be honest, be challenging)
   - Implications for the plan
   - Any risks or red flags discovered

4. Synthesize the five answers into a clear Intent Statement: 2-3 sentences that capture the true goal, the key constraints, and the definition of success.

5. Write the Intent Document using the Write tool to `${MP_DIR}/intent.md`:

```markdown
---
plan_id: <PLAN_ID>
goal: "<original goal from user>"
created: <ISO 8601 timestamp>
---

# Intent Document

## Original Goal
<The goal as stated by the user>

## Intent Interrogation

### Q1: True Intent
<analysis>

### Q2: Failure Modes
<analysis>

### Q3: Unstated Assumptions
<analysis>

### Q4: Fresh User Test
<analysis>

### Q5: Simplification Challenge
<analysis>

## Intent Statement
<2-3 sentence synthesis — the north star for all phases>

## Key Constraints
- <constraint 1>
- <constraint 2>

## Definition of Success
- <criterion 1>
- <criterion 2>

## Red Flags
- <any risks or concerns that must be addressed before proceeding>
```

6. After writing intent.md, present the Intent Statement and Red Flags to the user via AskUserQuestion. Ask them to confirm the intent is correct before proceeding to Phase 1. Options: "Correct, proceed to research", "Adjust intent", "Cancel".

If the user adjusts, revise the intent document and re-confirm. Do NOT proceed to Phase 1 without confirmed intent.

### Phase 1: Multi-Agent Deep Research Swarm

Launch up to 10 parallel research agents using the Agent tool. Each agent explores a different angle of the goal, guided by the Intent Document from Phase 0. All agents use ultrathink (extended thinking) for maximum depth.

#### 1.1 Define Research Angles

Each agent gets exactly one research angle and writes its report to `${MP_DIR}/research/agent-N-<angle>.md`:

| Agent | Angle | Output File | Research Question |
|-------|-------|-------------|-------------------|
| 1 | State of the art | `agent-1-state-of-art.md` | What exists in the ecosystem? What has been tried before — in this project and elsewhere? What worked, what failed, and why? |
| 2 | User journey | `agent-2-user-journey.md` | Walk through every user touchpoint end-to-end. Where does the current experience break? What would delight vs. frustrate a user? |
| 3 | Architecture implications | `agent-3-architecture.md` | What does this goal change structurally? Which subsystems are affected? What load-bearing abstractions get stressed? |
| 4 | Risk & failure modes | `agent-4-risks.md` | What kills this initiative? Enumerate failure modes: technical, operational, scope creep, performance. Rate likelihood and severity. |
| 5 | Dependencies & ordering | `agent-5-dependencies.md` | What blocks what? Map the dependency graph. Identify the critical path and potential parallelism. |
| 6 | Simplification | `agent-6-simplification.md` | What can we NOT do and still succeed? Strip the goal to its minimum viable form. Identify gold-plating and unnecessary complexity. |
| 7 | Testing strategy | `agent-7-testing.md` | How do we verify each phase actually works? Define test types needed (unit, integration, E2E). Identify what's hard to test and why. |
| 8 | Edge cases & fresh-install | `agent-8-edge-cases.md` | Does this survive real conditions? Test against: fresh install, no config, missing deps, partial state, interrupted operations, concurrent access. |
| 9 | Prior art in codebase | `agent-9-prior-art.md` | What patterns already exist in this codebase? What has been attempted before? What utilities, hooks, or conventions can be reused? |
| 10 | Devil's advocate | `agent-10-devils-advocate.md` | Argue against the entire approach. Why should we NOT do this? What alternative directions were dismissed too quickly? |

#### 1.2 Launch Research Agents in Parallel

Launch all 10 agents using the Agent tool. Send them in two parallel batches to avoid overwhelming the system.

**Batch A — Agents 1-5** (launch all 5 in a single message with 5 Agent tool calls):

For each agent in this batch, use the following prompt template (substitute the angle-specific values):

```
You are Research Agent N — "<ANGLE_NAME>" — for masterplan ${PLAN_ID}.
Project: ${PROJECT} at ${PROJECT_DIR}. Use absolute paths only.

## Intent Document
<Paste the full Intent Document from Phase 0 here>

## Your Research Angle
<RESEARCH_QUESTION from the table above>

## Instructions
1. Use ultrathink / extended thinking for deep analysis
2. Read relevant code, configs, docs, and git history in the project
3. Search broadly — check multiple directories, naming conventions, and patterns
4. Be thorough: this research informs the entire plan. Depth over speed
5. Write your findings to: ${MP_DIR}/research/agent-N-<angle>.md

## Report Format
Write your report using the Write tool to the output path above:

# Research Report: <Angle Name>
## Summary
<3-5 sentence executive summary>

## Key Findings
<Numbered list of concrete findings, each with evidence>

## Relevant Files & Code
<File paths with line numbers and brief descriptions>

## Implications for the Goal
<How your findings affect the masterplan — constraints, opportunities, warnings>

## Open Questions
<Unanswered questions that other agents or Phase 2 should address>

## Recommendations
<Actionable recommendations ranked by importance>

Stop when your report is written. Do not ask questions — make judgment calls.
```

**Batch B — Agents 6-10** (launch all 5 in a single message with 5 Agent tool calls):

Use the same prompt template, substituting the appropriate angle, question, and output path for agents 6-10.

> **Why two batches?** Launch Batch A first. Once all 5 Agent tool calls are sent, immediately launch Batch B in the next message. This keeps all 10 agents running concurrently while staying within practical tool-call limits per message.

#### 1.3 Verify Research Outputs

After both batches complete, verify all 10 reports were written:

```bash
EXPECTED=10
FOUND=$(ls "${MP_DIR}/research"/agent-*.md 2>/dev/null | wc -l)
echo "Research reports: ${FOUND}/${EXPECTED}"
if [ "$FOUND" -lt "$EXPECTED" ]; then
  echo "Missing reports:"
  for i in $(seq 1 10); do
    ls "${MP_DIR}/research"/agent-${i}-*.md >/dev/null 2>&1 || echo "  - Agent ${i} (missing)"
  done
fi
```

#### 1.4 Handle Missing Reports

If any agents failed to produce reports:

1. Check which angles are missing from the verification output
2. Re-launch ONLY the missing agents using the same prompt template and angle
3. Run verification again
4. If an agent fails twice, note the gap — Phase 2 (Synthesis) will work with available reports and flag the missing angle as an open question

#### 1.5 Phase 1 Complete

All research reports are now in `${MP_DIR}/research/`. Proceed to Phase 2 (Synthesis) which will read and merge all reports into a unified understanding document.

**Phase 1 outputs:**
- `${MP_DIR}/research/agent-1-state-of-art.md` through `agent-10-devils-advocate.md`
- Up to 10 deep-research reports, each with findings, evidence, and recommendations

### Phase 2: Synthesis

Merge all 10 research reports into a unified understanding. Contradictions are expected — resolve them, don't hide them.

#### 2.1 Read All Research Reports

Spawn a single ultrathink Agent to read and synthesize all reports:

```
Spawn Agent (ultrathink):
  Task: Read all 10 research reports from ${MP_DIR}/research/
  and produce a unified synthesis document.

  For each report:
  1. Extract key findings, recommendations, and warnings
  2. Tag each finding with the agent angle it came from (state-of-art, user-journey, architecture, risk, dependencies, simplification, testing, edge-cases, prior-art, devils-advocate)

  Then:
  3. Identify consensus — findings that 3+ agents agree on (these are high-confidence)
  4. Identify contradictions — where agents directly disagree (these need resolution)
  5. Identify blind spots — important areas no agent covered adequately
  6. Resolve each contradiction with a reasoned judgment: which side is right, why, and what's the risk if wrong
  7. Rank all findings by impact on the original intent (from Phase 0)
```

#### 2.2 Produce Synthesis Document

The Agent writes the synthesis to `${MP_DIR}/synthesis.md`:

```markdown
# Synthesis — <Goal Title>

## Intent Recap
<One-paragraph restatement of the intent from Phase 0>

## Consensus Findings
<Findings that 3+ research agents agreed on, ranked by impact>
- **Finding**: <description>
  - **Sources**: <which agents found this>
  - **Impact**: <how this affects the plan>

## Resolved Contradictions
<Where agents disagreed, with resolution>
- **Contradiction**: <Agent X says A, Agent Y says B>
  - **Resolution**: <which side wins and why>
  - **Risk if wrong**: <what happens if this judgment is incorrect>

## Critical Disagreements (Unresolved)
<Contradictions that need user input — flag these for Phase 4 presentation>
- **Disagreement**: <description>
  - **Option A**: <position and rationale>
  - **Option B**: <position and rationale>
  - **Recommendation**: <leaning and why>

## Blind Spots
<Important areas that need more investigation or user clarification>

## Constraints Discovered
<Hard constraints that emerged from research — these bound the solution space>

## Simplification Opportunities
<Things we can skip or defer without losing core value — from Agent 6 especially>
```

#### 2.3 Validate Synthesis

Before proceeding to Phase 3, verify:
- Every research report was read (10 files in `${MP_DIR}/research/`)
- Every contradiction is either resolved or flagged as unresolved
- The synthesis traces back to the Phase 0 intent — nothing drifted
- Simplification opportunities are concrete, not vague ("remove X" not "consider simplifying")

If any report is missing or unreadable, note it in Blind Spots and continue — don't block the pipeline.

### Phase 3: Vertical Phase Design

Design the implementation as vertical slices — each phase delivers a working, testable, valuable increment. NOT horizontal layers (backend first, then frontend, then tests). Every phase must stand on its own.

#### 3.1 Design Vertical Phases

Spawn a single ultrathink Agent to design phases from the synthesis:

```
Spawn Agent (ultrathink):
  Inputs:
  - ${MP_DIR}/intent.md (Phase 0 output)
  - ${MP_DIR}/synthesis.md (Phase 2 output)

  Task: Design a sequence of vertical implementation phases.

  Rules for each phase:
  1. Independently deployable — can ship without later phases existing
  2. Independently testable — has its own verification criteria
  3. Valuable alone — a user would notice or benefit from this phase, even if nothing else ships
  4. Small enough to verify — a single Subtaskmaster + workers can complete and verify it
  5. No phase is just "scaffolding" or "setup" — if it doesn't produce visible value, merge it into the phase that does

  Rules for phase ordering:
  1. Most valuable / highest-risk first — validate assumptions early
  2. Each phase builds on verified output from the previous phase
  3. If Phase N fails verification, later phases don't start — the plan surfaces for re-evaluation
  4. Minimize coupling between phases — Phase N+1 should need minimal awareness of Phase N internals

  Between every pair of phases, define explicit verification gates.
```

#### 3.2 Produce Phases Document

The Agent writes to `${MP_DIR}/phases.md`:

```markdown
# Implementation Phases — <Goal Title>

## Overview
- **Total phases**: <count>
- **Estimated scope**: <workers x phases rough estimate>
- **Critical path**: <which phases are highest risk>

## Phase 1: <Phase Title>

### What it delivers
<One paragraph: what a user can see, do, or verify after this phase ships>

### Changes
- <file or component>: <what changes and why>
- <file or component>: <what changes and why>

### Verification Gate
Before Phase 2 can start, ALL of these must pass:
- [ ] **Test**: <specific test that must pass — not "tests pass" but which tests>
- [ ] **Behavior**: <specific user-visible behavior to verify — what to do and what to expect>
- [ ] **Demo**: <what you can demo to prove this phase works>

### Risks
- <risk specific to this phase>: <mitigation>

---

## Phase 2: <Phase Title>

### What it delivers
...

### Changes
...

### Verification Gate
...

### Risks
...

---

(repeat for each phase)

## Phase Dependencies
<Diagram or ordered list showing which phases depend on which>
<Call out any phases that could run in parallel>

## Unresolved Questions for User
<Questions from the synthesis that affect phase design — present these in Phase 4>
```

#### 3.3 Validate Phase Design

Before proceeding to Phase 4, verify each phase against the checklist:

For every phase:
- [ ] Can it deploy independently? (If removing all later phases, does this still work?)
- [ ] Does it have concrete verification criteria? (Not "it works" — specific tests, behaviors, demos)
- [ ] Does it deliver visible value? (If this were the last phase that shipped, would it matter?)
- [ ] Is it small enough? (Can a single Subtaskmaster team verify it completely?)

For the overall sequence:
- [ ] Highest-risk phases come first (fail fast, not fail late)
- [ ] No phase is pure scaffolding — every phase has user-facing value
- [ ] Verification gates are binary — pass/fail, no "mostly works"
- [ ] The phase sequence traces back to the Phase 0 intent

If any phase fails the checklist, redesign it — split it, merge it, or reorder it. Do not proceed with phases that violate these rules.

### Phase 4: Plan Presentation & Approval

Present the complete masterplan to the user. This is the decision gate — nothing becomes a task without explicit approval. Show the full picture: intent, phases, risks, unresolved questions.

#### 4.1 Compile Plan Summary

Gather outputs from all previous phases into a presentation:

```
Read:
- ${MP_DIR}/intent.md (Phase 0)
- ${MP_DIR}/synthesis.md (Phase 2)
- ${MP_DIR}/phases.md (Phase 3)
```

Build a concise summary covering:
1. **Intent** — one paragraph from Phase 0: what we're really trying to achieve
2. **Phase Breakdown** — for each phase: title, what it delivers, estimated scope (one line each)
3. **Verification Gates** — the key pass/fail criteria between phases
4. **Risk Assessment** — top 3-5 risks across all phases, with mitigations
5. **Unresolved Questions** — from the synthesis `Critical Disagreements` and `Blind Spots` sections. These need user input before execution
6. **Simplification Opportunities** — what we chose NOT to do and why (from synthesis)

#### 4.2 Present to User

Use AskUserQuestion to show the plan summary and request a decision. Format the question as:

```
## Masterplan: <Goal Title>

### Intent
<One paragraph — why we're doing this, not what>

### Phases (<count> total)
1. **<Phase 1 Title>** — <what it delivers> (<scope estimate>)
   Gate: <key verification criterion>
2. **<Phase 2 Title>** — <what it delivers> (<scope estimate>)
   Gate: <key verification criterion>
...

### Top Risks
- <Risk 1>: <mitigation>
- <Risk 2>: <mitigation>

### Unresolved Questions
These need your input before we can proceed:
1. <Question from synthesis — Option A vs Option B, with recommendation>
2. ...

### What's excluded (by design)
- <Simplification 1> — <why it's safe to skip>

---
Options:
- **Approve and create tasks** — generates phased tasks and dispatches to Taskmaster
- **Modify plan** — tell me what to change, I'll update and re-present
- **Send back for more research** — specific question or angle to investigate further
- **Cancel** — discard the masterplan
```

#### 4.3 Handle User Response

**If "Approve and create tasks":**
1. Resolve the numeric plan ID:
   ```bash
   NUMERIC_PLAN_ID=$(( $(ls "${PLANS_DIR}"/*.md 2>/dev/null | sed 's/.*\///' | grep -E '^[0-9]+\.md$' | sed 's/\.md//' | sort -n | tail -1) + 1 )) 2>/dev/null || NUMERIC_PLAN_ID=1
   ```
2. Write the final plan to `${PLANS_DIR}/${NUMERIC_PLAN_ID}.md`:
   ```markdown
   ---
   plan_id: <NUMERIC_PLAN_ID>
   title: "<Goal Title>"
   status: active
   type: masterplan
   created: <ISO 8601 timestamp>
   updated: <ISO 8601 timestamp>
   phases: <count>
   ---

   # Masterplan: <Goal Title>

   ## Intent
   <Full intent statement from Phase 0>

   ## Phases

   ### Phase 1: <Title>
   <Full phase content from phases.md — changes, verification gate, risks>

   ### Phase 2: <Title>
   ...

   ## Risk Assessment
   <Consolidated risks>

   ## Resolved Questions
   <User's answers to unresolved questions from 4.2>

   ## Research Artifacts
   - Intent: ${MP_DIR}/intent.md
   - Research: ${MP_DIR}/research/
   - Synthesis: ${MP_DIR}/synthesis.md
   - Phases: ${MP_DIR}/phases.md
   ```
3. Proceed to Phase 5.

**If "Modify plan":**
1. Read the user's modification request
2. Update the relevant section (intent, phases, risks, or scope)
3. If the change affects phase design, re-run Phase 3 validation checklist against modified phases
4. Re-present the updated plan via AskUserQuestion (loop back to 4.2)
5. Do NOT proceed to Phase 5 until explicitly approved

**If "Send back for more research":**
1. Read the user's specific research question or angle
2. Spawn a targeted research Agent (ultrathink) with the specific question, reading existing research for context
3. Append findings to the synthesis document
4. Re-run Phase 3 if the new findings affect phase design
5. Re-present the updated plan via AskUserQuestion (loop back to 4.2)

**If "Cancel":**
1. Write a summary of what was researched to `${MP_DIR}/cancelled.md` (the research is still valuable)
2. Report to user: "Masterplan cancelled. Research artifacts preserved at ${MP_DIR}/"
3. Stop

#### 4.4 Validate Before Proceeding

Before moving to Phase 5, confirm:
- [ ] User explicitly chose "Approve and create tasks"
- [ ] All unresolved questions from the synthesis have user-provided answers
- [ ] Plan file exists at `${PLANS_DIR}/${NUMERIC_PLAN_ID}.md` with `status: active`
- [ ] Plan frontmatter has all required fields (plan_id, title, status, type, created, updated, phases)
- [ ] Every phase in the plan has a verification gate with concrete pass/fail criteria

### Phase 5: Task Generation

Convert the approved masterplan into executable Doey tasks. Each implementation phase becomes a task with subtasks for implementation, verification, and review. Dispatch is sequential-phased — phase N+1 only starts after phase N passes its verification gate.

#### 5.1 Create Tasks from Phases

For each phase in the approved plan, create a task:

```bash
# Phase 1
TASK_1=$(doey task create \
  --title "Masterplan Phase 1: <Phase 1 Title>" \
  --type "${PHASE_1_TYPE:-feature}" \
  --description "Phase 1 of masterplan #${NUMERIC_PLAN_ID}: <Goal Title>

What this phase delivers:
<Phase 1 delivery description from phases.md>

Changes:
<File/component change list from phases.md>

Plan: ${PLANS_DIR}/${NUMERIC_PLAN_ID}.md
Research: ${MP_DIR}/")
echo "Created task #${TASK_1} for Phase 1"

# Repeat for each phase...
```

#### 5.2 Add Subtasks

Each task gets three categories of subtasks — implementation, verification gate, and review:

```bash
# Implementation subtasks (from the "Changes" section of each phase)
doey task subtask add --task-id "$TASK_1" --description "Implement: <change 1 description>"
doey task subtask add --task-id "$TASK_1" --description "Implement: <change 2 description>"

# Verification gate subtasks (from the "Verification Gate" section)
doey task subtask add --task-id "$TASK_1" --description "Verify: <test that must pass>"
doey task subtask add --task-id "$TASK_1" --description "Verify: <behavior to confirm>"
doey task subtask add --task-id "$TASK_1" --description "Verify: <demo that must work>"

# Review subtask
doey task subtask add --task-id "$TASK_1" --description "Review: Phase 1 passes all verification gates — ready for Phase 2"
```

#### 5.3 Link Tasks to Plan

Attach plan metadata to each task:

```bash
doey task update --id "$TASK_1" --field "TASK_PLAN_ID" --value "$NUMERIC_PLAN_ID"
doey task update --id "$TASK_1" --field "intent" --value "<intent summary from Phase 0>"
doey task update --id "$TASK_1" --field "success_criteria" --value "<verification gate items, comma-separated>"
doey task update --id "$TASK_1" --field "dispatch_plan" --value "sequential-phased"
doey task update --id "$TASK_1" --field "masterplan_phase" --value "1"
doey task update --id "$TASK_1" --field "masterplan_total_phases" --value "<total phase count>"
doey task update --id "$TASK_1" --field "masterplan_next_task" --value "$TASK_2"
```

Set the chain: each task's `masterplan_next_task` points to the next phase's task ID. The last phase has no `masterplan_next_task`.

#### 5.4 Dispatch: Dedicated Masterplan Window (Recommended) or Taskmaster

Choose a dispatch mode. The dedicated masterplan window is recommended — it gives the plan its own workspace with a live viewer. Fall back to Taskmaster dispatch if the masterplan team definition is unavailable.

**Option A — Dedicated masterplan window (recommended):**

Spawn a dedicated team window from the `masterplan` team definition. The planner and viewer share the plan file via `PLAN_FILE` env var.

```bash
# Write the plan file path to runtime so the masterplan team can pick it up
PLAN_FILE="${PLANS_DIR}/${NUMERIC_PLAN_ID}.md"
echo "PLAN_FILE=${PLAN_FILE}" > "${RD}/masterplan-${NUMERIC_PLAN_ID}.env"
echo "MASTERPLAN_ID=${PLAN_ID}" >> "${RD}/masterplan-${NUMERIC_PLAN_ID}.env"
echo "TASK_ID=${TASK_1}" >> "${RD}/masterplan-${NUMERIC_PLAN_ID}.env"
echo "TOTAL_PHASES=<total phase count>" >> "${RD}/masterplan-${NUMERIC_PLAN_ID}.env"

# Export PLAN_FILE so the masterplan team's viewer and planner can access it
export PLAN_FILE

# Spawn the dedicated masterplan window
doey add-team masterplan
```

After the window spawns:
- The **Planner** pane (pane 0) reads `PLAN_FILE` from the environment and orchestrates phase execution
- The **Viewer** pane runs `masterplan-viewer.sh` watching the plan file for live rendering
- **Worker** panes are initially idle, waiting for the Planner to dispatch subtasks

The plan file at `${PLANS_DIR}/${NUMERIC_PLAN_ID}.md` is the integration point — the Planner updates phase statuses in the file, and the Viewer re-renders on each change.

Then notify Taskmaster that a masterplan window was spawned (informational, not a dispatch request):

```bash
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"

doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
  --subject "masterplan_spawned" \
  --body "MASTERPLAN_ID: ${PLAN_ID}
PLAN_FILE: ${PLAN_FILE}
TASK_ID: ${TASK_1}
PHASES: <total>
DISPATCH_MODE: dedicated-window

Masterplan '${PLAN_ID}' has its own dedicated window.
Plan file: ${PLAN_FILE}
The masterplan team handles phase sequencing and verification gates internally."
doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
```

**Option B — Fallback to Taskmaster dispatch:**

Use this if `doey add-team masterplan` fails (e.g., team definition not found). Falls back to the standard dispatch-to-Taskmaster path.

```bash
TASKMASTER_PANE=$(grep '^TASKMASTER_PANE=' "${RD}/session.env" 2>/dev/null | cut -d= -f2-)
TASKMASTER_PANE="${TASKMASTER_PANE:-1.0}"

doey msg send --to "${SESSION_NAME}:${TASKMASTER_PANE}" --from "${DOEY_PANE_ID}" \
  --subject "masterplan_dispatch" \
  --body "MASTERPLAN_ID: ${PLAN_ID}
TASK_ID: ${TASK_1}
PHASE: 1 of <total>
TITLE: Masterplan Phase 1: <Phase 1 Title>
PRIORITY: P1
DISPATCH_MODE: sequential-phased
NEXT_TASK: ${TASK_2}

Masterplan Phase 1 — dispatch to a team.
Plan: ${PLANS_DIR}/${NUMERIC_PLAN_ID}.md
Research: ${MP_DIR}/

IMPORTANT: This is a sequential-phased masterplan. After Phase 1 passes ALL verification gates:
1. Run the verification gate checklist from the plan
2. If all pass: dispatch Phase 2 (task #\${TASK_2}) with the same sequential-phased instructions
3. If any fail: surface to Boss for re-evaluation — do NOT auto-dispatch the next phase

Verification gates for Phase 1:
<gate items from phases.md>"
doey msg trigger --pane "${SESSION_NAME}:${TASKMASTER_PANE}"
```

**Decision logic:** Try Option A first. If `doey add-team masterplan` exits non-zero (definition not found), fall back to Option B automatically.

#### 5.5 Report to User

Output a final summary. Adjust the dispatch mode line based on which option was used.

**If dedicated window (Option A):**

```
## Masterplan Dispatched — Dedicated Window

**Plan:** ${PLANS_DIR}/${NUMERIC_PLAN_ID}.md
**Phases:** <count>
**Dispatch mode:** Dedicated masterplan window (plan viewer + phased execution)

| Phase | Task | Title | Status |
|-------|------|-------|--------|
| 1 | #${TASK_1} | <Title> | Active (in masterplan window) |
| 2 | #${TASK_2} | <Title> | Waiting (after Phase 1 gate) |
| 3 | #${TASK_3} | <Title> | Waiting (after Phase 2 gate) |
...

The masterplan has its own window with a live plan viewer.
The Planner manages phase sequencing — each phase is verified before the next starts.
Research artifacts: ${MP_DIR}/
```

**If Taskmaster fallback (Option B):**

```
## Masterplan Dispatched

**Plan:** ${PLANS_DIR}/${NUMERIC_PLAN_ID}.md
**Phases:** <count>
**Dispatch mode:** Sequential-phased via Taskmaster (each phase verified before next starts)

| Phase | Task | Title | Status |
|-------|------|-------|--------|
| 1 | #${TASK_1} | <Title> | Dispatched |
| 2 | #${TASK_2} | <Title> | Waiting (after Phase 1 gate) |
| 3 | #${TASK_3} | <Title> | Waiting (after Phase 2 gate) |
...

Phase 1 is now with Taskmaster for team assignment.
Research artifacts: ${MP_DIR}/
```

#### 5.6 Validate Dispatch

After dispatch, confirm:
- [ ] Every phase has a corresponding task with subtasks
- [ ] Every task is linked to the plan via `TASK_PLAN_ID`
- [ ] Tasks form a chain via `masterplan_next_task`
- [ ] Only Phase 1 was dispatched — remaining phases are queued
- [ ] If dedicated window: masterplan team window exists and viewer is watching the plan file
- [ ] If Taskmaster fallback: dispatch message includes verification gate criteria and sequential-phased instructions
- [ ] User received the summary with all task IDs, plan path, and dispatch mode

### Rules
- Always use AskUserQuestion for user interaction — never inline questions
- Use ultrathink (extended thinking) for all deep analysis (Phases 0, 1, 2, 3)
- Use the Agent tool for research agents (Phase 1) and synthesis/design agents (Phases 2-3)
- Use AskUserQuestion at Phase 0 (intent confirmation) and Phase 4 (plan approval)
- Sequential phases — never skip or reorder. Phase N must complete before Phase N+1 starts
- Do NOT jump to solutions — challenge assumptions first (Phase 0 is the north star)
- The Intent Document guides all later phases — if a phase drifts from intent, fix the phase
- Write all research, synthesis, and working files to `${MP_DIR}/`
- Write the final approved plan to `${PLANS_DIR}/<id>.md`
- All file paths must be absolute
- If the goal is simple, redirect to `/doey-planned-task` or `/doey-instant-task`
- Use `doey task create` for task generation — never duplicate the logic
- Prefer dedicated masterplan window (`doey add-team masterplan`) — fall back to Taskmaster dispatch only if the team definition is unavailable
- The plan file at `${PLANS_DIR}/<id>.md` is the integration point between planner and viewer — ensure Phase 4 writes the final plan before Phase 5 spawns the window
