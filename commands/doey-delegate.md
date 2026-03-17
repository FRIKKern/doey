# Skill: doey-delegate

Delegate a task to a Window Manager.

## Usage
`/doey-delegate`

## Prompt
You are delegating a task to a Window Manager (another Claude Code instance).

### Step 1: Discover teams

Run `doey team` to see available team windows and their Window Managers:

```bash
doey team
```

### Step 2: Pick target

Choose which Window Manager to delegate to. Default: first team window. Consider:
- Which WM is idle (look for "idle" in status)
- Which team is most appropriate for the task

If the user specified a window, use that. Otherwise pick the first idle WM.

### Step 3: Craft and delegate

```bash
doey delegate "Your task text here" W
```

Where `W` is the window number (e.g., `1`, `2`). The CLI handles: idle check, tmpfile creation, paste-buffer dispatch, verification, cleanup.

### Rules

1. Never delegate to your own pane — you ARE a Window Manager
2. If task is complex, craft a clear prompt with numbered steps
3. The WM you delegate to already knows the project context — no need for "You are a worker..." preamble
4. Check `doey delegate` output to confirm dispatch succeeded
5. For research tasks, prefer `/doey-research` instead
