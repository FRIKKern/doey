---
name: doey-add-window
description: Add a new team window (Subtaskmaster + Workers), optionally in a git worktree or as a reserved freelancer pool.
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Windows: !`tmux list-windows -t "$(grep SESSION_NAME $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null | cut -d= -f2)" -F '#{window_index} #{window_name}' 2>/dev/null || true`

`/doey-add-window [NxM] [--worktree] [--freelancer] [--reserved]` — delegates to `doey add-window`. **No confirmation.**

### 1. Build and run the CLI command

Parse the user's arguments and map them to `doey add-window` flags:
- `NxM` grid spec → `--grid NxM`
- `--worktree` → `--worktree`
- `--freelancer` → `--type freelancer`
- `--reserved` → `--reserved`

Run: `bash: doey add-window [flags]`

### 2. Verify

Run: `bash: tmux list-windows -t "$(grep SESSION_NAME "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"/session.env | cut -d= -f2)" -F '#{window_index} #{window_name}'`

Report the new window index and pane count.
