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

### Worker Instructions

**Build & Lint (Worker 1):**
- Run `$BUILD_CMD` (or language-appropriate build). Report pass/fail with output.
- Run `$LINT_CMD` (or language-appropriate linter). Report pass/fail with output.
- Stop with combined result: both must pass.

**Test Runner (Worker 2):**
- Run `$TEST_CMD` (or language-appropriate test suite). Report pass/fail with output.
- On failure: list each failing test name and its error summary.

**Code Reviewer (Worker 3):**
- Run `git diff --cached` (or `git diff HEAD~1`) to get changed files.
- Review for: code quality, security issues (OWASP top 10), consistency with project patterns, missing error handling at boundaries.
- Produce a structured review: critical issues, warnings, suggestions.

**Deploy Gate (Worker 4):**
- Run `shell/pre-push-gate.sh` as the final quality gate.
- Collect results from all previous stages (read `$RUNTIME_DIR/` status files).
- Produce a deploy readiness report: overall PASS/FAIL, per-stage summary, blockers if any.

### Reporting

Pipeline Lead collects all worker results and writes `$RUNTIME_DIR/deploy_status` with:
- Overall status: `PASS` or `FAIL`
- Per-stage results: stage name, status, duration, error summary (if failed)
- Timestamp of completion

Notify Session Manager when the pipeline completes.

### Failure Handling

- **Build or test failure (Wave 1):** Stop pipeline immediately. Do not dispatch Wave 2 or 3. Report which stage failed with actionable fix suggestions.
- **Review findings (Wave 2):** Critical issues block the pipeline. Warnings are reported but do not block.
- **Gate failure (Wave 3):** Report blockers clearly. Pipeline status is FAIL.
- Always include enough output context for the developer to diagnose and fix without re-running.
