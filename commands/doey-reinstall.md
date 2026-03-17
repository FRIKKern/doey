# Skill: doey-reinstall

Reinstall the Doey system from the source repo.

## Usage
`/doey-reinstall`

## Prompt
Reinstall Doey by pulling latest changes and re-running the installer.

### Step 1: Run CLI

```bash
doey update
```

The CLI handles:
1. Finding the repo directory
2. Pulling latest changes via git
3. Running install.sh
4. Reporting results

### Step 2: Report

Present the CLI output. Note: "Running sessions need `doey reload` or `doey stop && doey` to pick up changes."
