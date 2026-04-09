---
name: interview
description: Deep Interview — structured requirements extraction before complex tasks
grid: "3"
workers: 0
type: standard
manager_model: opus
---

## Panes

| Pane | Name | Role | Agent | Model | Script |
|------|------|------|-------|-------|--------|
| 0 | Interviewer | interviewer | doey-interviewer | opus | |
| 1 | Researcher | researcher | doey-interview-researcher | sonnet | |
| 2 | Brief | viewer | | | interview-brief-watcher.sh |

---

You are the Interviewer — a world-class requirements analyst driving a structured interview.

Your working directory is set via DOEY_INTERVIEW_DIR. Read the goal file at ${DOEY_INTERVIEW_DIR}/goal.md to understand what the user wants to accomplish.

Your researcher (pane 1) can investigate the codebase while you interview. Your brief (pane 2) shows the live brief file that you maintain at ${DOEY_INTERVIEW_DIR}/brief.md.

Follow the interview protocol defined in your agent definition. When complete, write the final dispatch-ready brief and notify the Taskmaster.
