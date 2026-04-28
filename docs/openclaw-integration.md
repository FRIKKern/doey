# OpenClaw integration

OpenClaw is an MIT-licensed self-hosted gateway (`localhost:18789`) that exposes
multi-channel I/O (Discord, Slack, and ~20 other adapters), three Gateway HTTP
APIs (Tools-Invoke, OpenAI-compat, OpenResponses), and a bidirectional MCP
surface. Doey integrates with OpenClaw as an **opt-in, Boss-centric notification
and inbound layer**, with v1 shipping a Discord round-trip demo.

Doey remains the source of truth for tasks, plans, and files. OpenClaw owns
channels, message routing, and presence. The two systems coexist with a hard
fresh-install invariant: a user who never runs `/doey-openclaw-connect` sees
zero behavior change, zero artifacts on disk, and zero network calls into the
OpenClaw daemon.

## Setup

### Prerequisites

- **Node.js ≥ 22.14** — required by the OpenClaw daemon. The wizard runs
  `node --version` as a warn-not-fail pre-check.
- **OpenClaw gateway daemon** — listening on `http://localhost:18789` by
  default. Install per upstream OpenClaw docs; Doey does not bundle the
  daemon.
- **A gateway access token** issued by OpenClaw (see "Authentication" below).
- **A Discord channel id** to bind this project to.

### Walkthrough

Inside the Doey session, run:

```
/doey-openclaw-connect
```

The wizard runs entirely in the Boss pane, prompts for inputs via
`AskUserQuestion`, and delegates filesystem writes to the host helper
`shell/doey-openclaw.sh connect`. Steps:

1. **Pre-flight checks** — Node.js version + daemon liveness. Both warn-not-
   fail; the wizard continues even if the daemon is down (you can configure
   now and the bridge will start when the daemon comes up).
2. **Round 1 — gateway** — gateway URL (default `http://localhost:18789`)
   and gateway access token.
3. **Round 2 — binding** — Discord channel id, thread strategy
   (`per-task` default), optional `bound_user_ids` allowlist, optional
   `legacy_discord_suppressed` toggle.
4. **Auto-generate** `bridge_hmac_secret` (32 bytes from `/dev/urandom`) —
   never prompted.
5. **Smoke version-pin** — daemon version vs `OPENCLAW_MIN_VERSION`. Reject
   below; defer if daemon was unreachable at pre-flight (per-reconnect smoke
   covers it later).
6. **Atomic writes + rollback** — helper writes `~/.config/doey/openclaw.conf`
   (mode `0600`) and `<project>/.doey/openclaw-binding`. On mid-wizard
   failure, the helper deletes `openclaw.conf` so no half-config remains.
7. **Idempotent bridge spawn** — wizard ends with
   `doey openclaw bridge-spawn` (no-op if PID file is alive). Mid-session
   opt-in produces a live integration immediately, not configured-but-dead.
8. **Confirmation summary** — wizard prints state without secrets.

After completion, `doey openclaw doctor` reports green; outbound notifications
flow through the OpenClaw branch in `send_notification`.

## Authentication — which token?

OpenClaw integration uses **two unrelated credentials**. Mixing them up is the
single most common setup error:

| Token | Where it lives | What it authenticates | Wizard prompts for it? |
|---|---|---|---|
| **OpenClaw gateway access token** | `~/.config/doey/openclaw.conf` (`gateway_token`) | Doey → OpenClaw daemon HTTP calls | **Yes** |
| **Anthropic / OpenAI / model API key** | OpenClaw's own config | OpenClaw → upstream LLM provider | **No** |

The `/doey-openclaw-connect` wizard prompts only for the **gateway access
token**. If you paste an Anthropic or OpenAI key into the wizard, calls into
the OpenClaw daemon will fail with auth errors and the daemon will not have
the model key it needs separately.

The wizard repeats this warning on the prompt and in the round-1 confirmation.
The doctor surfaces auth errors with a hint pointing back to this section.

## Binding schema (`.doey/openclaw-binding`)

Per-project binding written by the wizard. Worktree-local; not in
`~/.config/doey/`.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `channel_id` | string | required | Discord channel id this project routes through |
| `thread_strategy` | enum | `per-task` | `per-task` (one Discord thread per Doey task) or `flat` (all events in the channel) |
| `idempotency_namespace` | string | derived | Prefix for idempotency keys; defaults to `<project>:<sid>` |
| `bound_user_ids` | **list** | `[]` | Discord user ids permitted to send Boss inbound. **Empty list = any channel member.** Length ≥1 = strict allowlist. Empty-string entries (e.g. trailing comma producing `[""]`) are **rejected on parse** — they must NOT degrade to allow-all. |
| `legacy_discord_suppressed` | bool | `false` | Silence the legacy Discord forwarder chain when OpenClaw is configured |

