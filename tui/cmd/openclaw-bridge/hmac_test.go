package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testSecretHex = "0a1b2c3d4e5f60718293a4b5c6d7e8f900112233445566778899aabbccddeeff"

func newTestVerifier(t *testing.T, fixedNow time.Time) *HMACVerifier {
	t.Helper()
	v, err := NewHMACVerifier(testSecretHex, 60*time.Second)
	if err != nil {
		t.Fatalf("NewHMACVerifier: %v", err)
	}
	v.now = func() time.Time { return fixedNow }
	return v
}

func TestHMACRoundTrip(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	v := newTestVerifier(t, now)
	body := "hello bridge"
	ts := now.Unix()
	mac := v.Sign(body, ts)
	if err := v.Verify(body, ts, mac); err != nil {
		t.Fatalf("round-trip verify: %v", err)
	}
}

func TestHMACWrongSecret(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	good := newTestVerifier(t, now)
	bad, err := NewHMACVerifier("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", 60*time.Second)
	if err != nil {
		t.Fatalf("bad verifier: %v", err)
	}
	bad.now = good.now
	mac := good.Sign("body", now.Unix())
	if err := bad.Verify("body", now.Unix(), mac); !errors.Is(err, ErrHMACMismatch) {
		t.Fatalf("expected ErrHMACMismatch, got %v", err)
	}
}

func TestHMACTamperedBody(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	v := newTestVerifier(t, now)
	mac := v.Sign("original", now.Unix())
	if err := v.Verify("tampered", now.Unix(), mac); !errors.Is(err, ErrHMACMismatch) {
		t.Fatalf("expected ErrHMACMismatch, got %v", err)
	}
}

func TestHMACTimestampSkew(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	v := newTestVerifier(t, now)
	cases := []struct {
		name    string
		ts      int64
		wantErr bool
	}{
		{"future_inside", now.Unix() + 30, false},
		{"future_outside", now.Unix() + 120, true},
		{"past_inside", now.Unix() - 30, false},
		{"past_outside", now.Unix() - 120, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mac := v.Sign("b", tc.ts)
			err := v.Verify("b", tc.ts, mac)
			if tc.wantErr {
				if !errors.Is(err, ErrTimestampSkew) {
					t.Fatalf("want ErrTimestampSkew, got %v", err)
				}
			} else if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
		})
	}
}

// Regression: signing without the 0x00 separator must NOT verify.
// This guards against an attacker who can craft (body, ts) so that
// body || ts_ascii collides with a different (body', ts'_ascii).
func TestHMACSeparatorRequired(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	v := newTestVerifier(t, now)
	body := "hi"
	ts := now.Unix()

	// Build a MAC the WRONG way: body || ts_ascii (no NUL separator).
	secret, _ := hex.DecodeString(testSecretHex)
	h := hmac.New(sha256.New, secret)
	h.Write([]byte(body))
	h.Write([]byte(strconv.FormatInt(ts, 10)))
	wrongMAC := hex.EncodeToString(h.Sum(nil))

	if err := v.Verify(body, ts, wrongMAC); !errors.Is(err, ErrHMACMismatch) {
		t.Fatalf("expected mismatch when separator omitted, got %v", err)
	}

	// And the right MAC must verify.
	if err := v.Verify(body, ts, v.Sign(body, ts)); err != nil {
		t.Fatalf("canonical mac should verify: %v", err)
	}
}

func TestHMACBodyContainsNUL(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	v := newTestVerifier(t, now)
	body := "before\x00after"
	ts := now.Unix()
	mac := v.Sign(body, ts)
	if err := v.Verify(body, ts, mac); err != nil {
		t.Fatalf("verify body-with-NUL: %v", err)
	}
	// Sanity: a body without the NUL but with the same payload bytes after the
	// canonicalization separator must NOT verify under the same MAC.
	alt := "before"
	altTs := ts // unchanged
	if err := v.Verify(alt, altTs, mac); !errors.Is(err, ErrHMACMismatch) {
		t.Fatalf("expected mismatch on truncated body, got %v", err)
	}
}

func TestHMACInvalidSecretHex(t *testing.T) {
	if _, err := NewHMACVerifier("zz", 0); err == nil {
		t.Fatal("expected error for invalid hex")
	}
	if _, err := NewHMACVerifier("", 0); !errors.Is(err, ErrSecretNotConfigured) {
		t.Fatalf("expected ErrSecretNotConfigured, got %v", err)
	}
}

func TestHMACInvalidMACHex(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	v := newTestVerifier(t, now)
	err := v.Verify("body", now.Unix(), "zzzz")
	if !errors.Is(err, ErrInvalidHMACEncoding) {
		t.Fatalf("expected ErrInvalidHMACEncoding, got %v", err)
	}
}

// Demonstrates the canonicalization byte sequence for downstream verifier authors.
func TestHMACCanonicalizationBytes(t *testing.T) {
	body := "abc"
	ts := int64(1700000000)
	want := []byte("abc\x001700000000")
	got := []byte(body)
	got = append(got, 0x00)
	got = append(got, []byte(strconv.FormatInt(ts, 10))...)
	if !strings.EqualFold(hex.EncodeToString(got), hex.EncodeToString(want)) {
		t.Fatalf("canonical bytes mismatch:\n got=%x\nwant=%x", got, want)
	}
}
