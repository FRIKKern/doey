# Skill: doey-broadcast

Broadcast a message to all Claude instances in the session.

## Usage
`/doey-broadcast [message]`

## Prompt
You are broadcasting a message to all Claude Code instances in the tmux session.

### Step 1: Get the message

If a message was provided as an argument, use it. Otherwise ask the user what they want to broadcast.

### Step 2: Broadcast

```bash
doey broadcast "Your message here"
```

The CLI handles: creating broadcast files, delivering to all pane message queues, counting deliveries.

### Step 3: Confirm

Report the CLI output — how many panes received the broadcast. The Watchdog delivers queued messages to idle panes automatically.
