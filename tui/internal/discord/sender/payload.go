package sender

import "unicode/utf8"

// Payload size caps per ADR (masterplan lines 205-206 and 252).
const (
	MaxContentBytes     = 1990
	MaxEmbedTitle       = 256
	MaxEmbedDescription = 4096
	MaxEmbedFieldValue  = 1024
	MaxEmbedTotal       = 6000
	TruncationSuffix    = "… (truncated)"
)

// TruncateContent clamps s to MaxContentBytes, breaking on a UTF-8 rune
// boundary and appending TruncationSuffix when truncation occurred.
func TruncateContent(s string) string {
	out, _ := TruncateOnRuneBoundary(s, MaxContentBytes)
	return out
}

// TruncateOnRuneBoundary clamps s so len(out) <= maxBytes, breaking on a
// rune boundary. If s already fits, returns (s, false). Otherwise returns
// (prefix+TruncationSuffix, true) where prefix is the largest valid-UTF-8
// prefix of s whose bytes plus the suffix fit within maxBytes.
func TruncateOnRuneBoundary(s string, maxBytes int) (string, bool) {
	if maxBytes <= 0 {
		return "", len(s) > 0
	}
	if len(s) <= maxBytes {
		return s, false
	}

	budget := maxBytes - len(TruncationSuffix)
	if budget <= 0 {
		// Suffix alone exceeds maxBytes: return as many bytes of suffix as fit.
		return TruncationSuffix[:maxBytes], true
	}

	offset := 0
	for offset < len(s) {
		_, size := utf8.DecodeRuneInString(s[offset:])
		if offset+size > budget {
			break
		}
		offset += size
	}
	return s[:offset] + TruncationSuffix, true
}
