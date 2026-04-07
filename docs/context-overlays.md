# Context Overlays — Per-Project Agent Customization

## What it is and why

Context overlays inject project-specific knowledge into each Doey role at session start. While `CLAUDE.md` gives every agent the same global context, overlays let you tailor what each role knows. Workers get implementation details, the Boss gets product context, the Taskmaster gets coordination rules — all from simple markdown files in your project.

## Directory structure

Overlays live in `.doey/context/` at your project root. Five template files ship by default:

```
.doey/context/
  all.md            # Loaded for every role
  boss.md           # Boss (user-facing PM)
  coordinator.md    # Taskmaster (coordination)
  team_lead.md      # Subtaskmaster (planning)
  worker.md         # Workers (implementation)
```

You can add files for any role. The full mapping:

| Filename | Role | Description |
|----------|------|-------------|
| `all.md` | Everyone | Shared context loaded for all roles |
| `boss.md` | Boss | User-facing project management |
| `coordinator.md` | Taskmaster | Task routing and coordination |
| `team_lead.md` | Subtaskmaster | Planning and delegation |
| `worker.md` | Worker | Implementation and execution |
| `freelancer.md` | Freelancer | Independent workers |
| `task_reviewer.md` | Task Reviewer | Quality review |
| `deployment.md` | Deployment | CI/CD and releases |
| `doey_expert.md` | Doey Expert | Doey codebase specialist |
| `info_panel.md` | Info Panel | Dashboard display |
| `test_driver.md` | Test Driver | E2E test runner |

Only the 5 core files ship as templates. Additional role files are created by you as needed. The system is purely file-presence based — if the file exists, it gets loaded. No config toggles required.

## Creating overlays for each role

Each overlay should contain context relevant to how that role operates in your project.

**`boss.md`** — Product context the Boss needs when talking to you. Include project goals, stakeholder names, milestone dates, and terminology the Boss should use when reporting status.

**`coordinator.md`** — Coordination rules for the Taskmaster. Include team structure preferences, which types of tasks should go to which teams, deployment approval flows, and any ordering constraints on work.

**`team_lead.md`** — Planning context for Subtaskmasters. Include how to break down work in your project, testing requirements before marking tasks done, file ownership boundaries between teams, and review checklists.

**`worker.md`** — Implementation details workers need. Include build commands, test commands, code style rules, framework patterns, database conventions, and environment setup.

**`all.md`** — Shared context every role should have. Include domain terminology, architecture overview, and links to external resources.

## Real examples

Here are concrete snippets you could paste into your overlay files:

**Testing conventions** (`worker.md`):
```markdown
## Testing
- Run tests: `pytest -x --tb=short`
- All new code needs tests in `tests/` mirroring the source path
- Use fixtures from `conftest.py` — don't create test databases manually
- Integration tests require `docker compose up -d postgres redis` first
```

**Deploy steps** (`coordinator.md`):
```markdown
## Deployment
- Staging: push to `staging` branch — Vercel auto-deploys
- Production: merge to `main` then run `npm run deploy:prod`
- Rollback: `vercel rollback` (last 3 deploys retained)
- Never deploy on Fridays without explicit approval
```

**Domain terminology** (`all.md`):
```markdown
## Domain terms
- **Widget** — our core product entity, stored in `widgets` table
- **Flow** — a sequence of widget interactions, tracked in `flows` table
- **Tenant** — a customer organization (multi-tenant SaaS)
- **Credits** — usage-based billing units, 1 credit = 1 API call
```

**API patterns** (`worker.md`):
```markdown
## API conventions
- REST API at `/api/v2/`, auth via Bearer token in Authorization header
- All endpoints return `{ data, error, meta }` envelope
- Pagination: `?cursor=<id>&limit=50` (no offset-based)
- Rate limiting: 100 req/min per tenant, 429 response on breach
```

**Architecture constraints** (`all.md`):
```markdown
## Architecture rules
- No ORM — raw SQL only, Postgres 15
- All queries go through `db/queries/` — one file per table
- Background jobs via `pg_boss`, not cron
- File uploads to S3 via presigned URLs, never through our API
```

## How overlays survive updates

The `.doey/context/` directory is user-owned. Running `doey update`, reinstalling via `./install.sh`, or upgrading Doey refreshes agents, hooks, and shell scripts — but never touches your overlay files.

This means your project-specific context is safe across updates. To protect it further:

- **Commit overlays to version control.** Add `.doey/context/` to your repo so the whole team shares the same agent context.
- The shipped template files are created only if they don't already exist, so your edits are never overwritten.

## Priority order

Overlays load in a 2-tier priority system at session start:

1. **Team-specific role file** — If a team has a role configured (e.g., `DOEY_TEAM_1_ROLE=backend`), Doey looks for a matching file first (e.g., `backend.md`). This is exported as `DOEY_CONTEXT_OVERLAY`.
2. **Base role file** — Falls back to the standard role file (e.g., `worker.md`). Also exported as `DOEY_CONTEXT_OVERLAY`.
3. **`all.md`** — Always loaded for every role, in addition to the role-specific file. Exported as `DOEY_CONTEXT_OVERLAY_ALL`.

The team-specific file wins when it exists. A worker on a team with `DOEY_TEAM_1_ROLE=backend` loads `backend.md` instead of `worker.md`, plus `all.md`.

During compaction, `on-pre-compact.sh` inlines the first **200 lines** of each loaded overlay to preserve context. Keep overlays under this limit to avoid truncation.

## Tips and best practices

- **Keep overlays concise** — under 200 lines each to survive compaction intact.
- **Don't duplicate CLAUDE.md** — overlays supplement it, not replace it. Put universal rules in `CLAUDE.md`, role-specific details in overlays.
- **Use `all.md` for shared context** — domain terms, architecture rules, and team conventions that every role needs.
- **Use role files for role-specific content** — build commands in `worker.md`, deploy flows in `coordinator.md`, product context in `boss.md`.
- **Commit to version control** — so the whole team gets the same agent context.
- **Review periodically** — overlays drift as projects evolve. Update them when conventions change.
- **One concern per section** — use markdown headers within overlays to keep content scannable.
