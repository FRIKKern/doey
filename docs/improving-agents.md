# Improving Agents — Customization and Enhancement Guide

A practical guide to modifying, extending, and creating Doey agents. Covers the template system, agent anatomy, the context overlay system, role naming, and testing. For both contributors working on Doey itself and end users customizing agents for their projects.

## Overview

Doey agents are markdown files with YAML frontmatter that define how each Claude Code instance behaves within a Doey session. They live in `agents/` in the repo and get installed to `~/.claude/agents/` by `install.sh`.

Each agent file controls:

- **Identity** — name, model, color, description (YAML frontmatter)
- **Behavior** — system prompt instructions that shape how the role operates
- **Tool awareness** — documents which tools are blocked or allowed (enforcement is in hooks, not the agent file)

Key directories:

| Path | Purpose |
|------|---------|
| `agents/*.md.tmpl` | Source-of-truth templates |
| `agents/*.md` | Generated files (never edit directly) |
| `~/.claude/agents/` | Installed copies used at runtime |
| `.doey/context/` | Per-project overlays (user-owned) |

## The Template System

Agent `.md` files are **generated** from `.md.tmpl` templates. The templates contain `{{DOEY_ROLE_*}}` placeholders that get expanded to real role names by `shell/expand-templates.sh`.

**Rule: never edit `.md` files directly.** Your changes will be overwritten the next time templates are expanded. Always edit the `.md.tmpl` file.

### How it works

The script `shell/expand-templates.sh` sources `shell/doey-roles.sh` to load all `DOEY_ROLE_*` variables, then uses `sed` to replace every `{{DOEY_ROLE_*}}` placeholder in `.md.tmpl` files with the corresponding value.

### Running it

```bash
# Expand all templates (agents/ and .claude/skills/)
bash shell/expand-templates.sh

# Preview what would change without writing files
bash shell/expand-templates.sh --dry-run

# Check if generated files are up to date (CI-friendly)
bash shell/expand-templates.sh --check
```

### Before and after example

In `agents/doey-worker.md.tmpl`:

```markdown
Doey {{DOEY_ROLE_WORKER}}. Execute tasks, write clean code, report progress.
```

After running `bash shell/expand-templates.sh`, `agents/doey-worker.md` contains:

```markdown
Doey Worker. Execute tasks, write clean code, report progress.
```

The placeholder `{{DOEY_ROLE_WORKER}}` was replaced with the display name `Worker` from `shell/doey-roles.sh`.

### Available placeholders

All variables exported in `shell/doey-roles.sh` are available as placeholders. The most commonly used:

| Placeholder | Expands to | Purpose |
|-------------|------------|---------|
| `{{DOEY_ROLE_COORDINATOR}}` | `Taskmaster` | Display name for coordinator |
| `{{DOEY_ROLE_TEAM_LEAD}}` | `Subtaskmaster` | Display name for team lead |
| `{{DOEY_ROLE_BOSS}}` | `Boss` | Display name for boss |
| `{{DOEY_ROLE_WORKER}}` | `Worker` | Display name for worker |
| `{{DOEY_ROLE_FREELANCER}}` | `Freelancer` | Display name for freelancer |
| `{{DOEY_TASKMASTER_PANE}}` | `1.0` | Pane address of the Taskmaster |

## Agent Anatomy

Every agent file has two parts: YAML frontmatter and a markdown system prompt.

### YAML frontmatter

Using `agents/doey-worker.md.tmpl` as a real example:

```yaml
---
name: doey-worker
model: opus
color: "#3498DB"
memory: none
description: "Worker with live task-update instructions."
---
```

| Field | Purpose | Values |
|-------|---------|--------|
| `name` | Agent identifier, matches the filename | Must match `DOEY_ROLE_FILE_*` pattern |
| `model` | Claude model to use | `opus`, `sonnet`, `haiku` |
| `color` | Hex color for UI elements | Any CSS hex color |
| `memory` | Memory persistence level | `none`, `session`, `user` |
| `description` | One-line summary shown in agent picker | Free text (can use `{{DOEY_ROLE_*}}` placeholders in `.tmpl`) |

### System prompt sections

The markdown body after the frontmatter is the agent's system prompt. A typical agent includes these sections:

1. **Role identity** — One-line statement of what the role does. Example from the Worker: `"Doey Worker. Execute tasks, write clean code, report progress."`

2. **Core behavior** — Detailed instructions for how the role operates. For Workers, this includes success criteria verification. For the Subtaskmaster, this includes the "never delegate understanding" principle.

3. **Tool restrictions** — Documents which tools are blocked and allowed. Lists what the role can and cannot do.

4. **Communication protocol** — How to report progress, log results, and interact with other roles. Workers use `doey task` commands; the Subtaskmaster uses `send-keys`.

