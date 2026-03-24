---
name: doey-reload
description: Hot-reload Manager + Watchdog without stopping workers. Use when you need to "reload doey config", "restart manager and watchdog", or "apply agent/hook changes".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Hot-reload Manager + Watchdog. Workers keep running unless `--workers`/`--all` flag passed.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && cd "$PROJECT_DIR" && doey reload
```

### Rules
- Don't run from Manager/Watchdog pane — it kills your own instance
- Don't pass `--workers` unless user explicitly requested it
