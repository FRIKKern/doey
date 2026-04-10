---
name: doey-scaffy-discover
description: Discover scaffolding patterns in this project — structural fingerprints, accretion files, and refactoring patterns from git history. Returns candidates worth turning into templates.
---

- Project root: !`git rev-parse --show-toplevel 2>/dev/null || pwd`
- Recent commits: !`git log --oneline -10 2>/dev/null || echo "(not a git repo)"`

Scan the current project for repeating structural patterns (handler+test pairs, config-block accretion, refactor recipes from history) and surface the ones worth promoting into reusable scaffy templates.

### Usage

```bash
doey-scaffy discover [flags]
```

### Flags

- `--depth N` — how many commits of history to walk (default: 50)
- `--category structural|injection|refactoring` — restrict to one pattern class
  - **structural** — sibling files that always appear together (handler.go + handler_test.go)
  - **injection** — accretion blocks that grow over time (router tables, plugin registries, init() chains)
  - **refactoring** — recurring rewrites visible in history (rename-a-field, swap-an-import)
- `--json` — emit a machine-readable list of candidate patterns
- `--cwd <dir>` — working directory

### Examples

```bash
# Show top accretion candidates
doey-scaffy discover --category injection

# Wide history scan, JSON for piping into a generator
doey-scaffy discover --depth 200 --json
```

### Notes

- Discovery is read-only — it never writes templates
- Pipe output into `/doey-scaffy-new --from-files` to convert a candidate into a draft template
- Skipped silently outside a git repository
