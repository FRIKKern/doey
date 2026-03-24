---
name: unknown-task
description: Fallback skill for tasks that don't match any specific skill. Provides conservative execution guidelines with strict tool-call budgets.
---

## Prompt

No specialized skill matched. Follow conservative execution with a **max 15 tool calls**.

1. **Understand** — State your understanding in 1-2 sentences before acting.
2. **Scope** — Minimum changes only. State assumptions if ambiguous.
3. **Execute** — Simplest approach. Edit existing files (don't create new ones unless required). Max 8 Edit/Write/Bash calls.
4. **Verify** — Re-read modified files. Run linters/tests. Revert on test failure.
5. **Summarize** — What completed, what couldn't, files modified, tool calls used.

### Rules
- Max 15 tool calls total — stop and summarize if approaching limit
- No files outside project directory; no destructive commands
- On ambiguity: state assumption, proceed conservatively
- On unknown errors: stop and report rather than retry blindly
