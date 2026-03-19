# Skill: doey-delegate

Delegate a task to a specific Claude instance. Like `/doey-dispatch` but targets a user-chosen pane without kill/restart.

## Usage
`/doey-delegate`

## Prompt

### Project Context
Same as `/doey-dispatch` — source `session.env` and team env.

### Step 1: Discover panes

```bash
tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
```

### Step 2: Get target and task

If not specified, ask user for target pane and task. Never delegate to your own pane.

### Step 3: Check reservation + idle

Same checks as `/doey-dispatch` pre-flight: verify `.reserved` file absent, capture pane output and check for `❯`.

### Step 4: Dispatch

Follow `/doey-dispatch` dispatch sequence (rename, tmpfile/load-buffer, settle, verify). Skips kill/restart since worker is already idle.

### Rules
1. Never `send-keys "" Enter`; always tmpfile/load-buffer
2. Check idle + reservation before delegating
3. Verify after dispatch; never delegate to own pane
