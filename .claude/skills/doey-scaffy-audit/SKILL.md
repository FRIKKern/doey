---
name: doey-scaffy-audit
description: Audit scaffy templates for staleness with 6 checks — anchor validity, guard freshness, path existence, variable alignment, pattern activity, structural consistency. Returns healthy / needs_update / stale.
---

- Templates available: !`ls .doey/scaffy/templates/*.scaffy 2>/dev/null || echo "(none)"`

Run the Scaffy template auditor against one template or every template under `.doey/scaffy/templates/`. Each template gets 6 health checks; the overall status rolls up to **healthy**, **needs_update** (any warning), or **stale** (any failure).

### Checks

| # | Check | Fails when… |
|---|-------|-------------|
| 1 | anchor_validity | INSERT/REPLACE target text not present in the file |
| 2 | guard_freshness | `unless_contains` pattern is already in the file (warn — template applied) |
| 3 | path_existence | CREATE target already exists or INSERT/REPLACE target missing |
| 4 | variable_alignment | Variable has no Transform / no Default / no Examples (warn) |
| 5 | pattern_activity | Target files have zero git activity in last 50 commits (warn) |
| 6 | structural_consistency | Parent directory contains files with mismatched extensions (warn) |

### Usage

```bash
doey-scaffy audit [template]              # one template, or discover all
doey-scaffy audit --json                  # machine-readable report
doey-scaffy audit --fix                   # auto-fix (Phase 4 — currently a no-op)
doey-scaffy audit --cwd <dir>             # alternate working directory
```

### Examples

```bash
# Audit everything under .doey/scaffy/templates/
doey-scaffy audit

# Single template, JSON for CI
doey-scaffy audit --json .doey/scaffy/templates/handler.scaffy
```

### Notes

- Exit code is non-zero (`ExitAllBlocked = 3`) if any template has a failing check
- Warnings never fail the run — they print but pass
- Use alongside `/doey-scaffy-validate` (syntax) for a full health pass
