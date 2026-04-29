# doey-state-mcp

Read-only MCP (Model Context Protocol) server that exposes Doey runtime
state — tasks, panes, the message DB, status files, and plans — over stdio
JSON-RPC 2.0.

This is the Doey side of OpenClaw's "convenience telemetry" channel: an
LLM-friendly way to ask "what's Doey doing right now?" without screen-scraping
tmux or wrangling the CLI.

## Run

```
doey-state-mcp           # speaks MCP on stdin/stdout, logs to stderr
doey-state-mcp --version
doey-state-mcp --help
```

OpenClaw registers the binary via:

```
openclaw mcp set doey-state stdio /path/to/doey-state-mcp
```

## Tools

| Tool | Purpose |
|------|---------|
| `tasks_list` | Filter `.doey/tasks/*.task` by status/assignee |
| `task_get` | Parse one task file (fields, subtasks, decisions, notes) |
| `pane_layout` | Tmux windows / panes / role / status snapshot |
| `msg_db_recent` | Recent entries from the internal event/message log |
| `status_files_read` | Per-pane `READY/BUSY/FINISHED/RESERVED` markers + optional worker results |
| `plan_get` | Read a `.doey/plans/` masterplan (most recent if no id given) |

All tools are read-only. The server never writes to Doey state, never
shells out to the `doey` CLI, and never starts/stops processes.

## Redaction

**Convenience telemetry, NOT a confidentiality boundary.**

Every byte that leaves this process passes through a regex redactor
(`server.go` → `RedactBytes`) at the JSON-RPC write boundary. Patterns
are applied in this order — **specific labels first**, generic catch-alls
last — so that e.g. `Authorization: Bearer ghp_…` is captured by the
header rule before `gh[pousa]_…` or `bearer …` get a chance to leave a
fragment behind:

| # | Pattern | Replacement |
|---|---------|-------------|
| 1 | `Authorization: <value>` (header) | `Authorization: [redacted]` |
| 2 | `sk-…` (Anthropic / OpenAI, 20+ chars) | `[redacted]` |
| 3 | `gh[pousar]_…` (GitHub PAT/OAuth/server/refresh/app) | `[redacted]` |
| 4 | `xoxb-…` (Slack bot token) | `[redacted]` |
| 5 | `xoxa-…` (Slack legacy admin) | `[redacted]` |
| 6 | `bridge_hmac_secret = …` | `bridge_hmac_secret=[redacted]` |
| 7 | `gateway_token = …` | `gateway_token=[redacted]` |
| 8 | generic `token = <value>` / `token: <value>` | `token=[redacted]` |
| 9 | standalone `bearer <value>` (16+ chars) | `bearer [redacted]` |

**Why "convenience telemetry"**: this is a misuse-resistant best-effort
filter, not a vault. It will miss novel secret formats, custom env-var
names that we haven't thought to add, and anything embedded inside
structured payloads it doesn't know to inspect. The patterns also
deliberately let prose containing the literal words "token", "bearer",
"Authorization", "github", "skiing", or "xoxb" pass through unchanged so
documentation and chat history don't end up shredded.

**Operational rule**: rotate any credential that appears in Doey state.
Do not put real secrets through this server expecting them to stay
private. If a secret truly must never reach the model, keep it out of
the files this server can read — isolate at the OS level (file perms,
separate UIDs, container).

**JSON keys are not scanned, only values.** The redactor operates on the
serialized byte stream after a `json.Marshal`, so JSON syntax (quotes,
braces, escapes) is preserved across redactions. Patterns that consume
quoted values capture the surrounding `"` separately so the result is
still parseable JSON.

A unit test suite (`redact_test.go`) covers every pattern with positive
(must redact) and negative (prose / English words / opaque hex) cases,
plus an end-to-end JSON round-trip check.

## Status

- Phase 3b: 6 read-only tools implemented + boundary redaction + tests.
- Subtask 4 wires retroactive MCP registration into the OpenClaw wizard
  and `doey openclaw doctor --fix`.
