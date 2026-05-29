---
name: doey-scaffy-mcp
description: Spawn the doey-scaffy MCP server so workers can drive the Scaffy template engine via tool calls. Loaded automatically when a task needs scaffy_run / scaffy_validate / scaffy_list / scaffy_audit / scaffy_discover / scaffy_new / scaffy_fmt or any scaffy:// resource.
mcp_servers:
  - name: doey-scaffy
    command: doey-scaffy
    args: serve --stdio
    env: {}
---

# Doey Scaffy MCP Skill

When this skill is loaded, Doey's skill-embedded MCP lifecycle (task #499)
parses the `mcp_servers` block above, generates a per-pane `.mcp.json`
config in `$DOEY_RUNTIME/mcp/`, and launches the Claude instance with
`--mcp-config <path>`. The `doey-scaffy` binary is spawned as a stdio
MCP server for the duration of the worker's session.

## Usage

Load this skill from any worker that needs to run, validate, list, or
generate `.scaffy` templates. The MCP tools below appear in the worker's
tool palette as `mcp__doey-scaffy__<tool-name>` and the resources as
`mcp__doey-scaffy__<resource-uri>`.

No manual setup is required — the skill spawns the server, and Doey's
team-despawn cleanup tears down the MCP process and config when the
team is killed.

## Tools

- `scaffy_run` — Apply a `.scaffy` template to the working tree (the 7-stage execution pipeline).
- `scaffy_validate` — Parse a template and (optionally) run strict validation checks.
- `scaffy_list` — List the templates available in `.doey/scaffy/templates/`.
- `scaffy_audit` — Report which templates are stale, broken, or missing canonical formatting.
- `scaffy_discover` — Mine the working tree and git history for scaffolding patterns: structural directory shapes, accretion (injection) files, and refactoring co-creation pairs.
- `scaffy_new` — Scaffold a new template stub, optionally seeded from existing files.
- `scaffy_fmt` — Format a template to canonical form (idempotent Parse + Serialize).

## Resources

- `scaffy://registry` — The `.doey/scaffy/REGISTRY.md` catalog, served as `text/markdown`.
- `scaffy://audit` — JSON report of registry health (stale, broken, drift).
- `scaffy://template/{name}` — The raw `.scaffy` source of a single template.
- `scaffy://templates` — A JSON array of RegistryEntry objects (one per discoverable template).

## Notes

- The `doey-scaffy` binary must be installed at `~/.local/bin/doey-scaffy`.
  It is built from `tui/cmd/scaffy/` by `_build_all_go_binaries` in
  `shell/doey-go-helpers.sh` and installed alongside the rest of Doey's
  Go binaries. If the binary is missing, run `doey reinstall` (or
  `doey doctor` to confirm) before loading this skill.
- MCP servers start at Claude launch — they cannot be added or removed
  at runtime, so this skill must be present in the worker's loaded
  skill set when the pane is spawned.
- Each team gets an independent `doey-scaffy` MCP process; there is no
  cross-team sharing of in-memory registry state.
