---
name: deploy
description: "Validation pipeline team — build, lint, test, review, and deploy quality gate"
grid: dynamic
workers: 4
manager_model: opus
worker_model: opus
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | Pipeline Lead | opus |
| 1 | worker | - | Build & Lint | opus |
| 2 | worker | - | Test Runner | opus |
| 3 | worker | - | Code Reviewer | opus |
| 4 | worker | - | Deploy Gate | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | Build & Lint | manager | build_complete |
| stop | Test Runner | manager | tests_complete |
| stop | Code Reviewer | manager | review_complete |
| stop | Deploy Gate | manager | gate_complete |

## Team Briefing

### Mission

Run a validation pipeline before code is pushed. The team validates build integrity, code quality (lint), test passage, code review, and final deploy readiness. All stages must pass before code is cleared for push.

### Task Lifecycle

Pipeline Lead is task-obsessed — every pipeline run is tracked as a task with full subtask, report, and conversation history.

**On startup / dispatch:**
```bash
source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
TASK_FILE="${PROJECT_DIR}/.doey/tasks/${TASK_ID}.task"
```

If `TASK_ID` was provided in the dispatch, use it. Otherwise create a new task:
```bash
TD="${PROJECT_DIR}/.doey/tasks"; mkdir -p "$TD"
TASK_ID="deploy_$(date +%s)"
TASK_FILE="${TD}/${TASK_ID}.task"
cat > "$TASK_FILE" << EOF
TASK_ID=${TASK_ID}
TASK_TITLE=Pipeline run $(date +%Y-%m-%d_%H:%M)
TASK_STATUS=in_progress
TASK_CREATED=$(date +%s)
TASK_TYPE=deploy
TASK_DESCRIPTION=Validation pipeline: build, lint, test, review, deploy gate
EOF
```

**Track every stage as a subtask:**
```bash
S1=$(task_add_subtask "$TASK_FILE" "W${DOEY_TEAM_WINDOW}.1: Build & Lint")
S2=$(task_add_subtask "$TASK_FILE" "W${DOEY_TEAM_WINDOW}.2: Test Runner")
S3=$(task_add_subtask "$TASK_FILE" "W${DOEY_TEAM_WINDOW}.3: Code Review")
S4=$(task_add_subtask "$TASK_FILE" "W${DOEY_TEAM_WINDOW}.4: Deploy Gate")
```

**Update subtask status when each worker finishes:**
```bash
task_update_subtask "$TASK_FILE" "$S1" "done"    # Build & Lint passed
task_update_subtask "$TASK_FILE" "$S2" "done"    # Tests passed
# On failure:
task_update_subtask "$TASK_FILE" "$S3" "failed"  # Review found blockers
```

**Write a report after each wave completes:**
```bash
task_add_report "$TASK_FILE" "progress" "Wave 1 Complete" \
  "Build: PASS (go build ./... — 0 errors, 12s). Lint: PASS (golangci-lint — 0 issues). Tests: PASS (142/142, 8s)." \
  "Pipeline_Lead_W${DOEY_TEAM_WINDOW}"
```

**On pipeline completion — submit a completion report:**
```bash
task_add_report "$TASK_FILE" "completion" "Pipeline PASS" \
  "All 4 stages passed. Build: 12s. Tests: 142/142. Review: 0 critical, 2 warnings. Gate: CLEARED." \
  "Pipeline_Lead_W${DOEY_TEAM_WINDOW}"
```

Update task status on completion:
```bash
TMP="${TASK_FILE}.tmp"
while IFS= read -r line; do
  case "${line%%=*}" in TASK_STATUS) echo "TASK_STATUS=pending_user_confirmation" ;; *) echo "$line" ;; esac
done < "$TASK_FILE" > "$TMP" && mv "$TMP" "$TASK_FILE"
```

**On pipeline failure — submit an error report with actionable details:**
```bash
task_add_report "$TASK_FILE" "error" "Pipeline FAIL — Tests" \
  "3 tests failed: TestAuth (nil pointer at auth.go:42), TestCache (timeout after 30s), TestMigrate (column 'email' missing). Fix auth nil check first — other failures may cascade." \
  "Pipeline_Lead_W${DOEY_TEAM_WINDOW}"
```

### Conversation Trail

Pipeline Lead logs all significant interactions to the task file:

