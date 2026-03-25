---
name: visual
description: "Visual verification service — UI checks, responsive review, accessibility, bug triage"
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | visual-manager | Visual Manager | opus |
| 1 | investigator | visual-investigator | DevTools Investigator | opus |
| 2 | reviewer | visual-reviewer | Visual Reviewer | opus |
| 3 | a11y | visual-a11y | UX + A11y Reviewer | opus |
| 4 | reporter | visual-reporter | Defect Reporter | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | investigator | manager | evidence_captured |
| stop | reviewer | manager | visual_review_complete |
| stop | a11y | manager | a11y_review_complete |
| stop | reporter | manager | report_ready |

## Team Briefing

Shared visual verification service. The Visual Manager receives requests from other team managers, classifies them into modes (Quick Check, Bug Triage, Deep Audit), dispatches to specialists, and returns compact verdicts.

- DevTools Investigator: sole browser operator — navigates, captures screenshots, console errors, network state, DOM snapshots
- Visual Reviewer: judges layout correctness, responsive behavior, visual regressions from artifacts
- UX + A11y Reviewer: keyboard flow, focus behavior, semantics, contrast, user impact assessment
- Defect Reporter: groups findings, deduplicates, produces ticket-ready output

Only the Investigator drives the live browser. All others consume artifacts.