### Where tool enforcement lives

Tool restrictions listed in the agent file are **documentation only**. Actual enforcement happens in `.claude/hooks/on-pre-tool-use.sh`. The hook checks the role (via `DOEY_ROLE` env var) and blocks disallowed tool calls at runtime. If you need to change what a role can or cannot do, edit the hook — not just the agent file.

## How to Modify an Agent

### Step-by-step workflow

1. **Edit the template** — Open the `.md.tmpl` file in `agents/`:

   ```bash
   # Example: modifying the Worker agent
   # Edit agents/doey-worker.md.tmpl (NOT agents/doey-worker.md)
   ```

2. **Expand templates** — Regenerate the `.md` files:

   ```bash
   bash shell/expand-templates.sh
   ```

3. **Test** — Restart the relevant role to pick up changes (see "Testing Your Changes" below).

### What is safe to change

- Prompt text and behavior instructions
- Adding new sections to the system prompt
- Changing the `model` field (e.g., `opus` to `sonnet` for cost savings)
- Changing the `color` field
- Changing the `memory` field
- Updating the `description` field

### What NOT to change

- **The `name` field** — Hooks, shell scripts, and the install system depend on agent filenames matching `DOEY_ROLE_FILE_*` patterns. Changing a name requires the full rename procedure (see "Role Naming System").
- **Role identifiers referenced by hooks** — If `on-pre-tool-use.sh` checks for a specific role string, changing that string in the agent without updating the hook will break enforcement.
- **Structural patterns other roles depend on** — For example, Workers emit `PROOF_*` lines that the Task Reviewer parses. Changing that format requires updating both sides.

### Restart instructions

After modifying an agent, restart the affected role:

| What changed | Restart action |
|--------------|---------------|
| Agent definition | Restart the specific role's pane |
| Subtaskmaster agent | Restart the Subtaskmaster |
| Worker agent | Restart workers (`doey reload --workers`) |
| Hook that loads at startup | Restart ALL affected workers |

## Context Overlay System

Context overlays let you inject project-specific knowledge into agents **without editing templates**. They live in `.doey/context/` at your project root and are loaded at session start.

### When to use overlays vs. editing templates

| Scenario | Approach |
|----------|----------|
| Project-specific build commands, API patterns, domain terms | Context overlay |
| Changing how a role fundamentally behaves | Edit the `.md.tmpl` template |
| Adding coding standards for your project | Context overlay |
| Adding a new communication protocol | Edit the `.md.tmpl` template |

### How overlays work

Each role loads up to two overlay files:

1. **Role-specific file** — e.g., `worker.md` for Workers, `boss.md` for the Boss
2. **`all.md`** — Loaded for every role in addition to the role-specific file

Five template files ship by default (`all.md`, `boss.md`, `coordinator.md`, `team_lead.md`, `worker.md`). You can add files for any role — the system is file-presence based.

### Example: adding project context for Workers

Create or edit `.doey/context/worker.md`:

```markdown
## Build & Test
- Build: `npm run build`
- Test: `npm test -- --watchAll=false`
- Lint: `npm run lint`

## Code Style
- Use TypeScript strict mode
- Prefer named exports over default exports
- All API routes in `src/routes/`
```

Workers will receive this context at session start, in addition to their base agent prompt and `CLAUDE.md`.

### Key points

- Overlays survive Doey updates — `install.sh` never overwrites existing overlay files
- Keep overlays under 200 lines to survive compaction intact
- Commit `.doey/context/` to version control so the whole team shares context

For the full overlay reference, see [docs/context-overlays.md](context-overlays.md).

## Role Naming System

All role names are centralized in `shell/doey-roles.sh`. Three tiers:

| Tier | Variable prefix | Example |
|------|----------------|---------|
| Display | `DOEY_ROLE_*` | `DOEY_ROLE_COORDINATOR="Taskmaster"` |
| Internal ID | `DOEY_ROLE_ID_*` | `DOEY_ROLE_ID_COORDINATOR="coordinator"` |
| File pattern | `DOEY_ROLE_FILE_*` | `DOEY_ROLE_FILE_COORDINATOR="doey-taskmaster"` |

- **Display names** are user-facing strings used in prompts and UI
- **Internal IDs** are stable identifiers used in status files, env vars, and logic — these should rarely change
- **File patterns** map to agent filenames and skill directories

### Rename procedure

Renaming a role requires updating multiple layers. Follow this exact sequence:

```bash
# 1. Edit the source of truth
#    Change the display name(s) in shell/doey-roles.sh

# 2. Regenerate agent and skill files from templates
bash shell/expand-templates.sh

# 3. Regenerate Go constants for the TUI
cd tui && go generate ./internal/roles/

# 4. Verify Go compiles
cd tui && go build ./...

# 5. Verify shell compatibility
bash tests/test-bash-compat.sh
```

