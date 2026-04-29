package main

import (
	"regexp"
)

// Redaction is a best-effort, pattern-based filter applied to the JSON-RPC
// byte stream just before it leaves the process. It is "convenience
// telemetry, NOT a confidentiality boundary" — see README.md.
//
// Order matters. We deliberately match the most specific / longest patterns
// first so that, e.g., "Authorization: Bearer ghp_…" is captured by the
// header pattern before either the generic `bearer …` or the generic
// `gh[pousa]_…` rule has a chance to leave a partial fragment behind.

const redactedMark = "[redacted]"

// redactionPattern pairs a regex with its replacement. Replacements use
// Go's regex `$0`, `$1`-style backrefs to keep the human-readable label
// (e.g. "token=") intact while wiping the value.
type redactionPattern struct {
	name string
	re   *regexp.Regexp
	repl string
}

// minBearerLen is the lower bound on a bearer-token body before we treat
// the match as a secret. The spec example included single-word negatives
// like "bearer of the news"; without a length floor a naïve pattern would
// gleefully redact "bearer of". Real bearer tokens are JWTs, opaque blobs,
// or hex/base64 strings far longer than common English words.
const minBearerLen = 16

var redactionPatterns = []redactionPattern{
	// 1. HTTP Authorization header — must run before generic `bearer …`
	//    so we don't double-redact the value half. We deliberately swallow
	//    the rest of the line so a "Bearer <token>" credential is captured
	//    in one shot rather than leaving the token half unredacted.
	{
		name: "authorization_header",
		re:   regexp.MustCompile(`(?i)(Authorization\s*:\s*)[^\r\n"\\]+`),
		repl: "${1}" + redactedMark,
	},
	// 2. Anthropic/OpenAI-style keys — `sk-` prefix + 20+ token chars.
	//    Specific prefix runs before the generic token= rule.
	{
		name: "sk_key",
		re:   regexp.MustCompile(`sk-[A-Za-z0-9_\-]{20,}`),
		repl: redactedMark,
	},
	// 3. GitHub tokens — ghp_/gho_/ghu_/ghs_/ghr_/gha_ prefixes.
	{
		name: "github_token",
		re:   regexp.MustCompile(`gh[pousar]_[A-Za-z0-9]{20,}`),
		repl: redactedMark,
	},
	// 4. Slack bot tokens.
	{
		name: "slack_xoxb",
		re:   regexp.MustCompile(`xoxb-[A-Za-z0-9\-]+`),
		repl: redactedMark,
	},
	// 5. Slack legacy admin tokens.
	{
		name: "slack_xoxa",
		re:   regexp.MustCompile(`xoxa-[A-Za-z0-9\-]+`),
		repl: redactedMark,
	},
	// 6. bridge_hmac_secret — Doey-specific known-bad leak target. The
	//    `["']?` between the key and the colon handles JSON forms like
	//    `"bridge_hmac_secret": "value"`. Group 2 captures the optional
	//    opening quote of the value so JSON syntax is preserved.
	{
		name: "bridge_hmac_secret",
		re:   regexp.MustCompile(`(?i)(bridge_hmac_secret["']?\s*[:=]\s*)(["']?)[^"'\s,}\]\r\n\\]+(["']?)`),
		repl: "${1}${2}" + redactedMark + "${3}",
	},
	// 7. gateway_token — Doey/OpenClaw bridge auth.
	{
		name: "gateway_token",
		re:   regexp.MustCompile(`(?i)(gateway_token["']?\s*[:=]\s*)(["']?)[^"'\s,}\]\r\n\\]+(["']?)`),
		repl: "${1}${2}" + redactedMark + "${3}",
	},
	// 8. Generic `token = value` / `token: value`. Conservative: requires
	//    a labeled assignment so the prose word "token" stays intact.
	{
		name: "generic_token_assignment",
		re:   regexp.MustCompile(`(?i)(\btoken["']?\s*[:=]\s*)(["']?)[A-Za-z0-9._\-+/]+={0,2}(["']?)`),
		repl: "${1}${2}" + redactedMark + "${3}",
	},
	// 9. Standalone `bearer <token>` — runs LAST so the Authorization
	//    header has already swallowed any "Authorization: bearer …" form.
	//    minBearerLen guards against the prose word "bearer" followed by
	//    a short English word.
	{
		name: "bearer_token",
		re:   regexp.MustCompile(`(?i)(\bbearer\s+)[A-Za-z0-9._\-+/]{16,}={0,2}`),
		repl: "${1}" + redactedMark,
	},
}

// Redact applies every redactionPattern in order to s and returns the
// resulting string. Safe to call on already-redacted strings.
func Redact(s string) string {
	for _, p := range redactionPatterns {
		s = p.re.ReplaceAllString(s, p.repl)
	}
	return s
}

// RedactBytes is the byte-level convenience used by the JSON-RPC writer
// to scrub the marshaled response before it hits stdout.
func RedactBytes(b []byte) []byte {
	for _, p := range redactionPatterns {
		b = p.re.ReplaceAll(b, []byte(p.repl))
	}
	return b
}

// _ = minBearerLen documents the bearer-token length floor inline at the
// regex above so a future tuner sees it next to the pattern.
var _ = minBearerLen
