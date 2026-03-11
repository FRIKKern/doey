# Skill: doey-research

Dispatch a research & planning task to a worker with guaranteed report-back. The worker investigates thoroughly, then proposes a plan with alternatives. The worker cannot stop until it writes a structured report.

## Usage
`/doey-research`

## Prompt
You are dispatching a research task to a Claude Code worker instance in TMUX. The worker's Stop hook blocks it from finishing until a report file is written.

### Read Project Context

**Before dispatching**, discover the runtime directory and read the session manifest:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This gives you:
- `SESSION_NAME` — tmux session name
- `PROJECT_DIR` — absolute path to the project directory
- `PROJECT_NAME` — human-readable project name
- `WORKER_PANES` — list of worker pane IDs
- `WATCHDOG_PANE` — the watchdog pane ID

**Always use `${SESSION_NAME}` in all tmux commands.**

### Dispatch Function

**Step 1: Identify the task and target worker.**

Determine what to investigate. Pick an idle worker:

```bash
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -3
```

Look for the `❯` prompt. If busy, pick a different one.

Also check for reservation before selecting a worker:
```bash
PANE_SAFE=$(echo "${SESSION_NAME}:0.X" | tr ':.' '_')
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  EXPIRY=$(head -1 "$RESERVE_FILE")
  if [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ]; then
    echo "Reserved — pick another"
  fi
fi
```

**Step 2: Create the task marker file.**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_PANE="${SESSION_NAME}:0.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')

mkdir -p "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports"

cat > "${RUNTIME_DIR}/research/${PANE_SAFE}.task" << 'MARKER'
<research question or goal here>
MARKER

rm -f "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

**Step 3: Kill old session and start fresh Claude.**

```bash
PANE_PID=$(tmux display-message -t "${TARGET_PANE}" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1

tmux send-keys -t "${TARGET_PANE}" "claude --dangerously-skip-permissions --model opus" Enter
sleep 8
```

**Step 4: Rename the pane.**

```bash
tmux send-keys -t "${TARGET_PANE}" "/rename research-<short-topic>" Enter
sleep 1
```

**Step 5: Write and dispatch the task prompt.**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_PANE="${SESSION_NAME}:0.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"

mkdir -p "${RUNTIME_DIR}"
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a Senior Research & Planning Agent on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

## Research Task
<QUESTION_OR_GOAL>

## Scope
<OPTIONAL: specific files, directories, or areas to investigate>

## Instructions

### Phase 1: Research (use Agent Swarm)

**You MUST use the Agent tool to spawn subagents for parallel research.** Do not serially read files yourself — launch multiple agents simultaneously to investigate different aspects of the problem.

