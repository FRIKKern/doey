---
name: doey-reload
description: Hot-reload Manager + Watchdog without stopping workers. Use when you need to "reload doey config", "restart manager and watchdog", or "apply agent/hook changes".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

**Expected:** 1 bash command (doey reload), 1 file read (session.env), ~15s.

Hot-reload Manager + Watchdog. Workers keep running unless `--workers`. If user passed `--workers` or `--all`, append that flag to the command below.

## Step 1: Run doey reload
bash: RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && cd "$PROJECT_DIR" && doey reload
Expected: Manager and Watchdog restart. Workers continue running.

**If this fails with "DOEY_RUNTIME not set":** The session environment is missing. Run `tmux show-environment` to check available variables.
**If this fails with "session.env: No such file":** Runtime directory is gone. Run `doey stop && doey` to restart the full session.

## Gotchas
- Do NOT run this from the Manager or Watchdog pane — it kills YOUR Claude instance and you get a fresh context with ~15s watchdog gap
- Do NOT pass `--workers` unless the user explicitly requested it

Total: 1 commands, 0 errors expected.
