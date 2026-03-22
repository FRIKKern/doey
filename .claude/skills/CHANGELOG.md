# Doey Skills Changelog

Changes to Doey skills, with trigger, description, and expected impact.

---

## 2026-03-22 — Skills Improvement Batch (ainm research findings)

### All Skills — Added trigger phrases to description frontmatter
- **Triggered by:** Research finding from §11 — descriptive trigger phrases improve skill activation accuracy
- **Change:** Added 2-3 trigger phrases to each skill description field
- **Impact:** Better skill matching when users describe tasks in natural language

### All Skills — Added expected step counts
- **Triggered by:** Research finding from §7 — step counts give LLMs a completion signal
- **Change:** Added Expected: N tmux commands, N status writes, ~Ns. to each skill body
- **Impact:** Workers can self-check if they are over/under-executing

### doey-dispatch, doey-clear, doey-stop, doey-worktree, doey-add-window, doey-kill-window — Added Gotchas sections
- **Triggered by:** Research finding from §6 — explicit Do NOT lists prevent known failure modes
- **Change:** Added Gotchas section with 3-5 prohibitions per skill
- **Impact:** Reduces repeat failures from known anti-patterns

### doey-dispatch — Added inline error recovery
- **Triggered by:** Research finding from §13 — inline recovery instructions prevent worker stalls
- **Change:** Added If X fails recovery steps inline with dispatch instructions
- **Impact:** Workers can self-recover from common dispatch failures
