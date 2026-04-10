---
name: doey-scaffy-run
description: Apply a scaffy template to the current project. Supports --var KEY=VALUE, --vars-file, --dry-run preview, --diff unified diff output, --json structured report. Use /doey-scaffy-run <template> [vars].
---

- Templates available: !`ls .doey/scaffy/templates/*.scaffy 2>/dev/null || echo "(none — run /doey-scaffy-new to create one)"`

Apply a `.scaffy` template to the working tree. Templates run a 7-stage pipeline: parse → resolve INCLUDE → expand FOREACH → substitute variables → CREATE → INSERT/REPLACE → report.

### Usage

```bash
doey-scaffy run <template>.scaffy [flags]
```

### Common flags

- `--var KEY=VALUE` — variable assignment (repeatable)
- `--vars-file <path>` — JSON or `key=value` file
- `--dry-run` — plan changes without writing
- `--diff` — show unified diff of planned changes
- `--json` — emit machine-readable report
- `--human` — human summary (default)
- `--no-input` — fail rather than prompt for missing variables
- `--force` — overwrite existing files (Phase 2)
- `--cwd <dir>` — working directory

### Examples

```bash
# Preview only
doey-scaffy run .doey/scaffy/templates/handler.scaffy --var Name=User --dry-run --diff

# Apply with vars file
doey-scaffy run .doey/scaffy/templates/handler.scaffy --vars-file vars.json
```

### Notes

- Templates live under `.doey/scaffy/templates/<name>.scaffy`
- CREATE skips files that already exist (idempotent)
- INSERT/REPLACE skip if the target text is already present
- Exit codes: `0` ok, `1` syntax, `2` anchor missing, `3` all blocked, `4` var missing, `5` I/O, `10` internal
