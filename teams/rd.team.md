---
name: rd
description: "R&D product team — Brain coordinates Platform Expert, Claude Expert, and Critic"
grid: dynamic
workers: 3
type: local
manager_model: opus
worker_model: opus

panes:
  0: { role: brain, agent: doey-product-brain, name: "Brain" }
  1: { role: platform_expert, agent: doey-platform-expert, name: "Platform Expert" }
  2: { role: claude_expert, agent: doey-claude-expert, name: "Claude Expert" }
  3: { role: critic, agent: doey-critic, name: "Critic" }

workflow:
  - on: stop, from: platform_expert, to: brain, subject: platform_audit_complete
  - on: stop, from: claude_expert, to: brain, subject: claude_audit_complete
  - on: stop, from: critic, to: brain, subject: review_complete
---

## Team Briefing

R&D product team working on the live codebase. The Brain coordinates specialists:
- Platform Expert: tmux internals, bash 3.2 portability, shell scripts
- Claude Expert: hooks, agents, skills, settings overlays
- Critic: regression checks, output quality, before/after comparison
