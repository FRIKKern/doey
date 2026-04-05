---
name: doey-reload
description: Hot-reload Subtaskmaster without stopping workers. Use when you need to "reload doey config", "restart subtaskmaster", or "apply agent/hook changes".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Hot-reload Subtaskmaster (workers keep running unless `--workers`/`--all`).

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env" && cd "$PROJECT_DIR" && doey reload
```

Don't run from Subtaskmaster pane (kills self). Don't pass `--workers` unless asked.
