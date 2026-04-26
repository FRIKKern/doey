# Doey Plans Reference

Canonical contract for plan artifacts. Anything that writes a plan file
must conform to this document.

## 1. Purpose

The Plans system stores planning artifacts from features like
`/doey-masterplan` and `/doey-planned-task`. The Go TUI's Plans tab
reads from `<project>/.doey/plans/` and renders each plan's markdown
body in a detail view. This document is the authoritative contract for
anything that writes a plan file.

## 2. Storage location

Exactly `<project>/.doey/plans/<N>.md`. Flat directory — no
subdirectories. `<N>` is a decimal integer.

The TUI reader scans the top level only via `os.ReadDir`, keeping
entries whose name ends in `.md`
(`tui/internal/runtime/plans_config.go:62-79`). Nested paths and
non-`.md` files are ignored.

## 3. Filename convention

Format: `<N>.md`. Allocate via either:

- `doey plan create --title "…" --task-id <T>` — preferred. Routes to
  `doey-ctl plan create` (`tui/cmd/doey-ctl/store_cmds.go:108-150`) and
  returns the SQLite-assigned id. That id **is** the filename stem.
- `plan_create` in `shell/doey-plan-helpers.sh:6` — scans existing
  numeric basenames, picks `max+1`, and emits
  `.doey/plans/<id>.md` with starter frontmatter.

Do not reuse ids. Do not rename the file after creation — the Plans
tab, the DB, and every downstream skill key off the stem.

## 4. YAML-ish frontmatter

Delimited by `---` lines. Parsed line-by-line by a hand-rolled parser at
`tui/internal/runtime/plans_config.go:99-143`.

### Keys

| Key | Required | Type | Notes |
|-----|----------|------|-------|
| `plan_id` (or `id`) | yes | decimal int | Must equal filename stem. `migrate.go:463-467` silently drops non-numeric ids. |
| `task_id` | no | decimal int | FK to `tasks.id`. `0` or absent means unlinked. |
| `title` | yes | string | One line. Quotes stripped on parse. |
| `status` | yes | enum | `draft \| active \| complete \| archived`. (`backlog` also accepted, see §7.) |
| `created` | yes | RFC3339 UTC | e.g. `2026-04-18T07:00:00Z`. Fallback formats: `2006-01-02T15:04:05`, `2006-01-02 15:04:05`, `2006-01-02` (`tui/internal/model/plans.go:299-314`). |
| `updated` | yes | RFC3339 UTC | Bump on every mutation. |
| `skill` | no | string | Origin marker: `doey-masterplan`, `doey-planned-task`, `manual`, … |

### Parser constraints (`plans_config.go:118-143`)

- Split on **first** `:` only. Value trimmed then stripped of surrounding `"`/`'`.
- Single-line values only. No YAML block scalars (`|`, `>`), no lists, no nested maps.
- Lines empty, pure whitespace, or starting with `#` are skipped.
- **Unknown keys are silently ignored.** Put extra metadata in the body.

### Example

```yaml
---
plan_id: 42
task_id: 601
title: Canonical plan format contract
status: active
created: 2026-04-18T07:00:00Z
updated: 2026-04-18T08:30:00Z
skill: doey-masterplan
---
```

## 5. Body

