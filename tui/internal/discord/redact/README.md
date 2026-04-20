# redact

Redacts known secret patterns from strings before they reach logs,
stdout, Discord messages, or state files.

## Purpose

A single chokepoint for secret scrubbing across the Discord integration.
Any string that originates from user input, process output, subprocess
stderr, or third-party API errors MUST pass through `Redact` before it
is rendered to a human-visible surface or persisted to disk.

Prefer over-redaction. False positives are cheap — a visible
`[REDACTED]` token is a minor UX blemish. A leaked API key is a
credential rotation, a post-mortem, and potentially a bill.

## Surfaces (ADR-8)

The following eight surfaces funnel through this package:

1. Discord message bodies (outbound posts)
2. Bind wizard echo output (last-four display uses `LastFour`)
3. Structured error logs written to disk
4. Stdout/stderr proxied into Discord threads
5. Notification payloads (desktop + Discord)
6. Task result JSON written to `/tmp/doey/<project>/results/`
7. Taskmaster status and activity files
8. Crash-dump tails captured by the stop hooks

## Patterns

Non-exhaustive. Add new patterns as they are discovered. Order matters:
specific patterns run first, the generic long-base64 fallback runs last.

| Pattern                                                      | Description                                  |
| ------------------------------------------------------------ | -------------------------------------------- |
| `sk-ant-api03-[A-Za-z0-9_-]+`                                | Anthropic API key                            |
| `sk-[A-Za-z0-9]{20,}`                                        | OpenAI API key                               |
| `gh[pousr]_[A-Za-z0-9]{36,}`                                 | GitHub PAT / OAuth / user / server / refresh |
| `xox[abp]-[A-Za-z0-9-]{10,}`                                 | Slack token                                  |
| `AKIA[0-9A-Z]{16}`                                           | AWS access key id                            |
| `sk_live_[A-Za-z0-9]{24,}`                                   | Stripe live secret key                       |
| `https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+` | Discord webhook URL (critical for error logs) |
| `(?i)Authorization:\s*Bearer\s+\S+`                          | HTTP bearer header                           |
| `-----BEGIN [A-Z ]+PRIVATE KEY-----`                         | PEM private key header                       |
| `(?i)password\s*[:=]\s*\S+`                                  | `password=` / `password:` assignment         |
| `(?i)secret\s*[:=]\s*\S+`                                    | `secret=` / `secret:` assignment             |
| `[A-Za-z0-9+/]{48,}=?=?`                                     | Long base64 blob (fallback, runs last)       |

## API

```go
redact.Redact(s string) string          // run all patterns
redact.RedactBytes(b []byte) []byte     // same, for bytes
redact.LastFour(s string) string        // "…" + last 4 chars for UI
redact.Patterns() []*regexp.Regexp      // test introspection only
redact.Placeholder                      // "[REDACTED]" const
```

## Idempotency

`Redact(Redact(x)) == Redact(x)` for every input `x`. The replacement
token `[REDACTED]` is chosen so no pattern in this package matches any
of its characters in isolation. This lets callers redact defensively
without worrying about double-application.

## Example

```go
msg := "request failed with Authorization: [REDACTED]"
// already redacted; Redact(msg) returns msg unchanged.
```

No literal secrets appear in this README or in the test suite. All
fixtures are synthetic. Do not paste real keys into tests — the
secret-scanner has fired on this repo before.
