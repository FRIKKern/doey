package redact

import (
	"strings"
	"testing"
)

func TestRedactKnownPatterns(t *testing.T) {
	cases := []struct {
		name  string
		input string
	}{
		{"openai", "sk-" + strings.Repeat("A", 30)},
		{"anthropic", "sk-ant-api03-" + strings.Repeat("B", 40)},
		{"github-pat", "ghp_" + strings.Repeat("C", 36)},
		{"github-oauth", "gho_" + strings.Repeat("C", 40)},
		{"slack", "xoxb-" + strings.Repeat("D", 20)},
		{"aws", "AKIA" + strings.Repeat("X", 16)},
		{"stripe", "sk_live_" + strings.Repeat("E", 30)},
		{"discord-webhook", "https://discord.com/api/webhooks/123456789/abc_DEF-ghi"},
		{"discord-webhook-app", "https://discordapp.com/api/webhooks/987654321/zzz-YYY_www"},
		{"bearer", "Authorization: Bearer fake-token-value"},
		{"private-key", "-----BEGIN RSA PRIVATE KEY-----"},
		{"password", "password=hunter2dummy"},
		{"secret-colon", "secret: placeholder-value"},
		{"long-base64", strings.Repeat("A", 60) + "="},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Redact(tc.input)
			if !strings.Contains(got, Placeholder) {
				t.Fatalf("expected Placeholder in output, got %q", got)
			}
			if strings.Contains(got, tc.input) && tc.input != Placeholder {
				t.Fatalf("original input still present in %q", got)
			}
		})
	}
}

func TestIdempotent(t *testing.T) {
	inputs := []string{
		"prefix sk-" + strings.Repeat("A", 30) + " suffix",
		"AKIA" + strings.Repeat("X", 16),
		"Authorization: Bearer xyz",
		"no secrets here at all, just prose",
		"",
	}
	for _, in := range inputs {
		once := Redact(in)
		twice := Redact(once)
		if once != twice {
			t.Fatalf("not idempotent: %q -> %q -> %q", in, once, twice)
		}
	}
}

func TestLastFour(t *testing.T) {
	cases := map[string]string{
		"":           "…____",
		"a":          "…a",
		"abc":        "…abc",
		"abcd":       "…abcd",
		"foobar1234": "…1234",
	}
	for in, want := range cases {
		if got := LastFour(in); got != want {
			t.Errorf("LastFour(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDiscordWebhookRedaction(t *testing.T) {
	for _, url := range []string{
		"https://discord.com/api/webhooks/123456789/abc_DEF-ghi",
		"https://discordapp.com/api/webhooks/987654321/zzz-YYY_www",
	} {
		out := Redact("error posting to " + url + " failed")
		if strings.Contains(out, url) {
			t.Fatalf("webhook URL not redacted: %q", out)
		}
		if !strings.Contains(out, Placeholder) {
			t.Fatalf("missing placeholder: %q", out)
		}
		if !strings.Contains(out, "error posting to ") || !strings.Contains(out, " failed") {
			t.Fatalf("surrounding prose mutated: %q", out)
		}
	}
}

func TestMixedTextPreservesContext(t *testing.T) {
	secret := "sk-" + strings.Repeat("Z", 30)
	in := "before " + secret + " after"
	out := Redact(in)
	if !strings.HasPrefix(out, "before ") {
		t.Errorf("prefix lost: %q", out)
	}
	if !strings.HasSuffix(out, " after") {
		t.Errorf("suffix lost: %q", out)
	}
	if strings.Contains(out, secret) {
		t.Errorf("secret leaked: %q", out)
	}
}

func TestShortBase64NotRedacted(t *testing.T) {
	in := "SGVsbG8=" // 8 chars, well under 48
	if got := Redact(in); got != in {
		t.Errorf("short base64 incorrectly redacted: %q -> %q", in, got)
	}
}

func TestMultiline(t *testing.T) {
	secret := "sk-" + strings.Repeat("M", 30)
	in := "line1\n" + secret + "\nline3"
	out := Redact(in)
	lines := strings.Split(out, "\n")
	if len(lines) != 3 {
		t.Fatalf("line count changed: %d", len(lines))
	}
	if lines[0] != "line1" || lines[2] != "line3" {
		t.Fatalf("surrounding lines mutated: %v", lines)
	}
	if !strings.Contains(lines[1], Placeholder) {
		t.Fatalf("middle line not redacted: %q", lines[1])
	}
}

func TestNonASCIIPassthrough(t *testing.T) {
	in := "héllo 世界 — no secrets here 🔒"
	if got := Redact(in); got != in {
		t.Errorf("non-ascii input mutated: %q -> %q", in, got)
	}
}

func TestRedactBytesMatchesRedact(t *testing.T) {
	in := "token sk-" + strings.Repeat("Q", 30) + " end"
	got := string(RedactBytes([]byte(in)))
	want := Redact(in)
	if got != want {
		t.Errorf("RedactBytes diverges: %q vs %q", got, want)
	}
}

func TestPatternsReturnsCopy(t *testing.T) {
	a := Patterns()
	b := Patterns()
	if len(a) != len(b) || len(a) == 0 {
		t.Fatalf("Patterns returned empty or mismatched slices")
	}
	a[0] = nil
	if Patterns()[0] == nil {
		t.Fatalf("Patterns returned a shared reference, not a copy")
	}
}
