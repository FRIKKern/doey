package main

import (
	"errors"
	"strings"
	"testing"
)

func TestNonceGenerateUniqueness(t *testing.T) {
	seen := make(map[string]struct{}, 1000)
	for i := 0; i < 1000; i++ {
		n, err := GenerateNonce()
		if err != nil {
			t.Fatalf("GenerateNonce: %v", err)
		}
		if len(n) != 16 {
			t.Fatalf("nonce len = %d, want 16", len(n))
		}
		if !validNonce(n) {
			t.Fatalf("nonce not lowercase hex: %q", n)
		}
		if _, dup := seen[n]; dup {
			t.Fatalf("duplicate nonce at i=%d: %s", i, n)
		}
		seen[n] = struct{}{}
	}
}

func TestNonceWrapParseRoundTrip(t *testing.T) {
	bodies := []string{
		"hello",
		"line1\nline2\nline3",
		"",
		"contains END nonce=ffffffffffffffff in middle",
		"weird\x00bytes",
	}
	for _, body := range bodies {
		n, err := GenerateNonce()
		if err != nil {
			t.Fatal(err)
		}
		framed := WrapBody(n, body)
		gotN, gotBody, err := ParseFramed(framed)
		if err != nil {
			t.Fatalf("parse %q: %v", body, err)
		}
		if gotN != n || gotBody != body {
			t.Fatalf("round-trip mismatch:\n  got n=%q body=%q\n want n=%q body=%q", gotN, gotBody, n, body)
		}
	}
}

func TestNonceMismatched(t *testing.T) {
	framed := "BEGIN nonce=aaaaaaaaaaaaaaaa\nbody\nEND nonce=bbbbbbbbbbbbbbbb"
	if _, _, err := ParseFramed(framed); !errors.Is(err, ErrNonceMismatch) {
		t.Fatalf("expected ErrNonceMismatch, got %v", err)
	}
}

func TestNonceMissingEnd(t *testing.T) {
	framed := "BEGIN nonce=aaaaaaaaaaaaaaaa\nbody without end"
	_, _, err := ParseFramed(framed)
	if !errors.Is(err, ErrFramingFormat) {
		t.Fatalf("expected ErrFramingFormat, got %v", err)
	}
}

func TestNonceTamperedHex(t *testing.T) {
	cases := []string{
		"BEGIN nonce=ZZZZZZZZZZZZZZZZ\nbody\nEND nonce=ZZZZZZZZZZZZZZZZ", // non-hex
		"BEGIN nonce=ABCDEFABCDEFABCD\nbody\nEND nonce=ABCDEFABCDEFABCD", // uppercase rejected
		"BEGIN nonce=aaaa\nbody\nEND nonce=aaaa",                         // wrong length
		"BEGIN nonce=aaaaaaaaaaaaaaaaaa\nbody\nEND nonce=aaaaaaaaaaaaaaaaaa",
	}
	for _, c := range cases {
		_, _, err := ParseFramed(c)
		if err == nil {
			t.Fatalf("expected error for %q", c)
		}
	}
}

func TestNonceEmpty(t *testing.T) {
	if _, _, err := ParseFramed(""); !errors.Is(err, ErrFramingEmpty) {
		t.Fatalf("expected ErrFramingEmpty, got %v", err)
	}
}

func TestNonceMissingBegin(t *testing.T) {
	framed := "no begin\nbody\nEND nonce=aaaaaaaaaaaaaaaa"
	if _, _, err := ParseFramed(framed); !errors.Is(err, ErrFramingFormat) {
		t.Fatalf("expected ErrFramingFormat, got %v", err)
	}
}

func TestNonceWrapShape(t *testing.T) {
	got := WrapBody("0123456789abcdef", "x")
	want := "BEGIN nonce=0123456789abcdef\nx\nEND nonce=0123456789abcdef"
	if got != want {
		t.Fatalf("wrap shape:\n got=%q\nwant=%q", got, want)
	}
	// LF only — must not contain CR.
	if strings.ContainsRune(got, '\r') {
		t.Fatalf("framing must use LF only, got CR")
	}
}
