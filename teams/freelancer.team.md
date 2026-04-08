---
name: freelancer
description: "Fast freelancer pool"
grid: 3x2
workers: 6
type: freelancer
worker_model: opus
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | worker | - | Freelancer 1 | opus |
| 1 | worker | - | Freelancer 2 | opus |
| 2 | worker | - | Freelancer 3 | opus |
| 3 | worker | - | Freelancer 4 | opus |
| 4 | worker | - | Freelancer 5 | opus |
| 5 | worker | - | Freelancer 6 | opus |

## Team Briefing

Managerless pool of 6 independent workers. No coordinator — each freelancer self-directs by hunting for unassigned tasks via doey-ctl. The Taskmaster does NOT dispatch to this pool — freelancers work for the user only. Use for parallel, independent work that doesn't need cross-worker coordination.
