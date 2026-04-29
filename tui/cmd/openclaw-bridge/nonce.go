package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

var (
	ErrNonceMismatch = errors.New("nonce mismatch between BEGIN and END markers")
	ErrFramingEmpty  = errors.New("framed body is empty")
	ErrFramingFormat = errors.New("framed body malformed")
	ErrNonceFormat   = errors.New("nonce is not 16 lowercase hex chars")
)

const (
	beginPrefix = "BEGIN nonce="
	endPrefix   = "END nonce="
	nonceHexLen = 16
)

// GenerateNonce returns 8 random bytes encoded as 16 lowercase hex chars.
func GenerateNonce() (string, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("crypto/rand: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// WrapBody returns:
//
//	BEGIN nonce=<hex16>\n<body>\nEND nonce=<hex16>
//
// LF only. Newlines within body are preserved as-is.
func WrapBody(nonce, body string) string {
	var sb strings.Builder
	sb.WriteString(beginPrefix)
	sb.WriteString(nonce)
	sb.WriteByte('\n')
	sb.WriteString(body)
	sb.WriteByte('\n')
	sb.WriteString(endPrefix)
	sb.WriteString(nonce)
	return sb.String()
}

// ParseFramed extracts (nonce, body) from a framed message. The body may contain
// newlines. Mismatched BEGIN/END nonces return ErrNonceMismatch. Anything else
// returns ErrFramingFormat or ErrNonceFormat.
func ParseFramed(framed string) (string, string, error) {
	if framed == "" {
		return "", "", ErrFramingEmpty
	}
	// First line must be "BEGIN nonce=<hex16>".
	nl := strings.IndexByte(framed, '\n')
	if nl < 0 {
		return "", "", fmt.Errorf("%w: missing newline after BEGIN", ErrFramingFormat)
	}
	first := framed[:nl]
	if !strings.HasPrefix(first, beginPrefix) {
		return "", "", fmt.Errorf("%w: missing BEGIN marker", ErrFramingFormat)
	}
	beginNonce := first[len(beginPrefix):]
	if !validNonce(beginNonce) {
		return "", "", fmt.Errorf("%w: bad BEGIN nonce", ErrNonceFormat)
	}

	rest := framed[nl+1:]
	// Find the LAST occurrence of "\nEND nonce=" so body may contain "END nonce="
	// substrings of its own; the END marker must be on its own trailing line.
	sep := "\n" + endPrefix
	idx := strings.LastIndex(rest, sep)
	if idx < 0 {
		return "", "", fmt.Errorf("%w: missing END marker", ErrFramingFormat)
	}
	body := rest[:idx]
	endNonce := rest[idx+len(sep):]
	// END line must not contain extra content (no trailing newlines, etc.).
	if strings.ContainsRune(endNonce, '\n') {
		return "", "", fmt.Errorf("%w: trailing data after END marker", ErrFramingFormat)
	}
	if !validNonce(endNonce) {
		return "", "", fmt.Errorf("%w: bad END nonce", ErrNonceFormat)
	}
	if beginNonce != endNonce {
		return "", "", ErrNonceMismatch
	}
	return beginNonce, body, nil
}

func validNonce(s string) bool {
	if len(s) != nonceHexLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
		case c >= 'a' && c <= 'f':
		default:
			return false
		}
	}
	return true
}
