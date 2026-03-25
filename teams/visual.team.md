---
name: visual
description: "Visual verification service — UI checks, responsive review, accessibility, bug triage"
grid: dynamic
workers: 4
type: local
watchdog: default
manager_model: opus
worker_model: sonnet

panes:
  0: { role: manager, agent: visual-manager, name: "Visual Manager" }
  1: { role: investigator, agent: visual-investigator, name: "DevTools Investigator" }
  2: { role: reviewer, agent: visual-reviewer, name: "Visual Reviewer" }
  3: { role: a11y, agent: visual-a11y, name: "UX + A11y Reviewer" }
  4: { role: reporter, agent: visual-reporter, name: "Defect Reporter" }

workflow:
  - on: stop, from: investigator, to: manager, subject: evidence_captured
  - on: stop, from: reviewer, to: manager, subject: visual_review_complete
  - on: stop, from: a11y, to: manager, subject: a11y_review_complete
  - on: stop, from: reporter, to: manager, subject: report_ready
---

## Team Briefing

Shared visual verification service. The Visual Manager receives requests from other team managers, classifies them into modes (Quick Check, Bug Triage, Deep Audit), dispatches to specialists, and returns compact verdicts.

- DevTools Investigator: sole browser operator — navigates, captures screenshots, console errors, network state, DOM snapshots
- Visual Reviewer: judges layout correctness, responsive behavior, visual regressions from artifacts
- UX + A11y Reviewer: keyboard flow, focus behavior, semantics, contrast, user impact assessment
- Defect Reporter: groups findings, deduplicates, produces ticket-ready output

Only the Investigator drives the live browser. All others consume artifacts.
