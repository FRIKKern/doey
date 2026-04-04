---
name: doey-add-team
description: Spawn a team from a .team.md definition file. Usage: /doey-add-team <name>
---

## Context

- Current windows: !`tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null || true`
- Available team defs: !`ls -1 .team.md *.team.md .doey/*.team.md ~/.config/doey/teams/*.team.md 2>/dev/null || echo "(none found in common locations)"`

## Prompt

Spawn a team from a `.team.md` file via the CLI. **No confirmation. Taskmaster/Subtaskmaster only.**

### How to execute

1. Get the team name from the skill arguments. If no name was provided, report the error and stop.

2. Run `doey add-team <name>` via the Bash tool:
   ```bash
   doey add-team "<name>"
   ```

3. If the command **fails**, report the error output verbatim. Do NOT attempt manual tmux commands or any other fallback.

4. If the command **succeeds**, verify the window was created:
   ```bash
   tmux list-windows -t "$(tmux display-message -p '#S')" -F '#{window_index} #{window_name}' 2>/dev/null
   ```

5. Report: team name, new window index, and pane count.

Teardown: `/doey-kill-window <window_index>`. The CLI handles everything: .team.md search, parsing, window creation, env files, Claude launches, layout, settings, and status files.
