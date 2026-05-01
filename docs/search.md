# Smart Search

Doey indexes every task, subtask, decision, log entry, and message into a SQLite database (`.doey/doey.db`). Two complementary search surfaces sit on top:

1. **FTS5 full-text** (`tasks_fts`, `messages_fts`) — BM25-ranked snippet search across titles, descriptions, notes, acceptance criteria, decision bodies, log bodies, and message subjects/bodies.
2. **URL extraction table** (`task_urls`) — every URL ever pasted into a task is parsed at write-time, classified by host (figma, github, slack, linear, sanity, loom, notion, generic), and indexed by host substring.

The DB is built incrementally as tasks are created/updated. Existing rows can be re-indexed with `--backfill-urls`.

## CLI: `doey-ctl search`

```sh
doey-ctl search "auth flow"                  # FTS5 search across tasks
doey-ctl search --type message "rate limit"  # FTS5 search across messages
doey-ctl search --url figma                  # host-substring URL search
doey-ctl search --backfill-urls              # re-extract URLs from every row
```

| Flag | Meaning |
|------|---------|
| `--type task\|message\|decision\|log` | FTS5 scope (default: task) |
| `--url <pattern>` | switch to URL-host mode (LIKE `%pattern%`) |
| `--kind figma\|github\|slack\|linear\|sanity\|loom\|notion\|generic` | URL kind filter (URL mode only) |
| `--field <name>` | restrict URL match to a labeled source field (URL mode only) |
| `--since 30d\|2w\|6h\|YYYY-MM-DD` | recency filter |
| `--limit N` | result cap (1–100, default 20) |
| `--json` | emit `SearchResult[]` JSON |
| `--verbose` | show BM25 scores in human output |

Human output:

```
[task#664] [fts5-fix] Fix FTS5 query sanitization — Fix <b>FTS5</b> query sanitization
[task#659] [search] Smart SQLite search — URL extraction table + <b>FTS5</b> full-text
```

Exits `1` if no results.

## CLI: `doey-ctl msg search`

A message-DB-only convenience over `doey-ctl search --type message`. Same flags, same JSON shape. Use this when you want the FTS5 hit list scoped strictly to inter-pane messages without remembering the `--type` flag.

```sh
doey-ctl msg search "task_complete"
doey-ctl msg search --since 1d --limit 10 "subtaskmaster"
```

## MCP server: `mcp__doey__search`

The same engine exposed over stdio JSON-RPC for MCP clients (Claude Code, OpenClaw). Binary: `~/.local/bin/doey-search-mcp` (built/installed alongside `doey-state-mcp`).

Two tools:

### `text_search`

```json
{
  "query": "FTS5 sanitize",
  "type":  "task",
  "since": "30d",
  "limit": 20
}
```

Returns `{ count, results: [{ task_id, title, shortname, snippet, score, matched_field, ts }] }`. Snippets wrap matched terms in `<b>…</b>`. Score is BM25 (lower = better). `type` accepts `task` (default), `message`, `decision`, `log`.

### `url_search`

```json
{
  "query": "figma",
  "kind":  "figma",
  "field": "description",
  "since": "2w",
  "limit": 20
}
```

Returns `{ count, results: [{ task_id, title, matched_url, matched_field, ts }] }`. `query` is a host substring (case-insensitive `LIKE %query%`).

Fresh-install behavior: when `.doey/doey.db` does not exist yet, both tools return `{ results: [], note: "no search DB found …" }` instead of erroring — the MCP server never panics on a missing DB.

## FTS5 syntax notes

User input is always sanitized before it reaches FTS5 (see #664), so the query language as a user types it is the **safe subset**:

- Whitespace splits tokens; tokens are AND-joined.
- Each token is wrapped as a quoted phrase, so internal punctuation, dashes, colons, asterisks, parens, and operator words (`AND`, `OR`, `NOT`, `NEAR`) become literal phrase content rather than FTS5 operators.
- Prefix wildcards (`token*`) are **not** parsed as wildcards by the sanitizer — the `*` becomes part of the phrase. Use plain word fragments and rely on stemming + token order instead.
- Multi-word phrases are matched implicitly: `doey-ctl search "auth flow"` searches for the token `"auth"` AND the token `"flow"`, not the literal sentence `"auth flow"`.

If you need raw FTS5 power (e.g. column filters like `title:auth`), use the underlying SQL directly via `sqlite3 .doey/doey.db` — but the sanitized path is intentionally the only one exposed through the CLI and MCP surfaces.

## Sanitization behavior (#664)

Before #664 a query containing any FTS5 metachar (e.g. `--type message ":"` or a stray `*`) caused `sqlite3: SQL logic error: fts5: syntax error near ":"`. The fix wraps every whitespace-separated token as a quoted phrase, doubling internal `"` chars. Failure modes that used to crash now return a clean error or an empty result:

| Input | Behavior |
|-------|----------|
| `""` (empty) | `search query is empty` error |
| `:` | sanitized to `":"` — matches literal colons in indexed text (usually zero hits) |
| `auth*` | sanitized to `"auth*"` — matches literal `auth*`, not a prefix |
| `auth -- flow` | three tokens, AND-joined: `"auth" "--" "flow"` |
| `Bob's` | sanitized to `"Bob's"` — apostrophe survives intact |

## Troubleshooting

- **No results, but you know the term is in a task** — the FTS index might be behind. The detector runs on write; if a row was inserted before the FTS triggers landed, run `doey-ctl search --backfill-urls` and (for full FTS rebuild) re-save the affected task via `doey-task edit`.
- **Empty results from MCP, populated results from CLI** — check `DOEY_PROJECT_DIR`. The MCP server reads `DOEY_PROJECT_DIR` first, then falls back to the process cwd. When launched by an MCP client without that env var, point it at the right project.
- **`no search DB found` note from MCP** — fresh-install path. The DB is created the first time `doey-ctl` writes to a project. Run any `doey-ctl task add …` or `doey-ctl msg send …` once and the DB will materialize.
- **Stale URL index** — URLs are extracted at write time. To re-extract over the entire history (idempotent, dedup-safe via DELETE-then-INSERT inside `StoreURLs`):

  ```sh
  doey-ctl search --backfill-urls
  ```

## Related

- Task #659 — original Smart SQLite search plan
- Task #664 — FTS5 query sanitization fix
- Task #668 — completion of #659 missing surfaces (this MCP server, msg search CLI, tests, this doc)
- `tui/internal/search/query.go` — `URLSearch`, `TextSearch`, `sanitizeFTS5Query`
- `tui/cmd/doey-search-backfill/` — standalone URL backfill tool
- `tui/cmd/doey-search-mcp/` — MCP server source
