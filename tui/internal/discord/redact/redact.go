// Package redact scrubs known secret patterns from strings before they
// reach logs, stdout, Discord messages, or persisted state files.
//
// The package is intentionally self-contained: stdlib only, no imports
// from other tui/internal/* packages. Redaction is idempotent — the
// Placeholder token contains no characters that match any pattern, so
// Redact(Redact(x)) == Redact(x).
//
// The pattern set is non-exhaustive. Prefer over-redaction: false
// positives are cheap, leaked secrets are expensive. See ADR-8.
package redact

import "regexp"

// Placeholder is the fixed replacement token written in place of every
// matched secret. It is chosen so that no pattern in this package can
// match it, preserving idempotency.
const Placeholder = "[REDACTED]"

// patterns is the ordered slice of compiled redaction regexes. Order
// matters: more specific patterns must run before the generic long
// base64 fallback, otherwise a specific secret would be double-matched
// (harmless for correctness but wasteful).
var patterns = []*regexp.Regexp{
	regexp.MustCompile(`sk-ant-api03-[A-Za-z0-9_-]+`),
	regexp.MustCompile(`sk-[A-Za-z0-9]{20,}`),
	regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{36,}`),
	regexp.MustCompile(`xox[abp]-[A-Za-z0-9-]{10,}`),
	regexp.MustCompile(`AKIA[0-9A-Z]{16}`),
	regexp.MustCompile(`sk_live_[A-Za-z0-9]{24,}`),
	regexp.MustCompile(`https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+`),
	regexp.MustCompile(`(?i)Authorization:\s*Bearer\s+\S+`),
	regexp.MustCompile(`-----BEGIN [A-Z ]+PRIVATE KEY-----`),
	regexp.MustCompile(`(?i)password\s*[:=]\s*\S+`),
	regexp.MustCompile(`(?i)secret\s*[:=]\s*\S+`),
	regexp.MustCompile(`[A-Za-z0-9+/]{48,}=?=?`),
}

// Redact returns a copy of s with every occurrence of a known secret
// pattern replaced by Placeholder. Safe to call repeatedly on the same
// input (idempotent).
func Redact(s string) string {
	for _, p := range patterns {
		s = p.ReplaceAllString(s, Placeholder)
	}
	return s
}

// RedactBytes is the []byte equivalent of Redact.
func RedactBytes(b []byte) []byte {
	for _, p := range patterns {
		b = p.ReplaceAll(b, []byte(Placeholder))
	}
	return b
}

// LastFour returns "…" followed by the last 4 characters of s, suitable
// for display fields (e.g. the bind wizard's echo). Inputs shorter than
// 4 characters are returned verbatim after the ellipsis. The zero value
// renders as "…____" so the UI never shows a bare ellipsis.
func LastFour(s string) string {
	if s == "" {
		return "…____"
	}
	if len(s) <= 4 {
		return "…" + s
	}
	return "…" + s[len(s)-4:]
}

// Patterns returns a fresh copy of the compiled pattern slice for test
// introspection. Callers must not rely on the ordering for behavior —
// use Redact for actual redaction.
func Patterns() []*regexp.Regexp {
	out := make([]*regexp.Regexp, len(patterns))
	copy(out, patterns)
	return out
}
