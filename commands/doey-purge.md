# Skill: doey-purge

Scan and clean stale runtime files, audit context bloat.

## Usage
`/doey-purge [--dry-run] [--force] [--scope runtime|context|hooks|all]`

## Prompt
You are running the Doey purge tool to clean stale runtime files and audit context bloat.

### Step 1: Run CLI

Run with the user's requested flags. Default to `--dry-run` for safety:

```bash
doey purge $ARGUMENTS
```

Available flags:
- `--dry-run` — report only, no deletions (default if user just wants to check)
- `--force` — skip confirmation, purge immediately
- `--scope runtime` — only clean stale runtime files (status, old results)
- `--scope context` — only audit agent/command/CLAUDE.md sizes
- `--scope hooks` — only run context-audit.sh
- `--scope all` — everything (default)
- No flags — interactive mode (scan, report, ask before purging)

### Step 2: Interpret output

The CLI reports:
- Runtime scan: stale status files, old results
- Research scan: expired research/report files (>48h TTL)
- Context audit: file sizes with recommendations for oversized agents/commands
- Hook audit: context-audit.sh results
- Summary table: total files and bytes that can be freed

### Step 3: Follow up

If the user ran with `--dry-run` and wants to actually purge, run:

```bash
doey purge --force
```

Report the results including the JSON report path.
