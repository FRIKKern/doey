# Scaffy

A declarative template engine inside Doey: `.scaffy` files describe scaffolding operations, the engine applies them idempotently to your project.

---

## What it is

Scaffy is a sub-package of the Doey TUI module that turns repeated scaffolding work — creating files, inserting routes into a router, registering a handler in a barrel, co-creating a component and its test — into small declarative `.scaffy` template files. Each template lives under `.doey/scaffy/templates/`, names its variables, and lists the operations to perform. Running a template applies it to the working tree; running it again is a no-op because every operation is guarded for idempotency.

The point is not just to skip boilerplate. It is to make the scaffolding *itself* the artifact you reason about. Templates can be discovered automatically (`scaffy discover` mines git history for shapes you keep repeating), audited periodically (`scaffy audit` runs six health checks against every template), and driven by Doey's specialist agents (the orchestrator, pattern discoverer, template creator, auditor, syntax reference). Scaffy lives inside Doey — it follows Doey's fresh-install invariant, bash 3.2 rules, and `.doey/` conventions, and ships as `doey-scaffy` alongside the rest of Doey.

---

## Install

Scaffy is installed automatically as part of Doey. There is no separate installer.

```bash
# Verify scaffy is available
doey scaffy --version

# Health-check the whole Doey install (includes scaffy)
doey doctor
```

If you have built Doey from source and need to rebuild the scaffy binary specifically:

```bash
doey build
```

This produces `~/.local/bin/doey-scaffy`. The `doey scaffy …` wrapper proxies to it so you can call either form.

