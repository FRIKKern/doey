---
name: doey-reload
description: Hot-reload Manager + Watchdog without stopping workers
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Hot-reload Manager + Watchdog. Workers keep running unless user passes `--workers` or `--all` (append flag to command).

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
cd "$PROJECT_DIR"
doey reload
```

**Warning:** Kills YOUR Claude instance — fresh context. ~15s watchdog gap.
