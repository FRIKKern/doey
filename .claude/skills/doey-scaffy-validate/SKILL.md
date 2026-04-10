---
name: doey-scaffy-validate
description: Validate a scaffy template syntax and structure. Use --strict to also flag missing transforms, anchors, IDs.
---

- Templates available: !`ls .doey/scaffy/templates/*.scaffy 2>/dev/null || echo "(none)"`

Parse a `.scaffy` template and report syntax or structural problems before applying it.

### Usage

```bash
doey-scaffy validate <template>.scaffy [flags]
```

### Flags

- `--strict` — apply strict checks (variables must have explicit Transforms, INSERT/REPLACE need IDs, guarded ops need REASON, anchor targets must be non-empty)
- `--json` — emit a JSON validation report (`{valid, errors[], warnings[]}`)
- `--cwd <dir>` — working directory

### Examples

```bash
# Plain syntax check
doey-scaffy validate .doey/scaffy/templates/handler.scaffy

# Strict mode with JSON output for CI
doey-scaffy validate --strict --json .doey/scaffy/templates/handler.scaffy
```

### Notes

- Errors fail the run (`valid: false`); warnings are reported but pass
- Use `--strict` in CI to enforce template hygiene
- Run `/doey-scaffy-audit` afterward to also check the working tree for staleness
