# OpenClaw Bridge ↔ Gateway Protocol (v1)

This document is the contract between the Doey-side bridge sidecar
(`openclaw-bridge`) and the OpenClaw gateway. The bridge is the only
party in the Doey runtime that talks HTTP — all downstream consumers
read events from the local file queue at
`/tmp/doey/<project>/inbound-queue.jsonl`.

## Transport

- **Base URL**: `gateway_url` from `.doey/openclaw.conf`
- **Auth**: `Authorization: Bearer <gateway_token>` on every request
- **Content-Type**: `application/json` for both request and response bodies
- **TLS**: required in production. Plain `http://` allowed only for
  loopback gateway test instances.

## Endpoints

### `POST /v1/events_wait` (long-poll)

Long-polling endpoint the bridge holds open until events arrive or the
server times out. The bridge reconnects immediately on a clean empty
return.

Request:
```json
{
  "since": "<cursor opaque string, may be empty>",
  "timeout_ms": 25000,
  "channel": "claude"
}
```

Response (200):
```json
{
  "events": [ <Event>, ... ],
  "cursor": "<next opaque cursor>"
}
```

Empty long-poll returns `events: []` with the cursor unchanged. The
bridge must persist the returned cursor before processing events.

### `GET /v1/messages_read?since=<cursor>&limit=100&channel=claude`

Cursor-based replay endpoint used after a crash to drain anything the
gateway buffered while the bridge was offline. Same response shape as
`events_wait`.

### `POST /v1/notifications/claude/channel`

Reverse path used by other workers (out of scope for the bridge sidecar
itself; documented here for completeness so the gateway team knows the
allocated path). The bridge does not call this endpoint.

## Per-event payload (gateway → bridge)

Each event returned by `events_wait` / `messages_read`:

```json
{
  "id":        "string  — unique per event, gateway-assigned",
  "sender_id": "string  — opaque user id from gateway",
  "body":      "string  — UTF-8 plaintext, redaction is the gateway's job",
  "ts":        1234567890,
  "hmac":      "hex64   — HMAC-SHA256(body || 0x00 || ts_decimal_ascii) keyed by bridge_hmac_secret"
}
```

The bridge passes `body`, `ts`, and `hmac` to the `Verifier` interface
(`HMACVerifier` from `hmac.go`). Events failing the HMAC check (or
exceeding the configured timestamp skew window) are dropped with a
stderr log and never reach the queue file.

### Nonce ownership

The gateway does **not** supply a nonce. Nonces are issued **locally**
by the bridge (`GenerateNonce` in `nonce.go`) at the moment of queue
append, recorded in the rotating nonce ledger
(`/tmp/doey/<project>/openclaw-nonces.jsonl`), and used to frame the
body for downstream consumers via `WrapBody`:

```
BEGIN nonce=<hex16>
<body>
END nonce=<hex16>
```

Replay protection lives at the bridge → consumer boundary, not the
gateway → bridge boundary (the HMAC + timestamp skew window covers the
gateway hop).

## Failure modes

| HTTP status / condition | Bridge action |
|-------------------------|---------------|
| `200`                   | Process events, reset backoff, persist cursor |
| `204` / empty events    | Reset backoff, immediate reconnect |
| `401 Unauthorized`      | Token rotated. Stop reconnecting until config is reloaded; write stuck dashboard with `reason="auth_failed"`. Backoff at max (30s) while polling for config change. |
| `403 Forbidden`         | Treat like 401. |
| `429 Too Many Requests` | Honor `Retry-After` header if present, else exponential backoff |
| `5xx`                   | Exponential backoff + retry |
| Network error / timeout | Exponential backoff + retry |
| HMAC verify fail        | Drop event, log to stderr, continue (do not advance cursor past it) |
| Nonce reuse             | Drop event, log to stderr, continue |

Backoff schedule: `1s → 2s → 4s → 8s → 16s → 30s`, capped at 30s. Reset
to 1s on any successful 2xx response. After **3 consecutive failures**
the bridge writes `/tmp/doey/<project>/openclaw-bridge.stuck.json` so
the user dashboard can surface the outage. The file is removed on the
first successful poll.

## Replay caps (post-reconnect)

The first non-empty events_wait response after the bridge starts is
treated as a replay batch. Two caps apply, in order:

1. **Window cap.** Drop events with `ts < now() - 1h`.
2. **Count cap.** Keep at most the 50 most-recent survivors.

Both skips are logged as `replay truncated: skipped N older events, M
over-cap (kept K, last_seen_id=… last_seen_ts=…)`. The caps activate
only when `openclaw-cursor` exists at startup (i.e. the bridge has
prior drain state). On a fresh install or after the file is deleted,
no caps are applied — the bridge accepts whatever the gateway returns.
Subsequent batches in steady state are never capped.

Permissive 1-open correlation is enforced downstream by the consumer
(`oc_thread_get_or_create` in `shell/doey-openclaw.sh`); replayed
events flow through the queue file unchanged and inherit dedup at
thread-creation time.

## Cursor semantics

- Opaque to the bridge — never parsed, only stored
- Persisted to `/tmp/doey/<project>/inbound-cursor` after each successful
  poll, before the events are appended to the queue
- Empty string on first ever start (gateway returns full backlog up to
  its own retention window)

## Local file outputs

| Path | Writer | Format |
|------|--------|--------|
| `/tmp/doey/<project>/inbound-queue.jsonl` | bridge | one verified Event per line, JSON |
| `/tmp/doey/<project>/inbound-cursor`      | bridge | opaque gateway cursor string, no newline |
| `/tmp/doey/<project>/openclaw-cursor`     | bridge | single-line JSON `{"last_event_id","last_event_ts_unix"}` — last successfully drained event; bounds replay batches after reconnect (50 events / 1h window). Missing/malformed → graceful degrade to no-replay. |
| `/tmp/doey/<project>/openclaw-bridge.pid` | bridge | decimal PID |
| `/tmp/doey/<project>/openclaw-bridge.lock` | bridge | flock-only, contents irrelevant |
| `/tmp/doey/<project>/openclaw-bridge.stuck.json` | bridge | dashboard hint, see dashboard.go |
| `/tmp/doey/<project>/boss-idle`           | stop-status.sh | edge-trigger only — empty content |

## Go types (defined in queue.go, owned by W4.2 framing layer)

```go
// Event is the canonical inbound event shape used across the package.
type Event struct {
    ID       string `json:"id"`
    SenderID string `json:"sender_id"`
    Body     string `json:"body"`
    Ts       int64  `json:"ts"`
    HMAC     string `json:"hmac"`
    Nonce    string `json:"nonce"` // populated by bridge before queue append
}

// Verifier is the inbound message verifier interface.
// HMACVerifier (hmac.go) implements this.
type Verifier interface {
    Verify(body string, ts int64, hmacHex string) error
}
```

Pipeline (see `Drain` in `queue.go`):

1. `Poller.Run` long-polls the gateway and pushes raw `Event`s on a
   channel.
2. `Drain` consumes the channel, calls `Verifier.Verify`, generates a
   fresh nonce via `GenerateNonce`, calls `QueueWriter.RememberNonce`,
   then `QueueWriter.Append` to write the framed JSONL row to the
   inbound queue.
3. Events that fail verification or fail to obtain a nonce are dropped
   and logged to stderr.
