---
name: doey-openclaw-connect
description: OpenClaw integration wizard — bind this Doey project to an OpenClaw gateway for multi-channel notifications and Boss inbound. Use when the user says "connect openclaw", "set up openclaw", "bind openclaw to discord", or invokes /doey-openclaw-connect. Runs in Boss; gathers gateway URL + token + channel binding, delegates filesystem writes to `shell/doey-openclaw.sh connect`, ends with idempotent bridge spawn.
---

Run an inline opt-in wizard that connects this Doey project to a self-hosted OpenClaw gateway (`localhost:18789` by default). Notifications and Boss inbound will route through OpenClaw's multi-channel surface (Discord in v1). The skill stays in the Boss pane; all filesystem writes are delegated to the host shell helper `shell/doey-openclaw.sh connect`. The helper handles atomic temp+fsync+rename writes, mid-wizard rollback, idempotent bridge-spawn, and version pinning.

Fresh-install invariant: users who never run this skill see zero behavior change, zero artifacts, zero network calls. The fast-path stat at the top of `send_notification` is the only OpenClaw code path executed in non-opt-in state.

### When to use

- User asks to "connect openclaw", "wire up openclaw", or "use openclaw for notifications".
- User wants Discord round-trip (Boss → channel → reply → Boss prompt) via the OpenClaw gateway.
- User wants to rotate the HMAC bridge secret — re-running the wizard regenerates `bridge_hmac_secret`.

Skip the wizard and do nothing if the user is asking *about* OpenClaw (docs question) — point them at `docs/openclaw-integration.md` instead.

### The 8-step flow

The agent executes these steps in order. Use `AskUserQuestion` for every user prompt — never inline questions in chat text.

1. **Pre-check Node.js ≥ 22.14** — run `node --version`. If missing or older, surface a one-line warning ("OpenClaw requires Node.js ≥ 22.14; daemon may not start") and continue. Warn-not-fail.
2. **Pre-check daemon liveness** — run `openclaw gateway status`. If the binary is missing or the gateway is down, surface a one-line warning ("OpenClaw gateway not reachable; you can still configure — bridge will start when the daemon is up") and continue. Warn-not-fail.
3. **Prompt for gateway URL and gateway access token** (single batched `AskUserQuestion` call):
    - `gateway_url` — default `http://localhost:18789`.
    - `gateway_token` — the OpenClaw gateway access token.
    - **CRITICAL copy in the prompt and again in a follow-up confirmation:**

      > This is your **OpenClaw gateway access token**, NOT your Anthropic / OpenAI / model API key. The gateway token authenticates Doey's HTTP calls into the OpenClaw gateway daemon at `localhost:18789`. It is unrelated to whatever model key OpenClaw itself uses.

      Repeat the warning. Pasting an Anthropic/OpenAI key here is the single most common setup error.
4. **Auto-generate `bridge_hmac_secret`** — the wizard never prompts for it. The helper generates 32 bytes from `/dev/urandom` and writes the hex into `~/.config/doey/openclaw.conf`.
5. **Smoke version-pin** — record the daemon version reported by `openclaw gateway status` and reject below `OPENCLAW_MIN_VERSION` (the helper enforces; env-overridable). On reject, the wizard surfaces the version mismatch and aborts cleanly — no files written. If the daemon was unreachable at pre-flight, defer the smoke to first reconnect.
6. **Prompt for binding** (single batched `AskUserQuestion` call):
    - `channel_id` — required, free-text.
    - `thread_strategy` — default `per-task`. Choices: `per-task`, `flat`.
    - `bound_user_ids` — optional comma-separated list of Discord user ids permitted to send Boss inbound. Empty list = any channel member; length ≥1 = strict allowlist. **Empty-string entries (e.g. trailing comma producing `[""]`) are rejected on parse — they must NOT degrade to allow-all.**
    - `legacy_discord_suppressed` — bool, default `false`. When `true`, the legacy Discord forwarder chain is silenced; only OpenClaw fires.

    When the user opts in to `legacy_discord_suppressed=true`, surface this warning **explicitly in a follow-up confirmation** before continuing:

    > If `legacy_discord_suppressed=true` AND the OpenClaw daemon is unreachable, you will receive **ZERO notifications — total silent loss**. This is an explicit user-accepted risk. Confirm to proceed.
7. **Delegate filesystem writes** to the host shell helper:

    ```sh
    bash $HOME/.local/bin/doey-openclaw connect \
      --gateway-url <url> \
      --gateway-token-file <fd-or-stdin-path> \
      --channel-id <id> \
      --thread-strategy <per-task|flat> \
      --bound-user-ids <comma_list_or_empty> \
      --legacy-discord-suppressed <true|false>
    ```

    The token is passed via stdin or a `--*-file` arg, **never on argv** (matches the Discord helper convention; `ps` snapshots on multi-tenant hosts must not see the token). The helper:
    1. Generates `bridge_hmac_secret` from `/dev/urandom`.
    2. Atomically writes `~/.config/doey/openclaw.conf` (mode `0600`) — temp file, fsync, rename.
    3. Atomically writes `<project>/.doey/openclaw-binding`.
    4. Re-runs the daemon-version smoke (if daemon reachable) and rejects below `OPENCLAW_MIN_VERSION`.
    5. Calls `doey openclaw bridge-spawn` (idempotent: no-op if PID file is alive). Until the Phase 2 bridge binary lands, this step logs "bridge will start on next session" and exits green.

    **Rollback contract (helper invariant):** if the helper fails after writing `openclaw.conf` but before `<project>/.doey/openclaw-binding` lands, it deletes `openclaw.conf` so no half-config remains on disk. **Never leave half-config.** If both files wrote successfully but bridge-spawn fails, both files persist (configured-but-dead state) and the helper surfaces a loud "configured but bridge not running" warning that `doey openclaw doctor` will reproduce.
8. **Confirmation summary** — print resulting state. **Never print secrets** — no `gateway_token`, no `bridge_hmac_secret`, no full URL with embedded credentials.

    ```
    **OpenClaw connected.**
    Gateway: http://localhost:18789
    Channel: <channel_id>
    Thread strategy: per-task
    Bound user ids: <count> (any-channel-member if 0)
    Legacy Discord suppressed: false
    Bridge: running (pid=<n>)   |   queued for next session
    Daemon version: <version>   |   deferred (daemon was unreachable)
    Config: ~/.config/doey/openclaw.conf (0600), .doey/openclaw-binding
    ```

    If `legacy_discord_suppressed=true`, restate the silent-loss warning in the summary.

### Rules

- All user prompts MUST go through `AskUserQuestion`. Never put questions inline in chat text.
- The token CRITICAL copy ("gateway access token, NOT model API key") MUST appear in step 3 and MUST be repeated in the round-3 confirmation.
- The wizard never writes config files itself — every filesystem write goes through `bash $HOME/.local/bin/doey-openclaw connect`.
- Never print or echo `gateway_token` / `bridge_hmac_secret` / full webhook-style URLs.
- Never invoke `doey openclaw doctor --fix` from the wizard with no prior config — that is a no-op-with-message path, not the wizard's job.
- The skill produces no Co-Authored-By trailers, makes no git commits, and never edits files outside `~/.config/doey/openclaw.conf` and `<project>/.doey/openclaw-binding` (both via the helper).
- On any helper non-zero exit, surface stderr verbatim (helper redacts secrets in its own logs) and stop.
