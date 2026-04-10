---
name: doey-scaffy-new
description: Create a new scaffy template from existing files (--from-files) or interactively. Outputs to .doey/scaffy/templates/<name>.scaffy.
---

- Templates dir: !`ls .doey/scaffy/templates/ 2>/dev/null || echo "(none — will be created)"`

Create a new `.scaffy` template, either as an empty stub, from a set of existing files, or by walking an interactive prompt.

### Usage

```bash
doey-scaffy new <name> [flags]
```

### Flags

- `--from-files FILE...` — seed the template with CREATE blocks for each file (variables auto-extracted from filenames)
- `--domain <name>` — set the template's DOMAIN field (e.g. `web`, `cli`, `infra`)
- `--interactive` — walk a guided prompt for variables, anchors, and operations
- `--force` — overwrite an existing template with the same name
- `--cwd <dir>` — working directory

### Examples

```bash
# Empty stub
doey-scaffy new handler

# Seeded from existing handler + test pair
doey-scaffy new handler --from-files src/handler.go src/handler_test.go --domain web

# Guided prompt
doey-scaffy new handler --interactive
```

### Notes

- Output path: `.doey/scaffy/templates/<name>.scaffy`
- Refuses to overwrite without `--force`
- Run `/doey-scaffy-validate --strict` after creating to catch missing fields
- Pair with `/doey-scaffy-discover` to find candidate file sets first
