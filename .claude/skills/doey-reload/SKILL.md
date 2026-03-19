---
name: doey-reload
description: Hot-reload Manager + Watchdog without stopping workers
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Hot-reload: update files, restart Manager + Watchdog. Workers keep running unless `--workers`.

`/doey-reload [--workers]`

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
cd "$PROJECT_DIR"
doey reload $ARGUMENTS
```

**Warning:** Kills YOUR Claude instance — Manager starts with fresh context. ~15s watchdog gap. Pass through any arguments (`--workers`, `--all`).
