# Skill: doey-research

Dispatch a research & planning task to a worker with guaranteed report-back. The worker investigates thoroughly using parallel Agent subagents, then proposes a plan with alternatives. The worker cannot stop until it writes a structured report.

## Usage
`/doey-research`

## Prompt
You are dispatching a research task to a Claude Code worker instance in TMUX. The worker's Stop hook blocks it from finishing until a report file is written.

### Project Context (read once per Bash call)

Every Bash call that touches tmux must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `PASTE_SETTLE_MS` (default 500). **Always use `${SESSION_NAME}`** — never hardcode session names.

### Copy-mode pattern

`tmux copy-mode -q -t "$PANE" 2>/dev/null` — exits copy-mode (idempotent, always safe). **Run this before every `paste-buffer` and `send-keys`** throughout the dispatch. Copy-mode silently swallows all input.

### Step 1: Pick an idle, unreserved worker

**Always check before dispatching.** First verify the pane is not reserved, then check if it's idle.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE_SAFE=$(echo "${SESSION_NAME}:0.X" | tr ':.' '_')
RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
if [ -f "$RESERVE_FILE" ]; then
  EXPIRY=$(head -1 "$RESERVE_FILE")
  if [ "$EXPIRY" = "permanent" ] || [ "$(date +%s)" -lt "$EXPIRY" ]; then
    echo "Pane is reserved — skip this worker, pick another"
  fi
fi

# Check idle (look for ❯ prompt; if you see thinking/working/tool output — busy)
tmux copy-mode -q -t "${SESSION_NAME}:0.X" 2>/dev/null
tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -3
```

**Never dispatch to a RESERVED pane.** If all workers are reserved, report to the user and wait.

### Step 2: Create task marker and clear old report

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

### Step 3: Kill old session and start fresh Claude

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"

# 1. Exit copy-mode
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 2. Kill current Claude process by PID
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
sleep 3

# 3. Verify it died — SIGKILL if not
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
[ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null && sleep 1

# 4. Exit copy-mode (killing can trigger scroll)
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 5. Start fresh Claude
tmux send-keys -t "$PANE" "claude --dangerously-skip-permissions --model opus" Enter

# 6. Wait for boot
sleep 8

# 7. Exit copy-mode
tmux copy-mode -q -t "$PANE" 2>/dev/null

# 8. Rename pane
tmux send-keys -t "$PANE" "/rename research-<short-topic>" Enter
sleep 1
```

### Step 4: Write and dispatch the task prompt

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"
PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
REPORT_PATH="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"

TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << TASK
You are a Senior Research & Planning Agent on the Doey team for project: ${PROJECT_NAME}
Project directory: ${PROJECT_DIR}
All file paths should be absolute.

## Research Task
<QUESTION_OR_GOAL>

## Scope
<OPTIONAL: specific files, directories, or areas to investigate>

## Instructions

### Phase 1: Research (use Agent Swarm)

**You MUST use the Agent tool to spawn subagents for parallel research.** Do not serially read files — launch multiple agents simultaneously in a single message.