#### How to use the Agent tool:
- Spawn agents using the \`Agent\` tool with a \`subagent_type\` parameter
- **Available subagent types:**
  - \`"Explore"\` — Fast codebase search. Use for finding files by pattern, searching code for keywords, understanding structure. Specify thoroughness: "quick", "medium", or "very thorough".
  - \`"Plan"\` — Architecture analysis. Use for designing implementation strategies, identifying trade-offs, considering dependencies.
  - \`"general-purpose"\` — Multi-step research. Use for complex investigations that need multiple rounds of searching and reading.
- **Launch multiple agents in a single message** to maximize parallelism
- Each agent returns its findings to you — synthesize all results into your report

#### Research strategy:
1. **Identify 3-5 research questions** that together cover the full scope of the task.
2. **Spawn one agent per question** — all in a single message for maximum parallelism. Examples:
   - Agent 1 (Explore): "Find all files matching X pattern and show how Y is implemented"
   - Agent 2 (Explore): "Search for all usages of Z and map the dependency graph"
   - Agent 3 (general-purpose): "Read files A, B, C and document the conventions used"
   - Agent 4 (Plan): "Analyze the architecture of module X and identify extension points"
3. **Synthesize findings** from all agents into a coherent picture.
4. If initial findings reveal gaps, spawn a **second wave** of agents to fill them.

#### Example agent dispatch:
\`\`\`
// In a single message, spawn 3 agents:
Agent(subagent_type="Explore", prompt="Find all hook-related files in ${PROJECT_DIR}. Search for 'hook', 'UserPromptSubmit', 'Stop' patterns. Report file paths, what each does, and how they connect.", description="explore hooks")

Agent(subagent_type="Explore", prompt="Find all CLI command files and shell scripts in ${PROJECT_DIR}. Map which commands exist, their entry points, and shared utilities.", description="explore CLI")

Agent(subagent_type="general-purpose", prompt="Read ${PROJECT_DIR}/install.sh and ${PROJECT_DIR}/shell/doey.sh. Document the install flow, project registration, and session launch sequence. Note all directory paths used.", description="analyze install flow")
\`\`\`

**Important:** Always spawn at least 2 agents in parallel. Serial file reading is too slow — use the swarm.

### Phase 2: Propose a Plan
After research, propose a concrete plan. If there are multiple reasonable approaches, present them as alternatives:

- **Option A (Recommended):** The approach you believe is best. Explain WHY in detail — what makes this the right choice (simplicity, reliability, consistency with existing patterns, performance, etc.)
- **Option B:** An alternative approach. Explain tradeoffs vs A.
- **Option C:** (if applicable) Another alternative.

For the **recommended option**, include complete ready-to-dispatch task prompts that the Manager can copy-paste directly to workers. Each task prompt must include:
- Project name and directory
- "All file paths should be absolute"
- Exact file paths to work on
- What to change and why
- Patterns/conventions to follow (with examples from the codebase)
- Acceptance criteria and constraints

### Phase 3: Write Report
Write your report to this EXACT path:
${REPORT_PATH}

Use this exact structure:

## Research & Planning Report
**Topic:** <the research question or goal>
**Pane:** ${TARGET_PANE}
**Time:** <current timestamp>

### Summary
(2-3 sentence executive summary — what you found and what you recommend)

### Findings
(detailed research findings — code snippets, file paths, architecture notes, dependencies)

### Key Files
(bulleted list of relevant files with brief descriptions)

### Proposed Plan

#### Option A (Recommended): <short name>
**Why this is the best approach:**
(detailed reasoning — 3-5 sentences explaining why this option wins)

**Workers needed:** N
**Waves:** N

##### Wave 1 (parallel)

###### Task 1: [short-name]
**Rename:** [pane title]
**Files:** [absolute file paths]
**Prompt:**
\`\`\`
You are a worker on the Doey for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

[COMPLETE task instructions — ready to dispatch as-is]
\`\`\`

###### Task 2: [short-name]
...

##### Wave 2 (after Wave 1 completes)
...

##### Verification
(specific commands to run, files to check)

#### Option B: <short name>
**Approach:** (brief description)
**Tradeoffs vs A:** (why A is better, or when B might be preferred)
**Workers needed:** N

#### Option C: <short name>
(if applicable — omit if only two reasonable approaches exist)

### Risks
(what could go wrong with the recommended approach + mitigations)

## IMPORTANT
Your Stop hook will block you from finishing until the report file exists at the path above. Write the report using the Write tool to the EXACT path shown. Do not skip or abbreviate. Task prompts in the recommended option must be COMPLETE and ready to dispatch.
TASK

tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "${TARGET_PANE}"
sleep 0.5
tmux send-keys -t "${TARGET_PANE}" Enter
rm "$TASKFILE"
```

**Step 6: Verify dispatch.**

```bash
sleep 5
tmux capture-pane -t "${TARGET_PANE}" -p -S -5
```

If idle prompt with pasted text but no processing, send Enter again:

```bash
tmux send-keys -t "${TARGET_PANE}" Enter
```

### Reading Reports

After the worker finishes (shows idle), read the report:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

TARGET_PANE="${SESSION_NAME}:0.X"
PANE_SAFE=$(echo "$TARGET_PANE" | tr ':.' '_')
cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

### Acting on the Report (for the Manager)

1. Read the report and present a concise summary to the user:
   - What was found
   - The recommended option (A) with reasoning
   - Brief mention of alternatives (B, C)
2. Ask the user which option to proceed with (or confirm recommended)
3. On confirmation, dispatch using the ready-to-paste task prompts from the report
4. Monitor completion, dispatch subsequent waves
5. Run verification steps from the report

### Cleanup

Reports persist in `${RUNTIME_DIR}/reports/` until manually cleaned. Task markers in `${RUNTIME_DIR}/research/` are auto-cleaned by the Stop hook.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
rm -f "${RUNTIME_DIR}/research/"*.task
rm -f "${RUNTIME_DIR}/reports/"*.report
```

### Rules

1. **Always create the task marker BEFORE dispatching** — the Stop hook needs it to enforce reporting
2. **Always clear any old report file before dispatching** — stale reports would bypass enforcement
3. **The `PANE_SAFE` variable must match exactly** — full pane reference with `:` and `.` replaced by `_`
4. **Include the report path in the task prompt** — the worker needs to know where to write
