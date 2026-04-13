# Doey Documentation

Authoritative docs for the Doey CLI and its multi-agent architecture. Start
with [`context-reference.md`](context-reference.md) for the architectural
overview, then drop into the reference section below for command-by-command
detail.

## Reference

- [`reference/cli.md`](reference/cli.md) — full `doey` and `doey-ctl` command
  surface, sourceable shell library functions, and the hook contract.
- [`reference/messaging.md`](reference/messaging.md) — role topology, message
  subjects, trigger files, and `tmux send-keys` rules.
- [`reference/storage.md`](reference/storage.md) — runtime layout, on-disk
  state, and database schema.
- [`reference/cookbook.md`](reference/cookbook.md) — copy-paste recipes for
  common Doey operations.

## Architecture and concepts

- [`context-reference.md`](context-reference.md) — authoritative architecture
  reference.
- [`context-overlays.md`](context-overlays.md) — how role overlays are layered
  on top of base agent definitions.
- [`improving-agents.md`](improving-agents.md) — guide to customizing and
  iterating on agents.
- [`visualization-grammar.md`](visualization-grammar.md) — grammar for the
  status visualizations in the dashboard.

## Configuration and tooling

- [`configuration.md`](configuration.md) — config file hierarchy and keys.
- [`debug-mode-design.md`](debug-mode-design.md) — flight-recorder debug mode.
- [`enforce-ask-user-question.md`](enforce-ask-user-question.md) — the
  `AskUserQuestion` enforcement hook.
- [`intent-fallback.md`](intent-fallback.md) — Haiku-powered command
  correction layer for unknown `doey` subcommands.
- [`scaffy.md`](scaffy.md) — Scaffy template engine.
- [`stats.md`](stats.md) — local stats emission and queries.
- [`violations.md`](violations.md) — violation tracking and ledger.

## Hosting and deployment

- [`hetzner-setup.md`](hetzner-setup.md)
- [`linode-setup.md`](linode-setup.md)
- [`linux-server.md`](linux-server.md)
- [`windows-wsl2.md`](windows-wsl2.md)

## Testing

- [`test-worktree.md`](test-worktree.md) — running the E2E tests against an
  isolated worktree.