Never rename by editing generated `.md` files — your changes will be lost on the next template expansion.

## Testing Your Changes

### Template changes

After editing any `.md.tmpl` file:

```bash
# Regenerate all .md files from templates
bash shell/expand-templates.sh

# Verify all generated files match their templates
bash shell/expand-templates.sh --check
```

### Shell script changes

After editing any `.sh` file:

```bash
# Run Bash 3.2 compatibility checks
bash tests/test-bash-compat.sh
```

### Restart reference

Different change types require different restart actions:

| What changed | Action |
|--------------|--------|
| Agent definitions | Restart the specific role's pane |
| Hooks | Restart ALL workers (`doey reload --workers`) — hooks load at startup |
| Skills | No restart needed (loaded on-demand) |
| Shell scripts | Run `tests/test-bash-compat.sh` |
| Launcher | `doey reload` or `doey stop && doey` |
| Install script | `doey uninstall && ./install.sh && doey doctor` |

### The fresh-install test

Before any change, ask: "Would this work after deleting `~/.config/doey/`, `~/.local/bin/doey`, `~/.claude/agents/doey-*` and running `./install.sh` fresh?"

## Common Recipes

### Adding a new behavior to an existing agent

Goal: make Workers always run `npm test` before reporting completion.

1. Edit `agents/doey-worker.md.tmpl`
2. Add a section before the existing "Protocol" section:

   ```markdown
   ## Pre-Completion Check

   Before marking any task as done, run `npm test` in the project root. If tests fail, fix the issue or report the failure — do not mark the task as done with failing tests.
   ```

3. Regenerate and test:

   ```bash
   bash shell/expand-templates.sh
   bash shell/expand-templates.sh --check
   ```

4. Restart workers to pick up the change.

### Changing agent verbosity or style

Goal: make the Boss use more concise status updates.

1. Edit `agents/doey-boss.md.tmpl`
2. Find the reporting/communication section and add:

   ```markdown
   ## Communication Style

   Keep status updates to 2-3 sentences. Lead with the outcome, not the process. Skip transition phrases like "I've gone ahead and..." — just state what happened.
   ```

3. Regenerate: `bash shell/expand-templates.sh`
4. Restart the Boss pane.

### Adding project-specific knowledge via overlays

Goal: give Workers knowledge of your project's database conventions.

1. Create or edit `.doey/context/worker.md`:

   ```markdown
   ## Database

   - PostgreSQL 15, no ORM — raw SQL via `sqlx`
   - Migrations in `db/migrations/`, run with `sqlx migrate run`
   - All queries in `db/queries/` — one file per table
   - Use `$1, $2` parameter syntax, never string interpolation
   ```

2. No template expansion needed. Workers pick this up at next session start.
3. Commit `.doey/context/worker.md` so the team shares it.

### Creating a new role from scratch

Goal: add a "Security Reviewer" specialist role.

1. **Define the role** in `shell/doey-roles.sh`:

   ```bash
   DOEY_ROLE_SECURITY_REVIEWER="Security Reviewer"
   DOEY_ROLE_ID_SECURITY_REVIEWER="security_reviewer"
   DOEY_ROLE_FILE_SECURITY_REVIEWER="doey-security-reviewer"
   ```

   Add the corresponding `export` lines.

2. **Create the template** at `agents/doey-security-reviewer.md.tmpl`:

   ```markdown
   ---
   name: doey-security-reviewer
   model: opus
   color: "#E67E22"
   memory: none
   description: "{{DOEY_ROLE_SECURITY_REVIEWER}} — reviews code changes for security vulnerabilities."
   ---

   You are the {{DOEY_ROLE_SECURITY_REVIEWER}}. Review code for security issues: injection, auth bypass, secrets in code, unsafe deserialization, and OWASP Top 10.

   ## Tool Restrictions

   **Allowed:** Read, Glob, Grep on project source. Bash for non-destructive commands.
   **Blocked:** Edit, Write, git push, send-keys.
   ```

3. **Expand templates**:

   ```bash
   bash shell/expand-templates.sh
   ```

4. **Add hook enforcement** in `.claude/hooks/on-pre-tool-use.sh` if the role needs tool restrictions beyond what the agent file documents.

5. **Regenerate Go constants** (if the TUI needs to know about the role):

   ```bash
   cd tui && go generate ./internal/roles/
   cd tui && go build ./...
   ```

6. **Run compatibility checks**:

   ```bash
   bash tests/test-bash-compat.sh
   ```

7. **Test the full install path**:

   ```bash
   doey uninstall && ./install.sh && doey doctor
   ```
