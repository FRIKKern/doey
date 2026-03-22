---
name: unknown-task
description: Fallback skill for tasks that don't match any specific skill. Provides conservative execution guidelines with strict tool-call budgets.
---

## Prompt

You received a task that doesn't match any specialized skill. Follow this conservative execution protocol.

## Step 1: Understand
- Read the task prompt carefully
- Identify what files or systems are involved
- State your understanding in 1-2 sentences before acting

## Step 2: Scope
- Determine the minimum set of changes needed
- If the task is ambiguous, state your assumption and proceed conservatively
- Do NOT expand scope beyond what was explicitly requested

## Step 3: Execute
- Use the simplest approach that accomplishes the goal
- Edit existing files — do NOT create new files unless the task explicitly requires it
- Run tests after each significant change if tests exist
```bash
# Check for tests
ls *test* tests/ __tests__/ 2>/dev/null
```
**Budget for this step:** Max 8 Edit/Write/Bash calls.

## Step 4: Verify
- Re-read modified files to confirm changes are correct
- Run any available linters or tests
- If tests fail after your change, REVERT and report what went wrong

## Step 5: Summarize
Always end with a summary:
- ✅ What you completed
- ⚠️ What you couldn't complete and why
- 📁 Files modified (absolute paths)
- 🔢 Tool calls used: N/15

Total: 5 phases, max 15 tool calls across all phases.

## Gotchas
- Do NOT exceed 15 tool calls — stop and summarize instead
- Do NOT create files unless the task explicitly asks for it
- Do NOT modify files outside the project directory
- Do NOT run destructive commands (rm -rf, git reset, etc.)
- Do NOT guess at ambiguous requirements — state your assumption and proceed conservatively
- If you hit an error you don't understand, STOP and report it rather than retrying blindly
