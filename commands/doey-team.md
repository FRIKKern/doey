# Skill: doey-team

View the full team overview — all panes including Manager, Watchdog, and Info Panel.

## Usage
`/doey-team [W]` — show all panes (optionally filtered to window W)

## Prompt
You are showing the full team overview of all Claude Code instances.

### Step 1: Run CLI command
```bash
doey team $WINDOW_ARG
```
Where `$WINDOW_ARG` is the window number if specified, or omitted for all.

### Step 2: Interpret and present
Present the output clearly. Note:
- Which panes are Managers, Workers, Watchdogs, Info Panel, Session Manager
- Any panes with UNKNOWN status (may not have started yet)
- Any reserved panes
- Highlight your own pane if identifiable

If any issues are visible, suggest next actions (e.g., `/doey-monitor` for deep inspect, `/doey-reserve` for reservations).
