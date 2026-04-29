package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"time"
)

var (
	ErrHMACMismatch         = errors.New("hmac mismatch")
	ErrTimestampSkew        = errors.New("timestamp skew exceeds window")
	ErrSecretNotConfigured  = errors.New("hmac secret not configured")
	ErrInvalidHMACEncoding  = errors.New("invalid hmac hex encoding")
)

// HMACVerifier implements canonicalized HMAC-SHA256 verification.
//
// Canonicalization (byte sequence fed into HMAC):
//
//	mac = HMAC-SHA256(secret_bytes, body_bytes || 0x00 || ts_ascii_bytes)
//
// where ts_ascii_bytes is strconv.FormatInt(ts, 10) (decimal ASCII, no padding).
type HMACVerifier struct {
	secret []byte
	window time.Duration
	now    func() time.Time
}

// NewHMACVerifier parses a hex-encoded secret and returns a verifier with the given
// acceptable timestamp window. window<=0 defaults to 60s.
func NewHMACVerifier(secretHex string, window time.Duration) (*HMACVerifier, error) {
	if secretHex == "" {
		return nil, ErrSecretNotConfigured
	}
	secret, err := hex.DecodeString(secretHex)
	if err != nil {
		return nil, fmt.Errorf("decoding hmac secret: %w", err)
	}
	if len(secret) == 0 {
		return nil, ErrSecretNotConfigured
	}
	if window <= 0 {
		window = 60 * time.Second
	}
	return &HMACVerifier{
		secret: secret,
		window: window,
		now:    time.Now,
	}, nil
}

// canonicalMAC computes the canonical HMAC-SHA256 over body || 0x00 || ts_ascii.
func canonicalMAC(secret []byte, body string, ts int64) []byte {
	h := hmac.New(sha256.New, secret)
	h.Write([]byte(body))
	h.Write([]byte{0x00})
	h.Write([]byte(strconv.FormatInt(ts, 10)))
	return h.Sum(nil)
}

// Sign returns the lowercase-hex MAC for body+ts under this verifier's secret.
// Useful for tests and for the outbound side of the bridge.
func (v *HMACVerifier) Sign(body string, ts int64) string {
	return hex.EncodeToString(canonicalMAC(v.secret, body, ts))
}

// Verify checks the timestamp window then constant-time-compares the supplied MAC.
func (v *HMACVerifier) Verify(body string, ts int64, hmacHex string) error {
	if len(v.secret) == 0 {
		return ErrSecretNotConfigured
	}
	now := v.now().Unix()
	skew := now - ts
	if skew < 0 {
		skew = -skew
	}
	if time.Duration(skew)*time.Second > v.window {
		return fmt.Errorf("%w: skew=%ds window=%s", ErrTimestampSkew, skew, v.window)
	}
	got, err := hex.DecodeString(hmacHex)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidHMACEncoding, err)
	}
	want := canonicalMAC(v.secret, body, ts)
	if !hmac.Equal(got, want) {
		return ErrHMACMismatch
	}
	return nil
}
