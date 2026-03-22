---
name: doey-reload
description: Hot-reload Manager + Watchdog without stopping workers. Use when you need to "reload doey config", "restart manager and watchdog", or "apply agent/hook changes".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

**Expected:** 1 bash command (doey reload), 1 file read (session.env), ~15s.

Hot-reload Manager + Watchdog. Workers keep running unless `--workers`. If user passed `--workers` or `--all`, append that flag to the command below.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
cd "$PROJECT_DIR"
doey reload
```

**Warning:** Kills YOUR Claude instance — fresh context. ~15s watchdog gap.
