# Skill: doey-doctor

Run diagnostics on the Doey session and suggest fixes.

## Usage
`/doey-doctor`

## Prompt
You are running diagnostics on the Doey session.

### Step 1: Run CLI command
```bash
doey doctor
```

### Step 2: Interpret and present
Present the diagnostic results clearly. For any issues found:
- Explain what the issue means
- Suggest a specific fix or next step
- Prioritize: critical issues first, then warnings, then info

Common fixes to suggest:
- Missing runtime files → `doey reload`
- Stale heartbeat → check Watchdog pane, may need restart
- Crashed workers → `/doey-monitor deep <W.pane>` to inspect
- Version mismatch → `doey update`
