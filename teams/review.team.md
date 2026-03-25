---
name: review
description: "Code review pipeline — reviewer reads, critic validates, implementer fixes"
grid: dynamic
workers: 3
type: local
watchdog: default
manager_model: opus
worker_model: opus

panes:
  0: { role: manager, agent: doey-manager, name: "Review Lead" }
  1: { role: reviewer, name: "Code Reviewer" }
  2: { role: critic, agent: doey-critic, name: "Quality Gate" }
  3: { role: implementer, name: "Fix Implementer" }

workflow:
  - on: stop, from: reviewer, to: critic, subject: review_complete
  - on: stop, from: critic, to: implementer, subject: fixes_needed
  - on: stop, from: implementer, to: reviewer, subject: fixes_applied
---

## Team Briefing

Review pipeline: Reviewer reads code and produces findings → Critic validates against project standards → Implementer applies approved fixes → Reviewer re-checks.