**Strategy:**
1. Identify 3-5 research questions covering the full scope.
2. Spawn one agent per question — all in a single message for parallelism.
   - \`Explore\` — fast codebase search (files, patterns, keywords). Set thoroughness: "quick"/"medium"/"very thorough".
   - \`Plan\` — architecture analysis, trade-offs, dependencies.
   - \`general-purpose\` — multi-step research needing multiple rounds.
3. Combine all agent outputs into the Findings section. If gaps remain, spawn a second wave.

**Example invocation (single message, 3 agents):**

Agent tool call 1:
  subagent_type: "Explore"
  prompt: "Find all hook files in ${PROJECT_DIR}. Map their connections and call chains."
  description: "explore hooks"

Agent tool call 2:
  subagent_type: "Explore"
  prompt: "Find all CLI commands and shell scripts in ${PROJECT_DIR}. Map entry points and dependencies."
  description: "explore CLI"

Agent tool call 3:
  subagent_type: "general-purpose"
  prompt: "Read install.sh and doey.sh in ${PROJECT_DIR}. Document the full install flow, paths created, and files copied."
  description: "analyze install flow"

### Phase 2: Propose a Plan

Present alternatives:
- **Option A (Recommended):** Best approach with detailed reasoning.
- **Option B:** Alternative with tradeoffs vs A.
- **Option C:** (if applicable)

For the recommended option, include **complete ready-to-dispatch task prompts** with: project name/dir, absolute paths, exact files, what to change, patterns to follow, acceptance criteria.

### Phase 3: Write Report

Write to this EXACT path using the Write tool: ${REPORT_PATH}

**REQUIRED sections** (do not omit any):

\`\`\`
## Research & Planning Report
**Topic:** <question>  |  **Pane:** ${PANE}  |  **Time:** <timestamp>

### Summary
(2-3 sentence executive summary)

### Findings
(detailed findings from all agent outputs — code snippets, file paths, architecture, dependencies)

### Key Files
(bulleted list of important files with brief descriptions)

### Proposed Plan

#### Option A (Recommended): <name>
**Why:** (3-5 sentences)
**Workers:** N  |  **Waves:** N

##### Wave 1 (parallel)
###### Task 1: [short-name]
**Rename:** [title]  |  **Files:** [paths]
**Prompt:** [COMPLETE dispatch-ready prompt]

##### Wave 2 (after Wave 1)
...

##### Verification
(commands to run, files to check)

#### Option B: <name>
**Approach/Tradeoffs:** ...

### Risks
(what could go wrong + mitigations)
\`\`\`

## IMPORTANT
Your Stop hook blocks until the report exists at the path above. Write with the Write tool to the EXACT path. Task prompts must be COMPLETE and dispatch-ready.
TASK

# Exit copy-mode before paste
tmux copy-mode -q -t "$PANE" 2>/dev/null

# Load and paste
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "$PANE"

# Settle, then submit — auto-scales for large prompts
tmux copy-mode -q -t "$PANE" 2>/dev/null
TASK_LINES=$(wc -l < "$TASKFILE" 2>/dev/null | tr -d ' ') || TASK_LINES=0
if command -v bc >/dev/null 2>&1; then
  SETTLE_S=$(echo "scale=2; ${PASTE_SETTLE_MS:-500} / 1000" | bc)
  if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then MIN_SETTLE="2.0"
  elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then MIN_SETTLE="1.5"
  else MIN_SETTLE="$SETTLE_S"; fi
  SETTLE_S=$(echo "if ($MIN_SETTLE > $SETTLE_S) $MIN_SETTLE else $SETTLE_S" | bc)
else
  if [ "$TASK_LINES" -gt 200 ] 2>/dev/null; then SETTLE_S="2.0"
  elif [ "$TASK_LINES" -gt 100 ] 2>/dev/null; then SETTLE_S="1.5"
  else SETTLE_S="0.5"; fi
fi
sleep $SETTLE_S
tmux send-keys -t "$PANE" Enter

# Cleanup
rm "$TASKFILE"
```

### Step 5: Verify dispatch

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE="${SESSION_NAME}:0.X"

sleep 5
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
  echo "✓ Research worker 0.X started processing"
else
  echo "⚠ Research worker 0.X not processing — retrying..."
  tmux copy-mode -q -t "$PANE" 2>/dev/null
  tmux send-keys -t "$PANE" Enter
  sleep 3
  OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -5)
  if echo "$OUTPUT" | grep -qE '(thinking|working|Read|Edit|Bash|Grep|Glob|Write|Agent)'; then
    echo "✓ Research worker 0.X started after retry"
  else
    echo "✗ Research worker 0.X FAILED — run unstick sequence from /doey-dispatch"
  fi
fi
```

### Reading Reports

After the worker finishes (shows idle prompt ❯):

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

PANE_SAFE=$(echo "${SESSION_NAME}:0.X" | tr ':.' '_')
REPORT_FILE="${RUNTIME_DIR}/reports/${PANE_SAFE}.report"

# Verification: confirm report exists
if [ -f "$REPORT_FILE" ]; then
  echo "✓ Report found at ${REPORT_FILE}"
  cat "$REPORT_FILE"
else
  echo "✗ Report NOT found at ${REPORT_FILE} — task failed. Check worker output:"
  tmux capture-pane -t "${SESSION_NAME}:0.X" -p -S -20
fi
```

### Acting on the Report

```bash
# 1. Read report and present summary to user
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
PANE_SAFE=$(echo "${SESSION_NAME}:0.X" | tr ':.' '_')
cat "${RUNTIME_DIR}/reports/${PANE_SAFE}.report"
```

Then:
1. Present a concise summary to the user (findings, recommended option, alternatives).
2. Ask user which option to proceed with.
3. On confirmation, dispatch using the ready-to-paste task prompts from the report via `/doey-dispatch`.
4. Monitor completion, dispatch subsequent waves, run verification commands from the report.

### Rules

1. **Always create task marker BEFORE dispatching** — the Stop hook needs it to enforce reporting
2. **Always clear old report file before dispatching** — stale reports bypass enforcement
3. **`PANE_SAFE` must match exactly** — full pane ref with `:` and `.` replaced by `_`
4. **Include report path in task prompt** — worker needs to know where to write
5. **Always check idle + reservation before dispatch** — don't interrupt busy or reserved panes
6. **Always verify after dispatch (Step 5)** — if it fails, run unstick before retrying
7. **Always verify report exists after worker finishes** — if missing, the task failed
