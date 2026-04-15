---
name: doey-clarify
description: Quick inline clarification loop — a few targeted AskUserQuestion rounds to sharpen a vague goal before task creation. Use when you need to "clarify", "interview the user", "sharpen a vague goal", or resolve ambiguity without spawning a full /deep-interview window.
---

Run a short inline clarification loop with the user to sharpen a vague goal. Stays in the Boss pane — no new windows, no team, no runtime files. Goal from ARGUMENTS; if empty, use `AskUserQuestion` to ask for the goal first, then stop.

### When to use / when to escalate

Use `/doey-clarify` for goals that are under ~20 words, missing a clear WHERE (files/modules), or lacking success criteria. It is a lightweight complement to classification, not a replacement.

Escalate to `/deep-interview` when the goal is genuinely complex: cross-team work, architecture decisions, three or more unknowns, or the user explicitly wants a structured requirements document.

### Quality over quantity

Good clarification is about the RIGHT question, not more questions — the Douglas Adams principle. Before asking anything, identify the actual ambiguity: is it scope, success criteria, constraints, or a hidden assumption? Ask the smallest set of questions that collapses the uncertainty. Avoid yes/no-answerable questions — they confirm what you already suspect instead of surfacing what you do not know. Stop the loop the moment the picture is clear; extra rounds are friction, not rigor.

### The loop

1. **Slot extraction.** From the current goal, fill three slots: WHAT (action), WHY (motivation), WHERE (files/modules/surface). Note which slots are empty or ambiguous.
2. **Targeted rounds.** For each empty or ambiguous slot, add one question to the next round. Batch 2–4 questions into a single `AskUserQuestion` call per round. Prefer open questions that force specificity ("Which users or surfaces is this for?") over yes/no probes.
3. **Early exit.** If the user says "just do it", "good enough", "you pick", or gives terse one-word replies, stop immediately and proceed with what you have.
4. **Emit clarified goal.** On exit, output a single clarified-goal block (see Output format) so the caller can feed it straight into `/doey-instant-task` or `/doey-planned-task`.

### Rules

- Hard cap: **3 AskUserQuestion rounds**. After the third, stop regardless of remaining ambiguity.
- Batch 2–4 questions per round in one `AskUserQuestion` call — do not ask one question at a time across rounds.
- Exit early on terse or "just do it" responses. More questions at that point burn trust.
- Never create tasks, spawn windows, send `doey msg`, or run `doey add-team`. This skill is pure interaction.
- Never read project source files. Ambiguity resolution is about the user's intent, not the code.
- On exit, always emit the clarified-goal block — even if some slots remain "unknown".

### Output format

Emit exactly this block when the loop ends:

```
**Clarified goal:** <one sentence>
**Scope:** <files/modules or "unknown">
**Success criteria:** <how to verify>
**Classification hint:** INSTANT | PLANNED
```

The Boss IntentGate uses this block to continue classification with enriched intent.
