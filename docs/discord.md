# Discord integration

## What it does

Doey can optionally route its notifications (task completions, Boss questions,
worker crashes, errors) to a single Discord destination. Outbound only — Doey
never runs a bot process or subscribes to Discord events.

Each Doey instance binds to exactly one destination:

- **Webhook** — point at a channel via Discord's Incoming Webhook URL. No bot,
  no OAuth, no intents.
- **Bot DM** — DM a specific user via a per-user bot + mutual-guild verification.

There is no Doey-owned service, no shared bot, no verification gate. Users bring
their own Discord artefacts. The integration is fresh-install clean: if you
don't bind, nothing about Doey changes.

## Quickstart (recommended: webhook + personal-server pattern)

1. Open Discord → **New Server** → pick the "Personal" template (any name; just
   for you).
2. Create a channel — e.g. `#doey-alerts`.
3. Channel settings → **Integrations** → **Webhooks** → **New Webhook** → **Copy
   Webhook URL**.
4. `doey discord bind --kind webhook` → paste URL when prompted. *(Phase 3 —
   coming soon: today, hand-edit `~/.config/doey/discord.conf`; see "Manual
   bind" below.)*
5. `doey discord send-test` to verify.

### Why "personal server"?

A webhook on a channel in a 1-person server gives you the same effect as a bot
DM — private notifications, only you see them — without the OAuth dance, bot
creation, or mutual-guild verification.

Webhooks have one trade-off vs bot DMs: **anyone with the URL can post**. Keep
it secret. If the URL leaks, rotate it from the channel's Integrations →
Webhooks page; Doey will detect the rotation via `cred_hash` and invalidate its
rate-limit bucket automatically.

## Manual bind (Phase 1)

Until the bind wizard lands in Phase 3, write `~/.config/doey/discord.conf` by
hand. Doey refuses to read it unless it is mode `0600`:

```sh
chmod 600 ~/.config/doey/discord.conf
```

Contents:

```ini
[default]
kind=webhook
webhook_url=https://discord.com/api/webhooks/<channel_id>/<token>
label=My personal server
created=2026-04-19
```

Then create `<your-project>/.doey/discord-binding` containing the single word:

```
default
```

Verify:

```sh
doey discord status
```

## Bot DM (Phase 3 — coming soon)

*Will follow ADR-7 — a 7-step OAuth2 wizard: create Application → create Bot →
paste token → Doey generates an OAuth2 invite URL → you authorize a mutual
server → paste your user id → Doey verifies and binds.*

For now, use the personal-server pattern above. Same private-stream effect,
zero OAuth.

## Privacy model

- **Default: metadata only.** Title + task id + event kind + duration. Bodies
  are never sent.
- **Boss-question exception:** the first 200 bytes (rune-bounded) of the prompt
  body, run through the redaction helper before send. This is the only event
  class that ships body-content by default.
- **Overrides:**
  - `DOEY_DISCORD_INCLUDE_BODY=1` — opt into body content for all events.
  - `DOEY_DISCORD_METADATA_ONLY=1` — always wins. Set both → strict metadata.
- **Toggles live in `~/.config/doey/config.sh`** (user-level), *not*
  `.doey/config.sh`. This prevents accidental commits of privacy opt-outs
  that would surprise collaborators. The `[p]` key in the Discord tab writes
  to the user-level config.
- **Redaction runs before truncation.** Truncating first could leave a partial
  secret that redaction missed.

Known redaction patterns (non-exhaustive — see
`tui/internal/discord/redact/README.md` once Phase 2 lands):

| Provider | Structural form |
|---|---|
| OpenAI | `sk-<~48 base62 chars>` |
| Anthropic | `sk-ant-api<version>-<opaque>` |
| GitHub | `gh<letter>_<opaque>` where letter is one of `p o u s r` |
| Slack | `xox<letter>-<digits>-<digits>-<opaque>` where letter is one of `a b p` |
| AWS access key id | `AKIA<16 uppercase alnum>` |
| Stripe live | `sk_live_<opaque>` |
| Discord webhook URL | `https://discord.com/api/webhooks/<channel_id>/<token>` (also `discordapp.com` variant) |
| Generic bearer header | `Authorization: Bearer <opaque>` |
| Private keys | PEM `BEGIN ... PRIVATE KEY` header blocks (RSA, OPENSSH, EC, DSA, unlabeled) |
| Password / secret kv | lines of the form `password=<value>`, `secret=<value>`, `api_key=<value>` |
| Long base64 | opaque base64-alphabet runs of ~40+ characters |

"Opaque" above means any provider-defined token body. The redaction helper
replaces the match with `……xxxx` (showing the last 4 characters so users can
still correlate logs) rather than printing the full secret.

## Configuration files

| Path | Format | Permissions | Scope | Created by |
|---|---|---|---|---|
| `~/.config/doey/discord.conf` | INI | `0600` (required) | user | manual (Phase 1) / bind wizard (Phase 3) |
| `<project>/.doey/discord-binding` | one-line stanza name | any | project | bind command |
| `<project>/.doey/.gitignore` | gitignore rules | any | project | `install.sh` + `on-session-start.sh` |
| `/tmp/doey/<project>/discord-rl.state` | JSON (flock + tmp+rename) | any | session | Phase 2 |
| `/tmp/doey/<project>/discord-failed.jsonl` | append-only JSONL | any | session | Phase 2 |

`.doey/.gitignore` is created by `install.sh` and re-ensured on every session
start by `on-session-start.sh` — the binding file is never committed
accidentally, even if a user rebinds before the next install.

The rate-limit state and failure log live under `/tmp/doey/<project>/` so they
are ephemeral (cleared on reboot) and project-scoped (two projects sharing one
credential maintain independent rate-limit state — see "Limits" below).

## Hook integration

Doey's notification hooks forward Boss-class events to Discord through a
single shell helper. No hook calls `doey-tui discord send` directly —
they go through `send_notification`, which applies the role + cooldown
gates before forwarding.

- `send_notification(title, body, event_kind)` in `.claude/hooks/common.sh`
  forwards Boss events to Discord when
  `$DOEY_PROJECT_DIR/.doey/discord-binding` exists.
- `event_kind` is an explicit 3rd positional argument with default
  `generic`. Back-compat is preserved: old two-arg callers still work.
- Call-sites:
  - `stop-notify.sh` — `event_kind=boss_message`
  - `on-notification.sh` — `event_kind=boss_question`
- Non-Boss events stay desktop-only (ADR-8). Worker/Subtaskmaster stops
  never reach Discord; only the Boss role triggers the forwarder.
- CLI invocation: body is supplied on **stdin only**. The `doey-tui discord
  send` argv never carries body content, so a `ps` snapshot on a
  multi-tenant host cannot observe the message body. The privacy gate
  (see next section) is evaluated before the body is truncated and
  redacted.

## Privacy defaults

The CLI defaults to **metadata-only** sends. Opting in to body content is
a deliberate action, and the strict opt-out always wins.

Precedence (first match wins):

| Setting | Effect |
|---|---|
| `DOEY_DISCORD_METADATA_ONLY=1` | Strict metadata. Always wins, even if `INCLUDE_BODY=1` is also set. |
| `DOEY_DISCORD_INCLUDE_BODY=1` | Include body for all events. |
| *(neither set)* | **Default: metadata-only.** |

Where toggles live:

- The TUI Discord tab `p` key cycles the privacy mode: `off → metadata_only
  → include_body → off`. Cycling writes the current choice to
  `~/.config/doey/config.sh` (user-level, not `.doey/config.sh`) so that
  a privacy opt-out is never accidentally committed to a shared repo.
- Environment variables override the on-disk toggle for the duration of a
  single invocation.

When `include_body` is active:

- The body is run through the 12-pattern redaction scrubber (see
  "Known redaction patterns" above) **before** truncation, so a partial
  match cannot leak a secret that redaction would have caught.
- After redaction, the content is **rune-bounded truncated to 200 bytes**
  to fit Discord limits without splitting a UTF-8 codepoint.

## End-to-end test runner

Two scripts under `tests/` exercise the Discord send path. Neither runs
in CI by default — the e2e probe hits a real webhook, and the argv-leak
test is a local integrity check.

- **`tests/test-discord-e2e.sh`** — opt-in real-API probe.
  - Gate: set `DOEY_DISCORD_E2E_WEBHOOK` to a webhook URL of the form
    `https://discord.com/api/webhooks/<id>/<token>`.
  - Skips silently (exit 0) when the env var is unset or when `$CI` is
    truthy (`1`, `true`, `yes`, case-insensitive).
  - Sends one probe message and asserts `doey-tui discord send` exited 0.
    Delivery verification is left to a human — the script does not parse
    the Discord response.
  - The webhook URL is masked (first 32 chars + ellipsis) before printing.
  - Example:
    ```sh
    DOEY_DISCORD_E2E_WEBHOOK="https://discord.com/api/webhooks/<id>/<token>" \
      bash tests/test-discord-e2e.sh
    ```
- **`tests/test-discord-argv-leak.sh`** — argv leak guard. No env var
  required. Pipes a unique probe token on stdin, samples `ps` while the
  send process is live, and fails if the token ever appears in any
  process's argv. Skips when `doey-tui` is not on PATH.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `doey discord status` says "no binding" | `<project>/.doey/discord-binding` missing | Bind via wizard (Phase 3) or write the file by hand |
| `chmod 600 required` | `~/.config/doey/discord.conf` is world-readable | `chmod 600 ~/.config/doey/discord.conf` |
| `unknown stanza: <name>` | binding file points at a non-existent stanza | Edit `<project>/.doey/discord-binding` to `default` |
| `flock(2) unsupported` | filesystem doesn't support `flock(2)` (some FUSE, overlay) | Move config off the unsupported FS — see [POSIX and flock requirement](#posix-and-flock-requirement) |
| `bot_dm support lands in Phase 3` | bound with `kind=bot_dm` before Phase 3 ships | Rebind as webhook (personal-server pattern) |
| `send CLI lands in Phase 2` | tried `doey discord send` before Phase 2 ships | Wait for Phase 2, or use the bound channel directly |

## POSIX and flock requirement

Doey requires a POSIX filesystem that supports `flock(2)` for the Discord state
directory (`/tmp/doey/<project>/`) and for the credentials file
(`~/.config/doey/discord.conf`).

- **Non-POSIX FS** → Doey cannot enforce `chmod 600` on the credentials file;
  refuses to load with a link to this section.
- **`flock(2)` unsupported** → concurrent sends could corrupt RL state; Doey
  refuses to send with `Error` status.

`doey doctor` warns when either condition is detected (presence/permissions
only — no network calls).

## Ratelimits and circuit breaker (Phase 2 — coming soon)

*Stub — Phase 2 will document the rate-limit state machine, coalesce window
(30s), circuit breaker (opens after 5 consecutive failures), and the `[c]`
clear action in the Discord tab.*

## Failure log (Phase 2 — coming soon)

*Stub — `doey discord failures [--tail N]` will list permanent failures,
`--prune` clears the log, and `--retry <id>` replays a specific entry
(labeled "Retry (may duplicate)").*

## Limits

- **One destination per Doey instance.** No fan-out; no multi-server.
- **Outbound only.** No slash commands, no reactions, no two-way chat.
- **Cross-project rate-limits are independent.** Two projects sharing one
  credential maintain separate RL state under their own
  `/tmp/doey/<project>/discord-rl.state`; each correctly handles
  per-project 429s but does not coordinate across projects.
- **Windows not yet supported.**