If `doey scaffy --version` does not work after a fresh install, see [Troubleshooting](#troubleshooting).

---

## Quick start

Five steps from zero to a working template:

**1. Initialize the workspace.** Run from your project root:

```bash
doey scaffy init
```

This creates:

```
.doey/scaffy/
  templates/         # your .scaffy files live here
  REGISTRY.md        # template inventory (Orchestrator-managed)
  audit.json         # last audit report
scaffy.toml          # workspace config (defaults are fine for most projects)
```

**2. Write a template.** Save the following as `.doey/scaffy/templates/handler.scaffy`:

```scaffy
TEMPLATE "go-handler"
DESCRIPTION "Create a REST handler with its test file"
VERSION "0.1.0"
DOMAIN "go-backend"

VAR 1 "name"
  PROMPT "Handler name (e.g. user, order)"
  TRANSFORM PascalCase

CREATE "internal/handlers/{{ .snakeCase name }}.go"
CONTENT :::
package handlers

import "net/http"

func {{ .PascalCase name }}Handler(w http.ResponseWriter, r *http.Request) {
    // TODO: implement
}
:::

CREATE "internal/handlers/{{ .snakeCase name }}_test.go"
CONTENT :::
package handlers

import "testing"

func Test{{ .PascalCase name }}Handler(t *testing.T) {
    // TODO: assert
}
:::
```

**3. Validate it.**

```bash
doey scaffy validate handler
```

**4. Plan a dry run.**

```bash
doey scaffy run handler --var name=user --dry-run --diff
```

You should see a unified diff describing the two files that would be created.

**5. Apply for real.**

```bash
doey scaffy run handler --var name=user
```

Two new files in `internal/handlers/`. Re-run the same command and Scaffy reports `0 created, 2 skipped (already present)` — that is idempotency at work.

---

## The .scaffy DSL

Scaffy templates are plain text. Lines beginning with a keyword (uppercase) are directives; everything else is content. Fenced blocks (`:::`) carry multi-line content verbatim. Variable tokens (`{{ .Transform name }}`) interpolate user input.

### Header keywords (7)

| Keyword       | Required | Description                                   | Example                                  |
|---------------|----------|-----------------------------------------------|------------------------------------------|
| `TEMPLATE`    | yes      | Template identifier; must be unique           | `TEMPLATE "go-handler"`                  |
| `DESCRIPTION` | no       | One-line summary for `scaffy list`            | `DESCRIPTION "Create a REST handler"`    |
| `VERSION`     | no       | Semver string                                 | `VERSION "1.2.0"`                        |
| `AUTHOR`      | no       | Original author (defaults from `scaffy.toml`) | `AUTHOR "frikk"`                         |
| `TAGS`        | no       | Free-form tags for filtering                  | `TAGS "rest" "go" "handlers"`            |
| `DOMAIN`      | no       | Category (e.g. go-backend, react)             | `DOMAIN "go-backend"`                    |
| `CONCEPT`     | no       | High-level intent for human readers           | `CONCEPT "scaffold a stateless handler"` |

### Variables (6)

Variables are declared once at the top, then referenced as `{{ .Transform name }}` tokens in any operation body.

| Keyword     | Description                                                           | Example                                 |
|-------------|-----------------------------------------------------------------------|-----------------------------------------|
| `VAR`       | Declares a variable; takes index + name                               | `VAR 1 "name"`                          |
| `PROMPT`    | Question shown when interactively prompting                           | `PROMPT "Handler name"`                 |
| `HINT`      | Extra guidance shown alongside the prompt                             | `HINT "use singular noun"`              |
| `DEFAULT`   | Value used if no `--var` and `--no-input` is set                      | `DEFAULT "user"`                        |
| `EXAMPLES`  | Example values shown in the prompt                                    | `EXAMPLES "user" "order" "item"`        |
| `TRANSFORM` | Default transform applied when the bare `{{ .name }}` form is used    | `TRANSFORM PascalCase`                  |

A complete variable block:

```scaffy
VAR 1 "resource"
  PROMPT "Resource name (singular)"
  HINT "snake_case, no leading underscores"
  DEFAULT "user"
  EXAMPLES "user" "order" "invoice"
  TRANSFORM PascalCase
```

### Operations (9)

| Keyword    | Description                                                          |
|------------|----------------------------------------------------------------------|
| `CREATE`   | Create a new file at the given path                                  |
| `CONTENT`  | Body of a `CREATE` op (string or fenced block)                       |
| `FILE`     | Open a file scope; subsequent `INSERT`/`REPLACE` ops apply to it     |
| `INSERT`   | Insert text into the file relative to an anchor                      |
| `REPLACE`  | Replace text in the file (with `WITH` for the replacement)           |
| `WITH`     | Replacement clause for `REPLACE`                                     |
| `INCLUDE`  | Inline another template at parse time                                |
| `FOREACH`  | Repeat a body once per value in a list                               |
| `END`      | Close a `FOREACH` block                                              |

**CREATE** writes a new file from a fenced block:

```scaffy
CREATE "cmd/{{ .kebabCase name }}/main.go"
CONTENT :::
package main

func main() {}
:::
```

**FILE + INSERT** mutates an existing file at an anchor. Pair every `INSERT` with a guard so re-runs do nothing:

```scaffy
FILE "internal/router/router.go"

INSERT :::
    r.HandleFunc("/{{ .kebabCase name }}", handlers.{{ .PascalCase name }}Handler)
:::
  AFTER "// routes:"
  UNLESS CONTAINS "{{ .PascalCase name }}Handler"
  REASON "Register the new {{ .PascalCase name }} handler with the router"
  ID "register-{{ .snakeCase name }}-route"
```

**REPLACE** swaps an exact substring inside the current `FILE` scope. The `WITH` clause provides the replacement; both target and replacement support fenced blocks:

```scaffy
FILE "go.mod"

REPLACE FIRST "go 1.21"
  WITH "go 1.22"
  REASON "Bump Go toolchain"
```

**INCLUDE** pulls another template's body in at parse time. Use it to factor shared headers out of multiple templates:

```scaffy
INCLUDE "_shared/license-header.scaffy"
```

**FOREACH** repeats the body once per value. Values are quoted strings, comma-separated, listed after `IN`:

```scaffy
FOREACH "domain" IN "user", "order", "invoice"
  CREATE "internal/{{ .snakeCase domain }}/service.go"
  CONTENT :::
package {{ .snakeCase domain }}

type Service struct{}
:::
END
```

### Anchors (7)

Anchors tell Scaffy where, in the current file, an `INSERT` should land or how a `REPLACE` should pick its target. Position keywords decide *where relative to the match*; occurrence keywords decide *which match*.

| Keyword  | Kind        | Description                                                  |
|----------|-------------|--------------------------------------------------------------|
| `ABOVE`  | position    | Insert immediately before the matched line                   |
| `BELOW`  | position    | Insert immediately after the matched line                    |
| `BEFORE` | position    | Insert at the byte position of the match                     |
| `AFTER`  | position    | Insert just past the match                                   |
| `FIRST`  | occurrence  | Use the first match in the file                              |
| `LAST`   | occurrence  | Use the last match                                           |
| `ALL`    | occurrence  | Apply at every match (replace only)                          |

Combine them in an anchor clause:

```scaffy
INSERT :::
    "{{ .kebabCase name }}",
:::
  AFTER LAST "knownTags := []string{"
  UNLESS CONTAINS "\"{{ .kebabCase name }}\","
```

### Guards & metadata (8)

Guards let an operation decide whether to run; metadata gives the auditor and human readers a paper trail.

| Keyword     | Kind     | Description                                                    |
|-------------|----------|----------------------------------------------------------------|
| `UNLESS`    | guard    | Skip the op if the pattern is present (idempotency latch)      |
| `WHEN`      | guard    | Run the op only if the pattern is present                      |
| `CONTAINS`  | guard    | Argument form for `UNLESS`/`WHEN`                              |
| `REASON`    | metadata | Human explanation of *why* this op exists; required by `--strict` |
| `ID`        | metadata | Stable identifier for the op; required by `--strict`           |
| `VERIFY`    | metadata | Optional post-run sanity check expression                      |
| `TARGET`    | helper   | Subject of a `VERIFY EXISTS` clause                            |
| `EXISTS`    | helper   | Predicate for `VERIFY` — passes if the path is on disk         |

Idempotency in practice:

```scaffy
INSERT :::
    Routes = append(Routes, {{ .PascalCase name }}Route)
:::
  BELOW "var Routes ="
  UNLESS CONTAINS "{{ .PascalCase name }}Route"
  REASON "Register {{ .PascalCase name }} as a top-level route"
  ID "register-{{ .snakeCase name }}-route"
  VERIFY TARGET "internal/router/routes.go" EXISTS
```

The `UNLESS CONTAINS` clause is the most important guard you will write. Without it, every `scaffy run` re-inserts the line and the file grows unboundedly. **A useful rule of thumb: every `INSERT` should pair with an `UNLESS CONTAINS` whose pattern includes a piece of the inserted text that is unique per template invocation.**

### Fenced blocks

Multi-line content uses `:::` fences. The opening and closing fences must each be on a line of their own. Optional labels (`::: go ::: … ::: go :::`) let you tag a block; if used, they must match.

```scaffy
CREATE "README.md"
CONTENT :::
# {{ .CapitalizedCase name }}

{{ .Raw description }}
:::
```

**Trim rules:**
- One leading newline after `:::` is dropped
- One trailing newline before `:::` is dropped
- All other whitespace, including indentation, is preserved verbatim
- No backslash escapes — what you write is what you get

### Variable tokens

Tokens have the grammar `{{ .Transform varName }}`. The leading dot is required. The transform prefix is case-insensitive but the canonical spelling matches the Go convention (`PascalCase`, `camelCase`, etc.). Eleven transforms ship in the box:

| Transform           | Input          | Output           |
|---------------------|----------------|------------------|
| `PascalCase`        | `user_profile` | `UserProfile`    |
| `camelCase`         | `user_profile` | `userProfile`    |
| `kebabCase`         | `UserProfile`  | `user-profile`   |
| `snakeCase`         | `UserProfile`  | `user_profile`   |
| `ScreamingSnakeCase`| `UserProfile`  | `USER_PROFILE`   |
| `LowerCase`         | `UserProfile`  | `userprofile`    |
| `UpperCase`         | `UserProfile`  | `USERPROFILE`    |
| `DotCase`           | `UserProfile`  | `user.profile`   |
| `CapitalizedCase`   | `user profile` | `User Profile`   |
| `SlashCase`         | `UserProfile`  | `user/profile`   |
| `Raw`               | `user-PROFILE` | `user-PROFILE`   |

**Canonicalization.** Scaffy normalizes variable references so that `{{ .PascalCase userName }}` and `{{ .snakeCase user_name }}` resolve to the same underlying variable. The canonical key is built by stripping the transform prefix, splitting on word boundaries (camelCase, separators, dots), dropping common stop words, and re-joining as PascalCase. Two tokens with the same canonical key share one prompt and one stored value.

```scaffy
VAR 1 "userName"
  PROMPT "User name"
  TRANSFORM PascalCase

CREATE "{{ .snakeCase user_name }}/main.go"     # same variable as userName
CONTENT :::
package {{ .snakeCase user_name }}
:::
```

Both `user_name` and `userName` resolve to the single variable declared once.

---

## CLI reference

All commands are available as `doey scaffy <subcommand>` or — equivalently — `doey-scaffy <subcommand>` directly. The subcommands below assume the `doey scaffy` form.

### `scaffy init`

```text
SYNOPSIS
    doey scaffy init [--cwd DIR]

DESCRIPTION
    Bootstrap a Scaffy workspace in the given directory (default: process CWD).
    Creates .doey/scaffy/templates/, .doey/scaffy/REGISTRY.md, .doey/scaffy/audit.json,
    and a scaffy.toml with default values. Idempotent: re-running on an existing
    workspace leaves user-authored files alone.

FLAGS
    --cwd DIR    Initialize the workspace at DIR instead of the process CWD.

EXAMPLES
    doey scaffy init
    doey scaffy init --cwd ./services/api
```

### `scaffy run`

```text
SYNOPSIS
    doey scaffy run TEMPLATE [flags]

DESCRIPTION
    Apply a template to the working tree. Variables are resolved in the order:
    --var → --vars-file → SCAFFY_VAR_* env → DEFAULT directive → interactive prompt.
    With --no-input, missing variables exit with code 4 instead of prompting.

FLAGS
    --var KEY=VALUE     Set a variable; repeatable
    --vars-file PATH    Load variables from a JSON or TOML file
    --dry-run           Plan changes without writing the filesystem
    --diff              With --dry-run, emit unified diff against current state
    --json              Emit a structured JSON report
    --human             Force human-readable output (default unless --json)
    --cwd DIR           Run against DIR instead of the process CWD
    --force             Bypass guards and idempotency checks (dangerous)
    --no-input          Fail rather than prompting for missing variables

EXIT CODES
    0   success
    1   syntax error in template
    2   anchor not found in target file
    3   every operation was blocked by guards
    4   required variable missing and --no-input was set
    5   filesystem I/O error
    10  internal error

EXAMPLES
    doey scaffy run handler --var name=user
    doey scaffy run handler --var name=user --dry-run --diff
    doey scaffy run handler --vars-file ./vars.json --json
```

### `scaffy validate`

```text
SYNOPSIS
    doey scaffy validate TEMPLATE [--strict] [--json] [--cwd DIR]

DESCRIPTION
    Parse and structurally validate a template. Without --strict, only syntax
    errors are reported. With --strict, also enforces:
      - every variable reference uses an explicit transform prefix
      - every INSERT and REPLACE has a REASON
      - every INSERT and REPLACE has an ID
      - guards are not "weak" (UNLESS CONTAINS with very short patterns)

EXIT CODES
    0   valid
    1   syntax or strict-mode failure

EXAMPLES
    doey scaffy validate handler
    doey scaffy validate handler --strict --json
```

### `scaffy list`

```text
SYNOPSIS
    doey scaffy list [--domain DOMAIN] [--json] [--cwd DIR]

DESCRIPTION
    Enumerate templates discovered under the workspace templates directory.
    The default templates dir is .doey/scaffy/templates; override via scaffy.toml.

FLAGS
    --domain DOMAIN   Filter to templates whose DOMAIN matches
    --json            Emit a JSON array instead of the human table

EXAMPLES
    doey scaffy list
    doey scaffy list --domain go-backend --json
```

### `scaffy discover`

```text
SYNOPSIS
    doey scaffy discover [--depth N] [--category CAT] [--json] [--cwd DIR]

DESCRIPTION
    Mine the working tree and git history for recurring scaffolding patterns.
    Returns three categories: structural (directory shapes), injection
    (accretion files like routers and registries), and refactoring (suffix-pair
    co-creations like file.go + file_test.go).

FLAGS
    --depth N        Number of git commits to mine (default 200)
    --category CAT   Filter to one of: structural, injection, refactoring
    --json           Emit a JSON array of PatternCandidate objects

EXAMPLES
    doey scaffy discover
    doey scaffy discover --category injection --depth 500 --json
```

### `scaffy audit`

```text
SYNOPSIS
    doey scaffy audit [TEMPLATE] [--fix] [--json] [--cwd DIR]

DESCRIPTION
    Run the six-check auditor against a single template (when TEMPLATE is set)
    or every template under the workspace. Each template is classified as
    healthy, needs_update, or stale.

FLAGS
    --fix       Apply mechanical repairs for safe checks (variable alignment,
                anchor validity within 5 lines, guard freshness on renamed paths).
                Always commit or stash before using --fix.
    --json      Emit the structured AuditResult report

EXAMPLES
    doey scaffy audit
    doey scaffy audit handler --json
    doey scaffy audit --fix
```

### `scaffy new`

```text
SYNOPSIS
    doey scaffy new NAME [--from-files PATH...] [--domain DOMAIN] [--interactive]

DESCRIPTION
    Create a new template stub in the workspace templates directory. With
    --from-files, the stub is seeded with CREATE blocks for each input file
    and a best-effort variable list inferred from common substrings. Without
    --from-files, an empty stub is produced.

FLAGS
    --from-files PATH...   One or more example files to seed the stub from
    --domain DOMAIN        Set the DOMAIN header
    --interactive          Prompt for header fields (TEMPLATE, DESCRIPTION, …)

EXAMPLES
    doey scaffy new handler --from-files internal/handlers/user.go internal/handlers/order.go
    doey scaffy new component --interactive --domain react
```

### `scaffy fmt`

```text
SYNOPSIS
    doey scaffy fmt [TEMPLATE] [--write] [--check]

DESCRIPTION
    Canonicalize template formatting: 2-space indent for nested ops, keyword
    alignment in headers, fenced-block normalization. Without flags, writes
    the formatted text to stdout.

FLAGS
    --write    Rewrite the template in place
    --check    Exit non-zero if the template is not already canonical

EXIT CODES
    0   formatted (or already canonical with --check)
    1   needs formatting (with --check) or syntax error

EXAMPLES
    doey scaffy fmt handler                # print to stdout
    doey scaffy fmt handler --write        # rewrite in place
    doey scaffy fmt --check                # CI-friendly: error if dirty
```

### `scaffy serve`

```text
SYNOPSIS
    doey scaffy serve [--stdio] [--port N] [--cwd DIR]

DESCRIPTION
    Start the Scaffy MCP server. With --stdio (the default for skill-embedded
    use), speaks the Model Context Protocol over stdin/stdout — this is the
    form Doey skills load. --port speaks MCP over HTTP for IDE clients.

FLAGS
    --stdio       MCP over stdin/stdout (default)
    --port N      Listen on TCP port N for HTTP MCP
    --cwd DIR     Workspace root the tools should resolve paths against
```

### Exit codes

| Code | Meaning                                                       |
|------|---------------------------------------------------------------|
| 0    | success                                                       |
| 1    | syntax error in a template                                    |
| 2    | anchor pattern not found in target file                       |
| 3    | every operation was blocked by guards                         |
| 4    | required variable missing and `--no-input` was set            |
| 5    | filesystem I/O error                                          |
| 10   | internal error (parser bug, panic, unexpected condition)      |

---

## Configuration

Workspace configuration lives in `scaffy.toml` at the workspace root. Scaffy walks upward from the process CWD looking for the file (the same way `git` walks for `.git/`), so commands run in any subdirectory of the workspace find the right config. If no `scaffy.toml` is present, Scaffy uses built-in defaults — a missing config is not an error.

```toml
# scaffy.toml — full workspace configuration

[project]
name = "doey"          # purely descriptive; surfaces in registry headers

[templates]
dir          = ".doey/scaffy/templates"   # where templates live
registry     = ".doey/scaffy/REGISTRY.md" # Orchestrator-managed inventory
audit_report = ".doey/scaffy/audit.json"  # last audit JSON

[defaults]
domain = "go-backend"   # used when a template omits DOMAIN
author = "frikk"        # used when a template omits AUTHOR

[discover]
git_depth     = 200     # commits to mine for accretion/refactor passes
min_instances = 3       # threshold for graduating a candidate to a finding
ignore        = ["build", "dist", "generated"]  # extra dirs to skip in walk

[output]
format = "human"        # "human" or "json"
color  = "auto"         # "auto", "always", or "never"
```

**Override behavior.** CLI flags always win. Within the file system, the *innermost* `scaffy.toml` (the one closest to the process CWD) is the one that loads — there is no merge across multiple files. Each file is parsed once, missing fields are filled in from `DefaultConfig()`, and the result is the final config.

| Section       | Field           | Default                          |
|---------------|-----------------|----------------------------------|
| `project`     | `name`          | `""`                             |
| `templates`   | `dir`           | `.doey/scaffy/templates`         |
| `templates`   | `registry`      | `.doey/scaffy/REGISTRY.md`       |
| `templates`   | `audit_report`  | `.doey/scaffy/audit.json`        |
| `defaults`    | `domain`        | `""`                             |
| `defaults`    | `author`        | `""`                             |
| `discover`    | `git_depth`     | `200`                            |
| `discover`    | `min_instances` | `3`                              |
| `discover`    | `ignore`        | `[]` (plus built-ins)            |
| `output`      | `format`        | `"human"`                        |
| `output`      | `color`         | `"auto"`                         |

The discover walker always skips `.git`, `node_modules`, and `vendor` regardless of the `ignore` list — those are hard-coded for safety.

---

## MCP Server

`doey scaffy serve --stdio` starts a Model Context Protocol server that exposes Scaffy's full surface area as MCP tools. This is how Doey workers drive Scaffy from inside an agent loop: instead of shelling out to the CLI and parsing text, they call `scaffy_run`, `scaffy_audit`, etc. and get structured JSON back.

The server is wrapped by the **doey-scaffy-mcp** skill, which uses Doey's skill-embedded MCP lifecycle (introduced in task #499). The lifecycle owns starting, restarting, and tearing down the server process — Claude does not have to know the binary path or stitch lifecycle code into every task.

**How a worker uses it.** Loading the `doey-scaffy-mcp` skill registers the seven tools and four resources below. From that point on, the worker can call them directly:

```
scaffy_run({ template: "handler", variables: { name: "user" }, dry_run: true })
```

The wire shape mirrors the CLI's `--json` output exactly so a worker that has worked with one surface already knows the other.

### Tools (7)

| Tool              | Wraps                  | Required arguments     | Optional arguments                              |
|-------------------|------------------------|------------------------|-------------------------------------------------|
| `scaffy_run`      | `scaffy run`           | `template`             | `variables` (object), `dry_run` (bool), `cwd`   |
| `scaffy_validate` | `scaffy validate`      | `template`             | `strict` (bool), `cwd`                          |
| `scaffy_list`     | `scaffy list`          | —                      | `domain`, `cwd`                                 |
| `scaffy_audit`    | `scaffy audit`         | —                      | `template`, `cwd`                               |
| `scaffy_discover` | `scaffy discover`      | —                      | `depth` (number), `cwd`                         |
| `scaffy_new`      | `scaffy new`           | `name`                 | `files` (array), `domain`, `cwd`                |
| `scaffy_fmt`      | `scaffy fmt`           | `template`             | —                                               |

Every tool returns a JSON document. For `scaffy_run` it is an `ExecuteReport` with `created`, `inserted`, `replaced`, and `skipped` arrays. For `scaffy_audit` it is an `AuditResult` with one entry per template.

### Resources (4)

MCP resources are read-only views — clients fetch them with the standard `resources/read` request:

| URI                          | Returns                                                             |
|------------------------------|---------------------------------------------------------------------|
| `scaffy://registry`          | Contents of `.doey/scaffy/REGISTRY.md`                              |
| `scaffy://audit`             | Last audit report JSON (`.doey/scaffy/audit.json`)                  |
| `scaffy://templates`         | Index of all discovered templates with name + path + DOMAIN         |
| `scaffy://template/{name}`   | Raw text of a single template, addressed by `TEMPLATE` name         |

The `scaffy://template/{name}` resource is templated — the `{name}` segment is filled in by the client. Calling `scaffy://template/handler` returns `.doey/scaffy/templates/handler.scaffy`.

---

## Agent team

Five Doey specialist agents collaborate to manage Scaffy. They live in `agents/doey-scaffy-*.md` and are spawned on demand by a Subtaskmaster when scaffy work shows up.

| Agent                            | Model  | Color    | Memory  | Role                                                                          |
|----------------------------------|--------|----------|---------|-------------------------------------------------------------------------------|
| `doey-scaffy-orchestrator`       | opus   | orange   | session | Always-on entry point. Owns `REGISTRY.md`, dispatches to other specialists.   |
| `doey-scaffy-pattern-discoverer` | opus   | purple   | none    | Runs `scaffy discover`, ranks candidates, hands off to the Template Creator.  |
| `doey-scaffy-template-creator`   | opus   | blue     | none    | Authors new `.scaffy` templates from inferred patterns or example files.      |
| `doey-scaffy-template-auditor`   | opus   | red      | none    | Runs the six audit checks, classifies templates, proposes targeted fixes.    |
| `doey-scaffy-syntax-reference`   | sonnet | teal     | session | Compact DSL cheat sheet; the other four query it when unsure about syntax.   |

**Dispatch flow.** A Doey Subtaskmaster receives a task that mentions scaffy. It dispatches to the **Orchestrator** first — the orchestrator owns the routing decision because it has the registry in front of it and knows the project's current scaffy state. Based on the user's intent (discover vs. create vs. audit vs. syntax-question), the orchestrator hands off to the right specialist via a follow-up dispatch.

Typical flows:

- **"What templates do we have?"** → Orchestrator answers from `REGISTRY.md` directly. No further dispatch.
- **"Find patterns we should template."** → Orchestrator → Pattern Discoverer → returns ranked candidates → Orchestrator updates `REGISTRY.md` with proposals.
- **"Turn these three files into a template."** → Orchestrator → Template Creator → validates + dry-runs → Orchestrator records in `REGISTRY.md`.
- **"Are our templates still healthy?"** → Orchestrator → Template Auditor → returns classified report → Orchestrator updates `REGISTRY.md` with statuses, dispatches Template Creator to fix `needs_update` rows.
- **"What does FOREACH do?"** → Orchestrator → Syntax Reference → answer returned to user.

The Syntax Reference is the only specialist the *other* specialists query, not just users. The Template Creator queries it when unsure about a transform spelling; the Auditor queries it when interpreting an anchor failure.

---

## Pattern discovery

`scaffy discover` runs three independent passes over the project and returns candidates from each. Each candidate has a category, a confidence score in `[0, 1]`, a list of instances (paths or commit hashes), and an evidence list.

### Structural

Walks the working tree. For each non-ignored directory, computes a *fingerprint* — the sorted, hyphen-joined list of unique file extensions. Files without an extension contribute the literal token `noext`. Directories with the same fingerprint bucket together; buckets reaching `min_instances` graduate to candidates.

```text
dirs-with-go            instances=12   conf=0.34
dirs-with-go-md         instances=5    conf=0.14
dirs-with-noext         instances=3    conf=0.08
```

**How to read.** A high-confidence fingerprint with semantically related instances (`handlers/user`, `handlers/order`, `handlers/item`) is a strong template candidate — the project is repeating that shape on purpose. A low-confidence fingerprint with scattered instances usually indicates noise the default ignore list missed; add the offending dir to `[discover].ignore`.

### Injection

Mines git history for **accretion files**: files that keep getting co-changed with a revolving cast of siblings. Routers, barrels, registries, and dependency-injection wiring all have this signature. The detector parses `git log -n <depth> --name-only`, filters out single-file commits, builds a co-occurrence map, and reports any file whose unique-sibling count meets `min_instances`.

The candidate name is `inject-into-<file>`. The confidence score is the diversity ratio: unique siblings divided by total commits touching the file. A diversity of `1.0` means every commit touched the file alongside a brand-new sibling — the canonical shape of a registry. A diversity below `0.5` usually means the file is along for the ride (a shared header in the same package).

### Refactoring

Mines git history for **suffix-pair co-creation**: file pairs that consistently appear together in commits and share a common stem. The classic shape is `<name>.go` + `<name>_test.go`, but it also catches `<name>.tsx` + `<name>.test.tsx`, `<name>.py` + `test_<name>.py`, component + story, handler + mock. The detector groups each commit's files by directory, finds pairs sharing a 3+ character prefix, sorts each pair into a stable key (`a+b`), and counts hits across commits.

The candidate name is `co-create-<key>`. The confidence is hit count divided by max-possible hits across the mined commits.

### Interpreting results

| Category    | High-quality signal                                      | Common false positive                             |
|-------------|----------------------------------------------------------|---------------------------------------------------|
| structural  | Many sibling dirs share a fingerprint                    | Generated/build dirs leak in                      |
| injection   | Diversity > 0.6 on a known registry-style file           | Shared headers that travel with every package edit |
| refactoring | Stable suffix pair across 3+ commits                     | Off-by-one rename pairs (`foo.go` ↔ `bar.go`)     |

---

## Template auditor

`scaffy audit` runs six health checks against every template. Each check returns a `CheckResult` (status + details + suggested fix); the per-template result is the union of those, classified into one of three statuses.

### The six checks

1. **Anchor validity.** For every `BEFORE`/`AFTER`/`ABOVE`/`BELOW`, the anchor pattern must resolve in its target file. If the target file was edited and the marker line is gone, the anchor is broken — the template would error on its next run.
2. **Guard freshness.** Every `UNLESS CONTAINS` and `WHEN CONTAINS` references a pattern. The check verifies the pattern is meaningful: long enough to be specific, present in the file under predictable circumstances, not trivially always-true.
3. **Path existence.** The parent directory of every `CREATE`/`FILE` path must still exist on disk. A template that writes into a deleted directory is dead weight.
4. **Variable alignment.** Declared `VAR`s must be referenced by the body, and references must resolve to declared `VAR`s. Drift in either direction means the template is half-edited.
5. **Pattern activity.** Cross-checks against `scaffy discover`: is the pattern this template represents *still* a recurring pattern in the project? A registry-injection template for a registry that has not been touched in 200 commits is probably obsolete.
6. **Structural consistency.** For structural templates, the directory shape they generate must still match a meaningful number of project directories. If the project pivoted away from that layout, the template is misleading even if it still parses cleanly.

### Classification

| Status         | Criteria                                                                  |
|----------------|---------------------------------------------------------------------------|
| `healthy`      | All six checks pass                                                       |
| `needs_update` | 1–2 checks fail, fixes are local (anchor swap, var rename, guard tweak)   |
| `stale`        | 3+ checks fail, or any individual check is critical (missing target file) |

### `--fix` workflow

`scaffy audit --fix` mechanically repairs the safe checks:

- **Variable alignment** — drops unused `VAR` declarations
- **Anchor validity** — swaps to the nearest stable comment marker if one exists within 5 lines of the original
- **Guard freshness** — updates path references via `git log --follow` when a file was renamed

It will **not** touch path existence, pattern activity, or structural consistency — those need human judgment. Always commit or stash before running `--fix`; the rewrites happen in place.

---

## End-to-end example

You inherit a Go project that has accumulated 12 handlers in `internal/handlers/`, each with its test file, each registered in a central `routes.go`. You want to scaffy this so the next handler is a one-liner.

**Step 1 — Discover.** What patterns are already there?

```bash
$ doey scaffy discover --depth 200
CATEGORY      CONF  NAME
structural    0.34  dirs-with-go
    instances: internal/handlers, internal/services, internal/middleware, …
injection     0.71  inject-into-internal/router/routes.go
    instances: internal/router/routes.go
refactoring   0.92  co-create-.go+_test.go
    instances: 23 commits
```

The injection pattern on `routes.go` and the refactoring pattern on `.go`/`_test.go` are both high-confidence — those become two scaffy templates.

**Step 2 — Generate the refactoring template from example files.**

```bash
$ doey scaffy new handler --from-files internal/handlers/user.go internal/handlers/user_test.go
created .doey/scaffy/templates/handler.scaffy
inferred variables: name (from "user")
```

Open the file. The stub will look something like:

```scaffy
TEMPLATE "handler"
DESCRIPTION "Handler + test pair"
VERSION "0.1.0"

VAR 1 "name"
  PROMPT "Handler name"
  TRANSFORM PascalCase

CREATE "internal/handlers/{{ .snakeCase name }}.go"
CONTENT :::
package handlers
// … inferred body …
:::

CREATE "internal/handlers/{{ .snakeCase name }}_test.go"
CONTENT :::
package handlers
// … inferred body …
:::
```

You add the injection op into the routes file by hand:

```scaffy
FILE "internal/router/routes.go"

INSERT :::
    "/{{ .kebabCase name }}": handlers.{{ .PascalCase name }}Handler,
:::
  AFTER "var Routes = map[string]http.HandlerFunc{"
  UNLESS CONTAINS "{{ .PascalCase name }}Handler"
  REASON "Register the {{ .PascalCase name }} handler in the central route table"
  ID "register-{{ .snakeCase name }}-route"
```

**Step 3 — Validate.**

```bash
$ doey scaffy validate handler --strict
handler: OK
    syntax: pass
    transforms: pass (3 explicit, 0 implicit)
    reasons:    pass
    ids:        pass
    guards:     pass
```

**Step 4 — Dry run.**

```bash
$ doey scaffy run handler --var name=invoice --dry-run --diff
PLAN: 2 created, 1 inserted, 0 skipped

+++ internal/handlers/invoice.go (created)
@@ +1,12 @@
+package handlers
+
+func InvoiceHandler(w http.ResponseWriter, r *http.Request) {
+    // …
+}

+++ internal/handlers/invoice_test.go (created)
@@ +1,8 @@
+package handlers
+
+func TestInvoiceHandler(t *testing.T) { … }

--- internal/router/routes.go
+++ internal/router/routes.go
@@ +12,1 @@
+    "/invoice": handlers.InvoiceHandler,
```

**Step 5 — Apply for real.**

```bash
$ doey scaffy run handler --var name=invoice
created  internal/handlers/invoice.go
created  internal/handlers/invoice_test.go
inserted 1 line into internal/router/routes.go
```

**Step 6 — Re-run to confirm idempotency.**

```bash
$ doey scaffy run handler --var name=invoice
0 created, 0 inserted, 3 skipped (already present)
```

**Step 7 — Audit a month later.** After 60 commits the auditor still gives the template a clean bill of health:

```bash
$ doey scaffy audit handler
handler: HEALTHY
  anchor_validity:        pass
  guard_freshness:        pass
  path_existence:         pass
  variable_alignment:     pass
  pattern_activity:       pass (4 new instances since last audit)
  structural_consistency: pass
```

If a future refactor renames `routes.go`, the auditor will flag the anchor and the guard, classify the template as `needs_update`, and `scaffy audit --fix` will rewrite the path automatically — provided you committed first.

---

## Architecture

Scaffy lives inside the Doey TUI module as a sub-package. It is not a separate Go module — it shares the `github.com/doey-cli/doey/tui` import path and is built by the Doey build pipeline. The binary is `doey-scaffy`, installed by Doey's installer alongside the other Doey shell utilities.

```text
tui/
├── cmd/
│   └── scaffy/
│       └── main.go          # Cobra entry point
└── internal/
    └── scaffy/
        ├── dsl/             # template types, parser, serializer, transforms
        │   ├── types.go
        │   ├── parser.go
        │   ├── serializer.go
        │   ├── substitute.go
        │   ├── transform.go
        │   ├── canonical.go
        │   ├── format.go
        │   └── registry.go
        ├── engine/          # execution pipeline
        │   ├── executor.go
        │   ├── anchor.go
        │   ├── guard.go
        │   ├── idempotency.go
        │   ├── include.go
        │   ├── foreach.go
        │   ├── fs.go
        │   ├── memfs.go
        │   └── planner.go
        ├── cli/             # Cobra subcommand wiring
        │   ├── root.go
        │   ├── run.go
        │   ├── validate.go
        │   ├── list.go
        │   ├── discover.go
        │   ├── audit.go
        │   ├── new.go
        │   ├── fmt.go
        │   ├── init.go
        │   └── serve.go
        ├── config/          # scaffy.toml loader
        │   └── loader.go
        ├── discover/        # pattern discovery passes
        │   ├── types.go
        │   ├── shapes.go
        │   ├── git.go
        │   ├── accretion.go
        │   └── refactor.go
        ├── audit/           # six health checks + report aggregation
        │   ├── checks.go
        │   └── report.go
        ├── output/          # JSON / human / diff renderers
        │   ├── json.go
        │   ├── human.go
        │   └── diff.go
        └── mcp/             # MCP server wrapping the tools above
            ├── server.go
            ├── tools.go
            └── resources.go
```

### Package responsibilities

| Package     | Responsibility                                                                            |
|-------------|-------------------------------------------------------------------------------------------|
| `dsl`       | Template types, EBNF parser, serializer, 11 case transforms, canonicalization, fmt logic |
| `engine`    | The seven-stage execution pipeline; anchor resolution; guards; idempotency; INCLUDE/FOREACH expansion; in-memory FS for dry runs; planner that diffs against disk |
| `cli`       | Cobra subcommand wiring; flag parsing; one file per subcommand; output routing            |
| `config`    | `scaffy.toml` loader with upward walk; `DefaultConfig()` and `ApplyDefaults()` for backfill |
| `discover`  | The three discovery passes (structural, injection via accretion, refactoring via suffix-pair) |
| `audit`     | The six audit checks and the per-template `AuditResult` aggregator                        |
| `output`    | JSON encoder, human table renderer, unified diff renderer (via `sourcegraph/go-diff`)     |
| `mcp`       | MCP server that wraps each CLI subcommand as a tool plus the four registry resources     |

### How scaffy fits inside Doey

- **Single binary.** `doey-scaffy` is built by Doey's `doey build` command and installed by `install.sh` alongside `doey` and the other shell utilities. There is no separate installer to run.
- **Shared module path.** The Go import path is `github.com/doey-cli/doey/tui/internal/scaffy/...` — scaffy lives under the TUI module so it shares dependencies and CI.
- **Bash 3.2 compatible.** The thin shell wrapper that exposes `doey scaffy` is bash 3.2 compatible (no `declare -A`, no `mapfile`, etc.) — see the project-wide constraint in CLAUDE.md.
- **Fresh-install safe.** A fresh `curl | bash` of Doey gets `doey-scaffy` for free. There is no second install step, no extra config, no manual file creation.
- **`.doey/` conventions.** All workspace state — templates, registry, audit reports — lives under `.doey/scaffy/`, the same root Doey uses for its own per-project state. Scaffy never writes to `~/.config/doey/` or any user-global path.

### The five Go dependencies

| Module                              | Used by    | Purpose                       |
|-------------------------------------|------------|-------------------------------|
| `github.com/spf13/cobra`            | `cli`      | Subcommand wiring             |
| `github.com/BurntSushi/toml`        | `config`   | `scaffy.toml` parsing         |
| `github.com/fatih/color`            | `output`   | Terminal colorization         |
| `github.com/sourcegraph/go-diff`    | `output`   | Unified diff rendering        |
| `github.com/mark3labs/mcp-go`       | `mcp`      | MCP SDK                       |

Everything else — parser, executor, transforms, canonicalization, anchor resolution, guard evaluation — is hand-written with zero dependencies outside the standard library.

---

## Doey integration

Scaffy exists *inside* Doey rather than alongside it. That difference shapes a handful of decisions you should know about if you have used scaffy-like tools elsewhere.

**Fresh-install invariant.** Every Scaffy feature must work after `curl | bash`. There is no "setup wizard" you run once after installing. `doey scaffy init` creates a workspace in the current project, but a Scaffy install with no workspace is still functional (`scaffy --version`, `scaffy --help`, etc.). All defaults are baked into `config.DefaultConfig()`.

**Bash 3.2 portability.** The `doey scaffy` shell wrapper is constrained to bash 3.2 — it runs on macOS's stock `/bin/bash`. The Go binary it dispatches to has no such constraint, so the heavy lifting all happens in Go.

**`.doey/` conventions.** Scaffy stores everything per-project under `.doey/scaffy/`:

```text
.doey/
├── scaffy/
│   ├── templates/    # *.scaffy files
│   ├── REGISTRY.md   # human-readable inventory, Orchestrator-managed
│   └── audit.json    # last audit report
└── config.sh         # Doey project config (separate from scaffy.toml)
```

There is no user-global scaffy state — templates do not bleed across projects. Even the Orchestrator's REGISTRY is project-local.

**Skill-embedded MCP lifecycle.** The `doey-scaffy-mcp` skill uses Doey's task #499 lifecycle: starting the server is as simple as loading the skill, restarting/teardown is handled by Doey rather than by scaffy itself. Workers do not have to know the binary path or stitch lifecycle code into every task.

**Specialist agents over a single CLI agent.** Other scaffy-like tools tend to have a single "scaffy assistant" agent. Doey instead ships five specialists (Orchestrator, Pattern Discoverer, Template Creator, Template Auditor, Syntax Reference). Each is small and focused; the Orchestrator routes between them. A Subtaskmaster always dispatches to the Orchestrator first.

**Differences from a hypothetical standalone scaffy CLI.**

| Concern                         | Doey-integrated scaffy           | Hypothetical standalone scaffy   |
|---------------------------------|----------------------------------|----------------------------------|
| Install                         | Ships with Doey                  | Separate `go install`            |
| Config root                     | `.doey/scaffy/`                  | `.scaffy/`                       |
| Agent integration               | 5 specialist Doey agents         | Cursor `.cursor/rules/` or AGENTS.md |
| MCP lifecycle                   | Skill-embedded (task #499)       | User-managed                     |
| Bash wrapper                    | Bash 3.2 portable                | Whatever                         |
| Cross-project state             | None — fully project-scoped      | Variable                         |

---

## Troubleshooting

### `doey scaffy --version` exits non-zero

The `doey-scaffy` binary is missing. Rebuild it:

```bash
doey build
```

If `doey build` fails, check `doey doctor` for the underlying problem (missing Go toolchain, broken `~/.local/bin`, etc.).

### "anchor not found" during `scaffy run`

The template references an anchor pattern that no longer matches the target file. Run the auditor:

```bash
doey scaffy audit <template>
```

The `anchor_validity` check will tell you which anchor failed and which file it was looking in. Fix by either editing the template's anchor to match the current file content, or running `scaffy audit --fix` which will mechanically swap the anchor to the nearest stable comment marker within 5 lines of the original.

### "every operation was blocked by guards" (exit code 3)

Every op in the template was guarded out — either every `UNLESS CONTAINS` matched (because the template was already applied) or every `WHEN CONTAINS` failed (because the file wasn't in the expected state). Re-run with `--dry-run --diff` to see what each op decided.

### "required variable missing" (exit code 4)

You ran with `--no-input` and a required variable had no `--var`, `--vars-file`, env var, or `DEFAULT`. Either supply the variable or remove `--no-input` and let Scaffy prompt.

### Discover returns nothing

Three things to check:

1. Are you in a git repository? `scaffy discover` mines `git log` and silently returns empty if `git` errors.
2. Is `git_depth` high enough? Try `--depth 500`.
3. Are your dirs being filtered by the ignore list? Check `scaffy.toml` and the built-in `.git`/`node_modules`/`vendor` exclusions.

### Audit reports `pattern_activity: fail`

The pattern this template represents has not been seen in the most recent `git_depth` commits. Either the pattern is genuinely obsolete (retire the template via `scaffy audit --fix` or by deleting the file) or your `git_depth` is too low (raise it in `scaffy.toml`).

### `doey doctor`

Run for a comprehensive Doey + Scaffy health check:

```bash
doey doctor
```

It verifies that `doey-scaffy` is on `PATH`, that the workspace is initialized (if you are inside one), and that the agent definitions are present. A green `doey doctor` is the canonical "scaffy is healthy" signal.

---

## See also

- `agents/doey-scaffy-orchestrator.md` — Orchestrator agent definition
- `agents/doey-scaffy-pattern-discoverer.md` — Pattern Discoverer agent definition
- `agents/doey-scaffy-template-creator.md` — Template Creator agent definition
- `agents/doey-scaffy-template-auditor.md` — Template Auditor agent definition
- `agents/doey-scaffy-syntax-reference.md` — Syntax Reference agent definition
- `docs/context-reference.md` — authoritative Doey architecture reference
- `CLAUDE.md` — Doey contributor rules (fresh-install invariant, bash 3.2, `.doey/` conventions)