Markdown after the closing `---`. Rendered verbatim through
[glamour](https://github.com/charmbracelet/glamour) in the detail
viewport (`tui/internal/model/plans.go:767-813`). The TUI does **not**
parse sections — the `tui/internal/planparse` package is a separate
library used only by `doey-masterplan-tui`
(`tui/cmd/doey-masterplan-tui/main.go:20`).

Checkboxes (`- [ ]` / `- [x]`) are scanned by `extractUncheckedItems`
(`tui/internal/model/plans.go:702-719`) to drive the detail-view
`Build (b)` and `Tasks (c)` actions. A trailing
`<!-- task_id=N -->` comment on a checkbox line is stripped at read.

### Recommended canonical sections

Use H2 in this order. The viewer is permissive; these are the
conventional sections every plan-emitter should write:

- `## Goal` — 1–2 sentences on success.
- `## Context` — background, constraints, interview findings.
- `## Phases` — H3 per phase. Each phase opens with
  `**Status:** planned | in-progress | done | failed`, then
  `- [ ]` / `- [x]` step checkboxes.
- `## Deliverables` — artifacts or outcomes.
- `## Risks` — risk + mitigation pairs.
- `## Success Criteria` — measurable outcomes.
- `## Decisions` — append-only decision log.
- `## Agent Reports` — architect/critic/worker summaries pasted in.

Canonical example: `agents/doey-planner.md:141-169` and
`teams/masterplan.team.md:154-188`. Planner guidance: "Do NOT invent
new top-level sections — the viewer is built around these"
(`agents/doey-planner.md:171`).

## 6. Index

The index is the SQLite `plans` table at
`<project>/.doey/doey.db` (schema:
`tui/internal/store/schema.go:61-68`; `task_id` column added by
`tui/internal/store/schema.go:167-168`).

`SyncPlansFromFiles` (`tui/internal/store/migrate.go:510-530`) scans
`.doey/plans/*.md` and upserts rows whose body differs from disk. It
runs on every `ReadPlans` call
(`tui/internal/runtime/plans_config.go:37`), which fires on the 2 s
snapshot tick (`tui/internal/model/root.go:48,107,121-128`).

**There is no separate JSON index file.** Anyone asking about
`.doey/plans/index.json` is working from an outdated assumption.

| Column | Type | Source (frontmatter key) |
|--------|------|--------------------------|
| `id` | INTEGER PK | `plan_id` / `id` / filename stem |
| `task_id` | INTEGER | `task_id` |
| `title` | TEXT NOT NULL | `title` |
| `status` | TEXT DEFAULT `draft` | `status` |
| `body` | TEXT | everything after frontmatter |
| `created_at` | INTEGER (unix) | `created` |
| `updated_at` | INTEGER (unix) | `updated` |

## 7. Lifecycle

```
draft ──► active ──► complete ──► archived (optional)
   │
   └────► backlog (paused, via detail-view "Backlog" button)
```

- `draft` — created, not yet started. `/doey-masterplan` emits here.
- `active` — user accepted; work in progress. Enter on a draft calls
  `setPlanStatus(path, "active")` (`tui/internal/model/plans.go:483`).
- `complete` — all phases done.
- `archived` — retained, hidden from active work. Icon at
  `tui/internal/model/plans.go:136`; no UI path sets it today.
- `backlog` — paused via the detail-view `Backlog (B)` button
  (`tui/internal/model/plans.go:617-649`).

Update paths:

- `doey plan update --id <N> --status <s>` → `doey-ctl plan update`
  (`tui/cmd/doey-ctl/store_cmds.go`).
- `doey plan update --id <N> --body "$(cat file.md)"` — sync body to
  DB after editing the `.md` file (see
  `shell/doey-masterplan-spawn.sh:186`).
- TUI writer: `setPlanStatus` rewrites frontmatter `status` + `updated`
  lines in place (`tui/internal/model/plans.go:508-537`).
- Shell helpers: `plan_update_status`, `plan_update_field` in
  `shell/doey-plan-helpers.sh:106-117+`.

Always bump `updated` when status changes.

## 8. Authoring patterns

### Shell / skill emitter

```bash
# 1. Allocate id via DB (preferred).
plan_id="$(doey plan create \
    --title "Refactor auth layer" \
    --task-id "$TASK_ID" \
    --json | jq -r '.id')"

# 2. Write the canonical file.
plan_file="$PROJECT_DIR/.doey/plans/${plan_id}.md"
cat > "$plan_file" <<EOF
---
plan_id: ${plan_id}
task_id: ${TASK_ID}
title: "Refactor auth layer"
status: draft
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
skill: doey-masterplan
---

# Plan: Refactor auth layer
## Goal
...
EOF

# 3. Push body into DB (optional — SyncPlansFromFiles catches up in 2 s).
doey plan update --id "$plan_id" --body "$(cat "$plan_file")"
```

### Agent emitter

The spawning script hands the agent `${PLAN_FILE}` (already-allocated
path). The agent appends structured markdown under the canonical
sections and **never renames the file**. See
`shell/doey-masterplan-spawn.sh` for the allocation + handoff pattern.

## 9. Sidecars

Masterplan runs produce reviewer sidecars
(`<plan-id>.architect.md`, `<plan-id>.critic.md`, `consensus.state`).
These live **only** in the runtime masterplan directory
`/tmp/doey/<project>/masterplan-<TS>/`. They are **not** copied into
`.doey/plans/`.

The canonical plan file at `<project>/.doey/plans/<N>.md` absorbs
reviewer content via body edits — append architect/critic findings
under `## Agent Reports`. Do not drop additional files next to it:
the TUI scan in §2 would either ignore them or (if named `<M>.md`)
mistake them for independent plans.

## 10. Migration from legacy

Pre-601 plan files (`masterplan-<TS>.md`, non-numeric stems) are
invisible to the Plans tab — see §11. A one-shot migration script
`shell/migrate-plans-601.sh` renames such files to `<N>.md` with
allocated ids and inserts proper frontmatter. New emitters must follow
this contract from the start — do not produce non-numeric names and
rely on future migration.

## 11. Non-conforming files

`tui/internal/store/migrate.go:463-467`:

```go
if err != nil {
    r.Errors = append(r.Errors, fmt.Sprintf(
        "plan %s: skipping non-numeric plan ID %q",
        filepath.Base(path), idStr))
    return nil
}
```

A plan with a non-numeric `plan_id` (or, in the filename-stem
fallback, a non-numeric stem like `masterplan-2026-04-18.md`) is
silently dropped by `SyncPlansFromFiles`. It is therefore:

- invisible to the Plans tab (no DB row; the file-fallback reader
  assigns id `0` via `strconv.Atoi` which collides);
- invisible to `doey plan list` / `doey plan get`;
- still present on disk.

**Never emit non-numeric plan ids.** If tempted to use a timestamp or
slug as the filename, stop and allocate a numeric id via
`doey plan create` or `plan_create`.

### Pitfall: Unknown `doey plan` subcommands

The router at `shell/doey.sh` recognises `list|get|show|create|update|delete|to-tasks` as
plan subcommands. Anything else — typos, `--help`, or stray flags — falls through to the
masterplan-goal branch and spawns a new team window with the unknown token as the goal.
Use `doey plan --help` to see the recognised subcommands. (Fixed for `show`/`--help` in
task 601 Phase 1 — typos like `doey plan dlete` will still spawn a masterplan team.)

## 12. Cross-references

- Storage overview: [storage.md](storage.md).
- Reader: `tui/internal/runtime/plans_config.go`,
  `tui/internal/runtime/reader.go:182-188`.
- TUI view model: `tui/internal/model/plans.go`.
- SQLite schema + sync: `tui/internal/store/schema.go:61-68`,
  `tui/internal/store/plans.go`,
  `tui/internal/store/migrate.go:448-530`.
- CLI: `tui/cmd/doey-ctl/store_cmds.go`;
  router in `shell/doey.sh:479-509`.
- Shell helpers: `shell/doey-plan-helpers.sh`.