The list type for `bound_user_ids` is fixed at v1 to avoid a v2 schema break.

## Privacy model

OpenClaw notifications inherit Doey's per-config privacy mode:

| `privacy_mode` | Behavior |
|---|---|
| `metadata_only` | Title, task id, event kind, role, duration. Body is suppressed. |
| `full` | Body included after redaction (per the redaction protocol below). |
| *(unset)* | **Default = `metadata_only`**. |

Default is `metadata_only` whenever the field is absent from `openclaw.conf`.
The privacy mode is read on each `send_notification` call; rotating it does
not require a restart.

## Trust model

The integration is opt-in and Boss-centric — only the Boss pane (`0.1`)
receives inbound prompts via the bridge. Workers and Subtaskmasters never
receive OpenClaw inbound.

Trust boundaries:

- **`bound_user_ids` is the v1 trust knob for shared channels.** Length 0 =
  any channel member (suitable for personal/single-user channels). Length ≥1
  = strict allowlist by Discord user id. Use the allowlist on any
  multi-user channel.
- **HMAC on inbound prompts.** Every prompt the bridge writes into Boss is
  signed `HMAC-SHA256(secret, body || 0x00 || ts_ascii)` and verified by
  `on-prompt-submit.sh`. Mismatched / stale signatures are rejected.
- **Per-message nonce framing.** Inbound text is wrapped in a per-message
  nonce delimiter pair so static-string forgery from inside the body is
  defeated.
- **Doey state MCP redaction (Phase 3b)** is best-effort. The MCP boundary
  redacts common secret patterns at every tool result, **but it is convenience
  telemetry, NOT a confidentiality boundary.** On shared or public channels,
  rely on `bound_user_ids` and channel-privacy, not on the redaction layer
  alone. This is the explicit framing in the v1 contract.

## HMAC secret rotation

The v1 rotation procedure is: **re-run `/doey-openclaw-connect`**.

Re-running the wizard:

- Generates a fresh `bridge_hmac_secret` from `/dev/urandom` and writes it
  atomically to `~/.config/doey/openclaw.conf`.
- Re-issues the gateway access token if the user pastes a new value.
- Restarts the bridge so the new secret takes effect immediately.