```bash
echo "TASK_LOG_$(date +%s)=PIPELINE_START: Triggered by dispatch from SM" >> "$TASK_FILE"
echo "TASK_LOG_$(date +%s)=WAVE_1: Dispatched Build&Lint (W.1) + Tests (W.2) in parallel" >> "$TASK_FILE"
echo "TASK_LOG_$(date +%s)=WAVE_1_RESULT: Build PASS, Tests FAIL — 3 failures" >> "$TASK_FILE"
echo "TASK_LOG_$(date +%s)=DECISION: Pipeline stopped at Wave 1 — test failures block Wave 2" >> "$TASK_FILE"
```

Log decisions, stage transitions, failures, and escalations. The task file is the complete record of the pipeline run — anyone reading it should understand exactly what happened without checking runtime files.

### Pipeline Stages

Execute in sequential waves — each wave must pass before the next starts.

**Wave 1 (parallel):** Build & Lint (Worker 1) + Test Runner (Worker 2)
- These run simultaneously. If either fails, stop the pipeline immediately.

**Wave 2 (after Wave 1 passes):** Code Reviewer (Worker 3)
- Reviews changed files for quality, security, and pattern violations.

**Wave 3 (after all pass):** Deploy Gate (Worker 4)
- Runs final quality gate. Produces the deployment readiness report.

### Project Detection

The session provides `PROJECT_LANGUAGE`, `BUILD_CMD`, `TEST_CMD`, and `LINT_CMD` in `session.env`. Workers should read these to determine which commands to run. If these variables are not set, fall back to running `shell/pre-push-gate.sh` which auto-detects the project type.

### TASK_ID Propagation

Pipeline Lead MUST include `TASK_ID` in every worker dispatch prompt so workers can reference it:

```
You are Worker N on the deploy pipeline.
TASK_ID: <task_id>
Task file: <path to .task file>
...
```

### Worker Instructions

**All workers:** Include comprehensive output in your results — not just pass/fail. The Pipeline Lead will capture your full findings in task reports. Include: exact commands run, full stdout/stderr (trimmed to relevant sections if very long), duration, file-specific findings, and actionable fix suggestions on failure.

**Build & Lint (Worker 1):**
- Run `$BUILD_CMD` (or language-appropriate build). Report: command, exit code, full error output, duration.
- Run `$LINT_CMD` (or language-appropriate linter). Report: command, issue count, per-file issues with line numbers.
- Stop with combined result: both must pass.

**Test Runner (Worker 2):**
- Run `$TEST_CMD` (or language-appropriate test suite). Report: command, pass/fail/skip counts, duration.
- On failure: list each failing test name, file:line, error message, and suggested fix.
- On success: include total count and duration for the progress report.

**Code Reviewer (Worker 3):**
- Run `git diff --cached` (or `git diff HEAD~1`) to get changed files.
- Review for: code quality, security issues (OWASP top 10), consistency with project patterns, missing error handling at boundaries.
- Produce a structured review: critical issues (with file:line and explanation), warnings, suggestions. Categorize each finding.

**Deploy Gate (Worker 4):**
- Run `shell/pre-push-gate.sh` as the final quality gate.
- Collect results from all previous stages (read `$RUNTIME_DIR/` status files).
- Produce a deploy readiness report: overall PASS/FAIL, per-stage summary (command, status, duration, issue count), blockers if any.

### Reporting

Pipeline Lead collects all worker results and writes:

1. **Task file reports** (primary) — using `task_add_report` after each wave and on completion/failure. These are the permanent record — they survive runtime cleanup.

2. **Runtime status** — `$RUNTIME_DIR/deploy_status` with:
   - Overall status: `PASS` or `FAIL`
   - Per-stage results: stage name, status, duration, error summary (if failed)
   - Timestamp of completion

Reports must include full worker findings, not just pass/fail. The task file should contain enough detail for someone to understand exactly what happened without re-running the pipeline.

Notify Taskmaster when the pipeline completes.

### Failure Handling

- **Build or test failure (Wave 1):** Stop pipeline immediately. Do not dispatch Wave 2 or 3. Report which stage failed with actionable fix suggestions.
- **Review findings (Wave 2):** Critical issues block the pipeline. Warnings are reported but do not block.
- **Gate failure (Wave 3):** Report blockers clearly. Pipeline status is FAIL.
- Always include enough output context for the developer to diagnose and fix without re-running.
