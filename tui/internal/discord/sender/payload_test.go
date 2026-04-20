package sender

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestTruncateContent_ShortUnchanged(t *testing.T) {
	got := TruncateContent("short")
	if got != "short" {
		t.Fatalf("want unchanged, got %q", got)
	}
}

func TestTruncateContent_EmptyString(t *testing.T) {
	got := TruncateContent("")
	if got != "" {
		t.Fatalf("want empty, got %q", got)
	}
}

func TestTruncateContent_ExactFit(t *testing.T) {
	s := strings.Repeat("x", MaxContentBytes)
	got := TruncateContent(s)
	if got != s {
		t.Fatalf("exact-fit should be unchanged; got len=%d", len(got))
	}
	if strings.HasSuffix(got, TruncationSuffix) {
		t.Fatalf("exact-fit should not carry suffix")
	}
}

func TestTruncateContent_OneByteOver(t *testing.T) {
	s := strings.Repeat("x", MaxContentBytes+1)
	got := TruncateContent(s)
	if len(got) > MaxContentBytes {
		t.Fatalf("truncated len %d > cap %d", len(got), MaxContentBytes)
	}
	if !strings.HasSuffix(got, TruncationSuffix) {
		t.Fatalf("want suffix, got %q", got[len(got)-20:])
	}
}

func TestTruncateContent_LargeASCII(t *testing.T) {
	s := strings.Repeat("x", 3000)
	got := TruncateContent(s)
	if len(got) > MaxContentBytes {
		t.Fatalf("len %d > %d", len(got), MaxContentBytes)
	}
	if !strings.HasSuffix(got, TruncationSuffix) {
		t.Fatalf("missing suffix")
	}
	if !utf8.ValidString(got) {
		t.Fatalf("invalid utf8")
	}
}

func TestTruncateContent_MultibyteUTF8(t *testing.T) {
	// 世 is 3 bytes; 1000 runes = 3000 bytes > MaxContentBytes.
	s := strings.Repeat("世", 1000)
	got := TruncateContent(s)
	if len(got) > MaxContentBytes {
		t.Fatalf("len %d > %d", len(got), MaxContentBytes)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("truncation split a rune: %q", got)
	}
	if !strings.HasSuffix(got, TruncationSuffix) {
		t.Fatalf("missing suffix")
	}
	// Strip suffix and assert remainder is whole runes of 世.
	prefix := strings.TrimSuffix(got, TruncationSuffix)
	if len(prefix)%3 != 0 {
		t.Fatalf("prefix byte-length %d not divisible by 3 — split mid-rune", len(prefix))
	}
}

func TestTruncateContent_Emoji4Byte(t *testing.T) {
	// Each 🚀 is 4 bytes.
	s := strings.Repeat("🚀", 600) // 2400 bytes
	got := TruncateContent(s)
	if len(got) > MaxContentBytes {
		t.Fatalf("len %d > %d", len(got), MaxContentBytes)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("invalid utf8 after emoji truncation")
	}
	if !strings.HasSuffix(got, TruncationSuffix) {
		t.Fatalf("missing suffix")
	}
	prefix := strings.TrimSuffix(got, TruncationSuffix)
	if len(prefix)%4 != 0 {
		t.Fatalf("prefix byte-length %d not divisible by 4 — split mid-rune", len(prefix))
	}
}

func TestTruncateOnRuneBoundary_Generic(t *testing.T) {
	s, trunc := TruncateOnRuneBoundary("hello", 100)
	if trunc || s != "hello" {
		t.Fatalf("short string should not truncate; got trunc=%v s=%q", trunc, s)
	}

	out, trunc := TruncateOnRuneBoundary("hello world", 5)
	if !trunc {
		t.Fatalf("want truncation")
	}
	if len(out) > 5 {
		t.Fatalf("len %d > 5", len(out))
	}
}

func TestTruncateOnRuneBoundary_ZeroBudget(t *testing.T) {
	out, trunc := TruncateOnRuneBoundary("abc", 0)
	if out != "" {
		t.Fatalf("expected empty, got %q", out)
	}
	if !trunc {
		t.Fatalf("expected truncated=true for non-empty input")
	}
}