A no-prompt rotation flow ("rotate without re-entering the gateway URL or
token") is deferred to a v2 follow-up task — opened by Phase 4 of the
masterplan, intentionally out of v1 scope.

## Daemon-version policy

Daemon version compatibility is gated at three points, none of which is a
cron-style periodic check (Doey has no cron substrate):

1. **Connect-time smoke** — the wizard reads daemon version via
   `openclaw gateway status` and rejects below `OPENCLAW_MIN_VERSION`. If
   the daemon was unreachable at connect time, the smoke is deferred to
   first reconnect.
2. **Per-reconnect smoke** — on every successful bridge reconnect, the
   bridge re-reads the daemon version. Drift outside the known-good range
   surfaces a dashboard warning and opens a v1.x followup task (with
   fingerprint de-dupe so a single drift doesn't open the same task
   repeatedly).
3. **Session-start-tick doctor recheck** — `doey doctor` runs the same
   check on session start when the binding is present. There is no
   periodic background re-check; long-running sessions can talk to a
   silently-upgraded daemon between session starts and reconnects, but the
   per-reconnect smoke covers the realistic drift window.

Long sessions that survive a daemon upgrade without a reconnect are the
edge case. If a periodic-tick re-check is added later, it will be a v1.x
followup; v1 ships with the three checks above only.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `doey openclaw status` says "not configured" | wizard never run, or both files missing | Run `/doey-openclaw-connect` |
| **"configured but bridge not running"** (loud doctor warning) | binding files exist but PID file is dead | `doey openclaw bridge-spawn` (idempotent); check daemon is up |
| HTTP 401 on outbound | wrong token (model API key pasted instead of gateway access token) | Re-run wizard; see "Authentication — which token?" |
| Outbound silently no-ops | `~/.config/doey/openclaw.conf` missing — fast-path guard fired | Run wizard, or accept fresh-install state |
| `chmod 600 required` warning | `openclaw.conf` is world-readable | `chmod 600 ~/.config/doey/openclaw.conf` |
| Daemon-version mismatch on reconnect | upstream OpenClaw upgraded outside known-good range | Update Doey, or pin daemon version; re-check `OPENCLAW_MIN_VERSION` in helper |
| Inbound replies arrive out of thread or stale | correlation_id rules — see Phase 2 of masterplan | Reply in the task thread; if 2+ open, use Discord reply-chain reference |
| Two sessions, double inbound | per-project lockfile race | Check `/tmp/doey/<project>/openclaw-bridge.pid`; second invocation refuses |
| HMAC rejection in logs | bridge ↔ Boss clock drift > 60s, or token rotation mid-flight | Sync clocks; re-run wizard |

`doey openclaw doctor` runs the full health check and surfaces the same
hints. `doey openclaw doctor --fix` re-runs idempotent setup steps
(bridge-spawn, MCP register if Phase 3b shipped). With **no config**, the
`--fix` flag is a no-op-with-message: it prints "OpenClaw not configured;
run `/doey-openclaw-connect` first" and exits clean. Never auto-invokes the
interactive wizard.

## Redaction protocol

The OpenClaw helper wraps `curl` to enforce a hard invariant: **auth headers
never appear in any log, debug output, or `set -x` trace.**

Helper invariants:

- The helper sources a redacted curl wrapper. The wrapper writes
  `Authorization` headers from a tmp file fd-passed to `curl`, never on
  argv, never via `--header "Authorization: Bearer ..."` in argv-visible
  form.
- `set -x` and `curl -v` are both gated: enabling either does **not** print
  the auth header. A unit test in `tests/openclaw-redact.sh` runs the
  helper with `set -x` and greps the trace for the live token; the test
  fails if the token appears.
- Errors from `curl` are rewritten to drop the `Authorization` line before
  surfacing in any user-visible context.

The Doey state MCP server (Phase 3b) ships its own redaction layer at the
tool-result boundary, with regex patterns for `Authorization`, `Bearer`,
`token=`, `sk-…`, `gh[pousa]_…`, `bridge_hmac_secret`, `gateway_token`,
`xoxb-`, `xoxa-`. These two layers are independent: helper redaction
protects outbound; MCP redaction protects state-server reads.

## Version compatibility

OpenClaw daemon compatibility is pinned by `OPENCLAW_MIN_VERSION`, defined in
the helper. The minimum is set conservatively to the version verified during
the masterplan spike. The wizard rejects daemon versions below the minimum.

| Doey version | `OPENCLAW_MIN_VERSION` (pinned) | Known-good daemon range |
|---|---|---|
| v1 (this release) | (set by helper at ship time) | (filled by spike outcome) |

The helper's `OPENCLAW_MIN_VERSION` value is the authoritative pin; this table
is documentation, not config. To override (e.g. for testing), set the env var
of the same name before running the wizard.

## `legacy_discord_suppressed=true` failure semantics

When `legacy_discord_suppressed=false` (the safe default): the OpenClaw branch
attempts every notification first; on failure, falls back to the legacy
Discord forwarder chain (and ultimately to desktop-only). Falls back on **any
of the three trigger conditions**:

1. **Transport error** — connection refused, DNS failure, timeout, TCP reset,
   TLS handshake failure, or any error before an HTTP response is parsed.
2. **HTTP non-2xx** — any 4xx/5xx response from the gateway.
3. **HTTP 2xx with channel-write-rejected error in body** — the gateway
   accepted the request but the downstream channel adapter (Discord) rejected
   the write. The helper inspects the response body for the gateway's
   documented error shape and treats this as a failed send.

Any of these three triggers a fallback to the existing chain.

When `legacy_discord_suppressed=true`: the OpenClaw branch is the **only**
notification path. If the daemon is unreachable, **you receive ZERO
notifications — total silent loss**. No desktop notification, no legacy
Discord webhook, nothing. This is an explicit user-accepted risk, surfaced by
the wizard at opt-in time and restated in the wizard summary on enable.

The default of `false` is defensive. Enable suppression only when you know
the gateway is highly available and you actively want to deduplicate the
notification surface.

## Fresh-install invariant

A user who has never run `/doey-openclaw-connect` sees:

- **No artifacts on disk.** No `~/.config/doey/openclaw.conf`, no
  `<project>/.doey/openclaw-binding`, no `/tmp/doey/<project>/openclaw-*`.
- **No behavior change.** `send_notification` is byte-identical pre- and
  post-OpenClaw-install when not configured. This is asserted by
  `tests/openclaw-fresh-install.sh` as a PR-gating CI test, including a
  before-vs-after byte-equality regression assertion on legacy Discord and
  desktop output.
- **No network calls.** The fast-path guard at the top of the
  OpenClaw branch in `send_notification` is `[ -f
  "$HOME/.config/doey/openclaw.conf" ] || { existing_chain "$@"; return; }`
  — first executable line. The stat is the only OpenClaw code path
  executed in non-opt-in state. No daemon probe, no HTTP, no DNS, no
  background daemon spawn.
- **No daemon spawn.** The bridge daemon is spawned only when
  `<project>/.doey/openclaw-binding` exists at session start (or by the
  wizard end-step). Without binding, no Go bridge runs.
- **`stop-status.sh` `boss-idle` write** is gated behind
  `[ -f .doey/openclaw-binding ]` (parallel to the fast-path guard) — no
  IDLE-edge signal file is created in non-opt-in state.

The invariant is non-negotiable. Any change that touches the OpenClaw
integration must keep `tests/openclaw-fresh-install.sh` green.
